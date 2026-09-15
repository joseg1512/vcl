# Análisis técnico: discos adicionales en imágenes VCL

**Estado:** análisis únicamente — no hay código de la funcionalidad en este cambio.  
**Audiencia:** Jose Gabriel / NAC.  
**Base analizada:** `develop` en https://github.com/joseg1512/vcl (`706542a1`, último merge: tema NAC).  
**Fecha:** 2026-09-15.

## Resumen ejecutivo

Hoy una imagen VCL se reserva con **un solo disco OS**. RAM y CPU ya se configuran en *Manage Images → Advanced Options* y se aplican en el `load()` del provisioner (VMware o libvirt/KVM). **No existe** soporte de discos extra vacíos.

La petición (checkbox **Additional disk**, hasta 10 discos con tamaño en GB) es **viable**, pero **no está abstraída**. Cada hypervisor crea el disco OS en su propio `load()`. Hace falta implementar el adjunto en **ambos** provisioners de interés:

| Entorno | Quién crea la VM | Módulo | Disco OS hoy |
|---|---|---|---|
| Producción NAC | Host ESXi real | `VCL::Module::Provisioning::VMware::VMware` | Un `.vmdk` en VMX (`scsi0:0` o `ide0:0`) |
| Pruebas locales | Ubuntu + KVM/libvirt | `VCL::Module::Provisioning::libvirt` + `libvirt/KVM.pm` | Un qcow2 CoW en XML (`vda`) |

Eso **no** es un `if (ESXi vs KVM)` suelto en PHP. El `computer.provisioningid` ya selecciona el módulo. El trabajo nuevo es **polimorfismo de provisioner**: cada `load()` crea y adjunta los discos extra.

**Recomendación de datos:** tabla nueva `imageadditionaldisk` con FK a `image.id` (no blob JSON, no columnas fijas en `imagemeta`). El checkbox de UI se deriva de “hay filas” o de un flag opcional; no hace falta un flag persistido si se borra al desmarcar.

**Alcance recomendado (fase 1):** discos **ephemeral vacíos** creados en cada *reserve/load*, **no** capturados en la imagen dorada. En un guest ESXi anidado, un VMDK/qcow vacío aparece como disco local; el estudiante aún debe crear datastore VMFS (o usar el NAS opcional `ESXI_STORAGE_*` que ya existe).

---

## 1. Contexto del caso de uso

Hay tres capas que conviene no mezclar:

1. **Hypervisor anfitrión (host que crea la VM VCL)**  
   En NAC: ESXi. En el lab local: Ubuntu/KVM. Aquí se adjunta el disco extra **a la VM reservada**.

2. **Guest de la reserva**  
   Puede ser Linux/Windows o **ESXi anidado** (`OS` `vmwareesxi` / módulo `VCL::Module::OS::Linux::ESXi`). El disco extra aparece *dentro* de ese guest.

3. **VMs que los estudiantes crean dentro del ESXi anidado**  
   Eso ya no es VCL: es vSphere/vim-cmd del guest. VCL solo puede dar capacidad (discos vacíos o un datastore NFS).

El comentario “quien crea las VMs es un ESXi” se refiere a la capa 1 en producción. Las pruebas en Ubuntu no invalidan el diseño: el mismo `image.id` se carga con VMware.pm o libvirt.pm según el `provisioningid` del *computer* asignado.

Ya hay un camino parcial para laboratorio anidado: `ESXi.pm::_configure_nested_lab_storage()` monta NFS (`ESXI_STORAGE_*` en `vcld.conf`) y registra VMX. Eso es **presentación de datastore**, no “disco extra vacío en la VM”. Son complementarios, no equivalentes.

---

## 2. Hallazgos A — Manage Images / Advanced Options

### 2.1 UI

El diálogo de edición de imagen se construye en PHP y se rellena por AJAX:

| Pieza | Ruta | Rol |
|---|---|---|
| HTML Advanced Options | `web/.ht-inc/image.php` → `Image::addEditDialogHTML()` | `dijit.TitlePane` `id="advancedoptions"` |
| Carga al editar | `web/js/resources/image.js` → `inlineEditResourceCB()` | Rellena spinners/selects |
| Guardado | `saveResource()` → `RPCwrapper` → `Image::AJsaveResource()` | Continuation `AJsaveResource` |
| Validación servidor | `Image::validateResourceData()` | Rangos RAM/CPU/etc. |

Campos actuales en el pane (aprox. líneas 390–485 de `image.php`):

| Widget JS id | Etiqueta | Tipo | Destino DB |
|---|---|---|---|
| `ram` | Required RAM (MB) | spinner 512–8388607, default 4096 | `image.minram` |
| `cores` | Required Cores | spinner 1–255, default 2 | `image.minprocnumber` |
| `cpuspeed` | Processor Speed | spinner | `image.minprocspeed` |
| `networkspeed` | Minimum Network Speed | select | `image.minnetwork` |
| `concurrent` | Max Concurrent Usage | spinner | `image.maxconcurrent` |
| `reload` | Estimated Reload Time | spinner (solo edit) | `image.reloadtime` |
| `checkout` | Available for Checkout | Yes/No | `image.forcheckout` |
| `checkuser` | Check for Logged in User | Yes/No | `imagemeta.checkuser` |
| `rootaccess` | Users Have Administrative Access | Yes/No | `imagemeta.rootaccess` |
| `sethostname` | Set Computer Hostname | Yes/No | `imagemeta.sethostname` |
| `maxinitialtime` | Max Reservation Duration | select | `image.maxinitialtime` |
| `sysprep` | Use Sysprep | Yes/No (solo **alta**) | `imagemeta.sysprep` |
| Connect methods | lista + popup | **por revisión** | `connectmethodmap` |
| AD auth | checkbox `adauthenable` | solo Windows | `imageaddomain` |
| Subimages | popup (efecto inmediato) | 1:N | `imagemeta.subimages` + tabla `subimages` |

Patrón de checkbox ya usado: `adauthenable` (`type='check'` en `labeledFormItem`, `onChange: toggleADauth()`). Es el analogo UI correcto para “Additional disk”.

### 2.2 Flujo de persistencia (edit)

1. Grid → `AJeditResource()` carga `getImages()` + notas, guarda `olddata` en la continuation, devuelve JSON.
2. JS rellena widgets. Si Advanced Options está abierto, lo cierra.
3. `saveResource()` valida en cliente (abre el pane si RAM/cores fallan), envía POST.
4. `AJsaveResource()`:
   - Hardware (RAM/CPU/red/concurrencia/reload/checkout/maxinitialtime/desc/usage) → `UPDATE image SET ...` **solo si cambió**.
   - AD → `imageaddomain`.
   - Flags comportamentales → `imagemeta` **lazy**:
     - Si no hay `imagemetaid` y algún flag sale del default → `INSERT imagemeta` + `image.imagemetaid`.
     - Si ya hay fila → `UPDATE` si cambió.
     - `checkClearImageMeta()` borra `imagemeta` y pone `imagemetaid = NULL` si todo volvió al default.

**Importante:** RAM/CPU **no** viven en `imagemeta`. Viven en `image`. `imagemeta` es para flags (checkuser, rootaccess, sysprep, sethostname, subimages).

### 2.3 Esquema actual relevante

```sql
-- image (hardware + vínculo opcional a meta)
minram, minprocnumber, minprocspeed, minnetwork, maxconcurrent,
reloadtime, forcheckout, maxinitialtime, size, imagemetaid

-- imagemeta (1:0..1, creado solo si hay no-default)
id, checkuser DEFAULT 1, subimages DEFAULT 0, sysprep DEFAULT 1,
postoption, architecture, rootaccess DEFAULT 1, sethostname NULL

-- imagerevision (revisiones; NO tiene RAM/CPU/meta)
id, imageid, revision, production, imagename, comments, ...

-- subimages (único 1:N ligado a meta hoy)
imagemetaid, imageid
```

Valores **por imagen**, no por revisión (igual que RAM). Connect methods sí son por revisión. Discos extra deben ser **por imagen**, como RAM.

Defaults PHP si no hay `imagemeta`: `checkuser=1`, `rootaccess=1`, `sethostname` 0 (Windows/OSX) o 1 (Linux).

### 2.4 Validación / matching

- RAM: UI min 512; servidor 0–8388607; al editar se fuerza ≥512 para mostrar.
- Cores: 0–255 servidor; UI 1–255.
- El scheduler (`utils.php`) elige computers con `c.RAM >= i.minram` y `c.procnumber >= i.minprocnumber`. **No hay chequeo de espacio en disco del host en el matching**, solo en `VMware.pm::check_vmhost_disk_space()` al hacer `load()`.

Cambiar RAM de una imagen **en uso** no muta la VM viva: aplica en el **próximo load**. El mismo contrato debe usarse para discos extra.

---

## 3. Hallazgos B — Cómo RAM/CPU llegan al hypervisor

Orquestación: `new.pm` → `State::create_provisioning_object()` lee `computer.provisioningid` → `module.perlpackage` → `provisioner->load()`.

Datos: `utils.pm::get_imagemeta_info()` mete `image.imagemeta` en el hash de la reserva. `DataStructure.pm` expone `get_image_minram()`, `get_image_minprocnumber()`, `get_imagemeta_*()`.

### 3.1 VMware / ESXi host (`VMware.pm::load`)

1. `remove_existing_vms()`
2. `check_vmhost_disk_space()` / `reclaim_vmhost_disk_space()`
3. `prepare_vmdk()` — copia/clone del **único** disco OS (shared o dedicated según `vmprofile.vmdisk`)
4. `prepare_vmx()` — escribe `memsize` (`get_vm_ram()` ← `image.minram`) y `numvcpus` / `cpuid.coresPerSocket` (`get_vm_cpu_configuration()` ← `image.minprocnumber`)
5. Disco OS:
   - SCSI: `scsi0:0.fileName` = path vmdk
   - IDE: `ide0:0.fileName` + CDROM en `ide0:1`
6. Nested HV si el host lo soporta: `vhv.enable`, `monitor.virtual_*` (ya existe; no es disco)
7. `vm_register`, snapshot, power on
8. OS `post_load`

API de disco hoy: `vmkfstools -i` (clone) y `-E` (rename). **No hay** `vmkfstools -c` (crear disco vacío).

### 3.2 libvirt / KVM (`libvirt.pm::load` + `KVM.pm`)

1. `delete_existing_domains()`
2. `generate_domain_xml()`:
   - `memory` = `minram` (mín. 512) en KB
   - `vcpu` = `minprocnumber`
   - **un** `<disk>` file → CoW en `get_copy_on_write_file_path()`
   - `target dev='vda'`, bus desde XML master (default `ide`)
3. `KVM.pm::extend_domain_xml()` — solo guests ESXi: CPU `host-passthrough`, timers, NIC `vmxnet3`
4. `KVM.pm::pre_define()` — `qemu-img create -f qcow2 -b <master>` (CoW del OS)
5. `virsh define` + power on + OS `post_load`

`qemu-img create` **sin** backing file (disco vacío) **no se usa** en ningún sitio.

### 3.3 Otros provisioners

`vbox`, `docker`, `openstack`, `one`, `xCAT`: fuera del alcance NAC ESXi/KVM. Si un computer usa otro engine, los discos extra se ignorarían hasta implementarlos.

---

## 4. Hallazgos C — Modelo de disco actual

Conclusión: **multi-disco extra vacío no está soportado**. Lo que hay es:

| Concepto | Qué es | Relación con la petición |
|---|---|---|
| Disco OS (vmdk/qcow2) | Imagen dorada + clone/CoW | Sigue igual |
| Split 2gbsparse vmdk | Varios archivos = **un** disco | No son discos extra |
| `vmprofile.datastorepath` / `vmpath` | Dónde viven master y VM | Extra disks deben ir en `vmpath` (por-VM), no en el master compartido |
| `vmprofile.vmdisk` dedicated/shared | Solo el OS disk | Extra disks **siempre dedicated/ephemeral** |
| `imagetype` vmdk vs qcow2 | Formato del OS | Extra: mismo formato que el datastore del host |
| `image.size` | Tamaño estimado de la imagen | No sirve para 1:N extra |
| `computer.drivetype` | Reliquia (hda) | No usar |
| NAS `ESXI_STORAGE_*` | Datastore NFS **dentro** del guest ESXi | Alternativa/complemento, no checkbox de discos |

Capture **asume un disco**:

- VMware: si el VMX tiene **más de un** vmdk → **falla** (`prepare`/`capture` ~L878–880).
- libvirt: si hay varios discos, **solo captura el primero** (warning, ~L502–507).

Por eso fase 1 debe tratar los extra como **no parte de la imagen capturada**.

Cleanup: `libvirt.pm::delete_domain()` borra archivos de disco cuyo nombre empieza por `$computer_name_`. Los extra **deben** usarse ese prefijo. VMware `delete_vm()` borra el directorio vmx/vmdk dedicated; conviene colocar extra vmdk **en el directorio de la VM**, no junto al master compartido.

---

## 5. Hallazgos D — ESXi host vs KVM (¿condicional o polimorfismo?)

**Ya está resuelto a nivel de arquitectura.** No hace falta un `if` global “si el host es ESXi…”.

```
computer.provisioningid
  → provisioning.moduleid
    → module.perlpackage
      → VMware.pm  o  libvirt.pm
```

Módulos sembrados:

- `provisioning_vmware` → `VCL::Module::Provisioning::VMware::VMware`
- `provisioning_libvirt` → `VCL::Module::Provisioning::libvirt` (driver KVM)

El OS del **guest** (`os_esxi`) no crea discos; prepara cuentas, red, firewall, y opcionalmente NAS. Nested HV en VMX/XML ya se hace en el provisioner.

Lo que **sí** hay que implementar **dos veces** (misma interfaz, distinta API):

| Paso | ESXi host (prod) | Ubuntu KVM (lab) |
|---|---|---|
| Crear disco vacío | `vmkfstools -c <size>G -d thin <path>.vmdk` | `qemu-img create -f qcow2 <path> <size>G` |
| Adjuntar | líneas VMX `scsi0:N.fileName` (o 2º SCSI) **antes** de `vm_register` | más elementos `<disk>` en `generate_domain_xml` |
| Thin vs full | thin (`-d thin`) recomendado | qcow2 sparse por defecto |
| Bus | SCSI (`lsiLogic`/`lsisas1068`); si OS es IDE, **añadir SCSI** para extra (IDE solo 4 slots y uno es CDROM) | mismo bus que el OS (`get_master_xml_disk_bus_type`); **ESXi guest no usa virtio** — forzar `scsi`/`sata` para extra si el OS disk es virtio |
| Espacio host | extender `get_vm_additional_vmdk_bytes_required()` | no hay chequeo equivalente; añadir o aceptar riesgo en lab |
| Borrar | `delete_vm` del directorio VM | `delete_domain` por prefijo de nombre |
| Capture | **debe ignorar** extra o fallará el “multiple vmdk” | ya ignora todo excepto el primer disco |

`govc` no se usa. El camino VMware es SSH + `vmkfstools` / `vim-cmd` (`VIM_SSH.pm`, `vmware_cmd.pm`, `vSphere_SDK.pm`).

**¿Condicional real?** Solo:

- Bus/controller según guest OS (ESXi anidado vs Linux).
- No adjuntar extra en xCAT/docker/etc. (no-op).
- Thin en datastore NFS vs local: ambos soportan thin/qcow2; no bloquear por perfil.

No hace falta que PHP sepa si el computer caerá en ESXi o KVM. El MN lee la tabla y el provisioner concreto actúa.

---

## 6. Hallazgos E — Modelo de datos

### Opción 1 — Tabla nueva `imageadditionaldisk` + checkbox UI (recomendada)

```sql
CREATE TABLE IF NOT EXISTS `imageadditionaldisk` (
  `id` smallint(5) unsigned NOT NULL auto_increment,
  `imageid` smallint(5) unsigned NOT NULL,
  `sequence` tinyint(3) unsigned NOT NULL,
  `sizegb` smallint(5) unsigned NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `imageid_sequence` (`imageid`,`sequence`),
  KEY `imageid` (`imageid`),
  CONSTRAINT `imageadditionaldisk_ibfk_1`
    FOREIGN KEY (`imageid`) REFERENCES `image` (`id`)
    ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=latin1;
```

- Checkbox **no** es columna: checked ⇔ `COUNT(*) > 0`. Desmarcar = `DELETE`.
- `sequence` 1–10; `sizegb` entero (p.ej. 1–65535, tope UI más bajo).
- Por imagen, como RAM. Independiente de `imagemeta` lazy (evita que `checkClearImageMeta` borre el flag).
- Migración: `CREATE TABLE IF NOT EXISTS` + FK en `mysql/vcl.sql` y bloque idempotente al final de `mysql/update-vcl.sql` (antes del `DROP PROCEDURE`).

**UI load/save:**

- `AJeditResource`: `SELECT sequence, sizegb FROM imageadditionaldisk WHERE imageid=? ORDER BY sequence` → JSON `additionaldisks: [{sequence, sizegb}, ...]`.
- JS: checkbox + contenedor 1–10 spinners (mostrar/ocultar como `toggleADauth`).
- `validateResourceData`: max 10, sizegb ≥ 1, enteros.
- `AJsaveResource`: transacción `DELETE` + `INSERT` de la lista (o diff). No tocar `image` salvo que se añada un flag (no recomendado).

**MN:** `get_image_info()` carga `image.additionaldisks`. `DataStructure` añade `get_image_additional_disks()`. `load()` itera.

### Opción 2 — Flag `imagemeta.additionaldisks` + tabla hija con `imagemetaid`

Copia de `subimages`. Coste: hay que crear `imagemeta` al marcar, no borrar meta si hay filas, y enseñar a `checkClearImageMeta` la tabla hija. Más acoplamiento para un dato de hardware. **No recomendada.**

### Opción 3 — JSON/text en `imagemeta`

VCL no usa JSON en tablas de recurso (salvo `variable` yaml). Malo para validar, migrar y leer desde Perl. **Rechazar.**

### Opción 4 — 10 columnas en `image` (`adddisk1gb` …)

Rígido, feo, nulos. **Rechazar.**

### Comparación

| Criterio | Tabla `imageid` (1) | Meta + hija (2) | JSON (3) |
|---|---|---|---|
| 1:N natural | sí | sí | forzado |
| Encaja con RAM (por image) | sí | no (meta) | no |
| Lazy imagemeta | no interfiere | hay que pelear | hay que pelear |
| Validar 10 / GB | SQL + PHP | igual | solo PHP |
| Lectura Perl | SELECT | JOIN extra | parse |

---

## 7. Hallazgos F — Casos borde

### 7.1 Imagen ya reservada / en uso

Igual que RAM: el `UPDATE` es inmediato en DB; la VM viva **no** se reconfigura. El siguiente `load`/`reload` aplica los discos. No hace falta bloquear el save. Opcional: aviso “hay reservas activas” (el delete de imagen ya consulta `request`/`reservation`).

### 7.2 Máximo 10

Validar en JS, PHP y (defensa) en `load()`. SCSI `scsi0:1`–`scsi0:7` = 7 extra si el OS está en `:0`; para 10 extra usar `scsi1` o PVSCSI. Documentar en implementación.

### 7.3 Límites de tamaño / espacio del host

No hay tope de GB en UI hoy (RAM sí). Propuesta fase 1:

- UI: 1–4096 GB (ajustable).
- Servidor: 1–65535.
- Thin/qcow2: el “size” es virtual; el host gasta según escritura.
- VMware: sumar `sum(sizegb)` (o una fracción thin, p.ej. 10%) en `get_vm_additional_vmdk_bytes_required()`.
- KVM: añadir chequeo análogo o log + fallar si `qemu-img`/`ENOSPC`.
- Matching de reserva: **no** filtrar por disco libre en fase 1 (hoy tampoco se hace para el OS más allá del check en load VMware).

### 7.4 Capture vs reserve

**Solo reserve/load.** No meter extra en la imagen dorada.

Al capturar:

- VMware: **hay que cambiar** el “return si >1 vmdk” para **saltar** discos cuyo path coincida con el patrón extra (`…/<vm>_adddiskN.vmdk`) y capturar solo el OS. Si no, **capture de imágenes con extra se rompe**.
- libvirt: ya captura solo el primer disco; asegurar que el OS es siempre `disk[0]`.
- Checkpoint/reload tras capture: `load()` volverá a crear extra vacíos (contenido de lab se pierde — correcto para ephemeral).

Si más adelante se quiere “persistir datos de lab en la imagen”, sería otra feature (incluir extra en capture). **Fuera de fase 1.**

### 7.5 ESXi anidado: ¿VMDK vacío basta?

**Para ver un disco en el guest, sí. Para que los estudiantes creen VMs de inmediato, no del todo.**

| Qué obtiene el estudiante | ¿Fase 1 (qcow/vmdk vacío)? | ¿Ya existe? |
|---|---|---|
| Disco local extra en el ESXi guest | sí (aparece en *Storage adapters / Devices*) | no |
| Datastore VMFS usable | no — hay que `esxcli storage vmfs create` (o UI Host Client) | no |
| Datastore NFS con ISOs/VMX | no | sí, `ESXI_STORAGE_*` en `grant_access` |

Recomendación: fase 1 = adjuntar vacíos. Fase 2 opcional (solo OS ESXi): en `post_load`/`grant_access`, crear VMFS en esos dispositivos. No mezclar con el NAS.

### 7.6 Varios hosts / datastores / perfiles

Los extra se crean en el `vmpath` del **vmprofile del host asignado**, mismo sitio que el VMX/CoW:

- ESXi local: `datastore1`
- ESXi NFS: `nfs-datastore` / mixto
- KVM: `/var/lib/libvirt/images`

No hay que elegir datastore en la UI de imagen. Si el host no tiene espacio, falla el `load` (como un vmdk OS grande).

Shared vs dedicated del OS no aplica a extra: **nunca** compartir extra entre VMs.

### 7.7 Reload / sanitize / predictive

Reload vuelve a `load()` → extra se recrean vacíos.  
`Predictive::Level_2` destruye la VM → extra se van con ella.  
ESXi `sanitize()` si el usuario conectó fuerza reload (guest hypervisor sucio) → extra nuevos vacíos. Correcto.

### 7.8 Alta de imagen (`createImage` / `addResource`)

El pane también aparece al crear. Incluir save de extra en `addResource()` para no tener que re-editar. Sysprep solo en add; extra sí en add y edit.

---

## 8. Boceto de UI

Dentro de `#advancedoptions`, después de cores/RAM (hardware) o junto a AD (toggle):

```
[ ] Additional disks
    (If checked, empty disks are attached at reservation load time.
     They are not stored in the captured image.)

    Disk 1  [ 100 ] GB   [+]
    Disk 2  [  50 ] GB   [−]
    ...
    (máx. 10; [+] deshabilitado al llegar a 10)
```

Comportamiento:

- Unchecked (default): no POST de discos / lista vacía → DELETE all. Igual que hoy.
- Checked: al menos 1 fila; spinners GB (delta 10/50).
- `inlineEditResourceCB`: `checked = additionaldisks.length > 0`.
- `resetEditResource` / `saveResourceCB`: reset checkbox + filas.
- Validación: si checked y 0 filas o size inválido → abrir pane y foco (igual que RAM).
- i18n: `i()` en PHP; `_()` + `web/js/nls/es_CR/messages.js` (NAC).

No usar el popup de Subimages (guarda al vuelo y el texto dice que no hace falta “Submit”). Extra debe ir en **Confirm / Save Changes**, como RAM.

---

## 9. Puntos de toque en código (implementación futura)

### 9.1 Esquema

- `mysql/vcl.sql` — `CREATE TABLE` + `ALTER` FK
- `mysql/update-vcl.sql` — mismo `CREATE` idempotente
- `mysql/phpmyadmin.sql` — opcional (display)

### 9.2 Web

- `web/.ht-inc/image.php` — HTML, `AJeditResource`, `AJsaveResource`, `addResource`, `validateResourceData`
- `web/js/resources/image.js` — load/save/reset/validate + toggle
- `web/.ht-inc/utils.php` — `getImages()` incluir array `additionaldisks` (no hace falta meterlo en `imagemeta`)
- nls `es_CR` (y otros si se mantiene paridad)

### 9.3 Management node

- `utils.pm` — SELECT extra en `get_image_info()`
- `DataStructure.pm` — mapping + `get_image_additional_disks()`
- `VMware.pm`:
  - helper `create_empty_vmdk($path, $size_gb)` → `vmkfstools -c`
  - `prepare_vmx()`: `scsi0:N` / `scsi1:N`
  - `check_vmhost_disk_space` / `get_vm_additional_vmdk_bytes_required`
  - `capture`: filtrar extra; no fallar por >1 vmdk
  - naming: `{vmx_directory}/{computer}_adddisk{N}.vmdk`
- `libvirt.pm` + `KVM.pm`:
  - `qemu-img create -f qcow2` (o formato datastore)
  - más `<disk>` en `generate_domain_xml` (`vdb`… o `sdb`…)
  - bus: no virtio para guest ESXi
  - naming: `{vmpath}/{computer}_adddisk{N}.qcow2` (cumple el filtro de `delete_domain`)
- `ESXi.pm`: **no** en fase 1 (fase 2 VMFS)
- `Provisioning.pm`: opcional `attach_additional_disks` en la base; no es obligatorio (hoy RAM tampoco está en la base)

### 9.4 Qué no tocar

OS Linux/Windows, scheduler de matching, `imagemeta` (si se elige opción 1), connect methods, tema NAC.

---

## 10. Plan de acción por fases

### Fase 0 — Aprobación (este documento)

Jose/NAC confirma:

1. Extra **solo en load**, no en capture.
2. Tabla `imageadditionaldisk(imageid, sequence, sizegb)`.
3. Fase 1: VMware.pm **y** libvirt/KVM (lab local).
4. Guest ESXi: disco vacío basta en v1; VMFS automático queda como fase 2.
5. Tope GB y thin vs eager-zero.

### Fase 1a — DB + UI (sin hypervisor)

Migración, formulario, validación, round-trip save. Se puede demo en Manage Images sin reservar.

### Fase 1b — libvirt/KVM (lab)

Más fácil de iterar. Reservar imagen Linux + extra; `virsh dumpxml` muestra 2+ discos; `lsblk` en el guest; reclaim borra qcow extra; capture sigue sacando solo el OS.

### Fase 1c — VMware/ESXi (prod)

`vmkfstools -c thin`, VMX SCSI, espacio, capture filtrado. Probar imagen Linux y `vmwareesxi`. Confirmar que nested HV sigue igual.

### Fase 1d — Regresión

Reload, dedicated vs shared OS, imagen **sin** extra (checkbox off = 1 disco), 10 discos, disco enorme / ENOSPC, computer no-VM (xCAT) no-op.

### Fase 2 (opcional, otro PR)

- `ESXi.pm`: VMFS en extra disks.
- Aviso si hay reservas al guardar.
- Espacio de extra en matching.
- OpenStack/VBox si hiciera falta.

---

## 11. Riesgos

| Riesgo | Impacto | Mitigación |
|---|---|---|
| Capture VMware falla con >1 vmdk | No se puede recapturar imagen con extra | Filtrar extra **en el mismo PR** que adjunta en VMware |
| Extra en datastore **shared** del OS | Contamina el master / otras VMs | Solo en directorio VM / `vmpath` |
| IDE lleno (OS + CDROM) | No caben 10 extra | SCSI dedicado para extra |
| virtio en ESXi anidado | Guest no ve el disco | Forzar scsi/sata si OS name ~ esxi |
| Thin 10×1 TB | El host parece “caber” y luego ENOSPC | Tope GB + chequeo; thin no reserva 100% |
| `imagemeta` lazy si se usa flag | Se pierde config al “reset” meta | Opción 1: FK a `image` |
| Solo implementar VMware | Lab KVM no prueba la feature | 1b antes que 1c |
| Solo implementar KVM | Prod ESXi no entrega valor | 1c antes de cerrar |
| Formatear VMFS en fase 1 | Scope creep, fácil romper el guest | Dejarlo en fase 2 |
| Contenido de extra en reload | Se pierde | Documentar ephemeral; es el contrato de VCL reload |

---

## 12. Preguntas abiertas para Jose

1. **¿Fase 1 en KVM y ESXi, o primero un hypervisor?** Recomendación: UI+DB → KVM lab → ESXi prod.
2. **¿Tope de GB?** Sugerencia 4096 GB/disco, 10 discos. ¿Más bajo para no llenar `datastore1`?
3. **¿Thin siempre?** Recomendado (qcow2 / `vmkfstools -d thin`). ¿Algún curso necesita eager-zero?
4. **¿El estudiante formatea VMFS a mano** (Host Client) en v1, o hay que automatizarlo para el curso?
5. **¿Checkbox visible en todas las imágenes o solo `installtype=vmware` / OS ESXi?** Mostrarlo siempre y no-op en xCAT es más simple; ocultarlo en no-VM evita confusión.
6. **¿Nombres en UI en español (NAC) o inglés VCL (`Additional disks`)?** El resto del pane está en inglés vía `i()`.
7. **¿Alta de imagen debe pedir extra, o solo edit?** Recomendación: ambos, como RAM.
8. **¿Hay que versionar extra por `imagerevision`?** Recomendación: no (como RAM). Si una revisión vieja necesitara otro layout, habría que decirlo ahora.
9. **¿Relación con `ESXI_STORAGE_*`?** ¿Se sigue usando NFS de lab, o los extra lo sustituyen para el curso?

---

## 13. Veredicto

| Pregunta | Respuesta |
|---|---|
| ¿Se puede hacer encajando en Advanced Options? | Sí: mismo diálogo, AJAX, `AJsaveResource`, como RAM + toggle tipo AD. |
| ¿Tabla nueva? | **Sí.** `imageadditionaldisk(imageid, sequence, sizegb)`. |
| ¿VCL ya abstrae “attach disk”? | **No.** Cada provisioner pega un solo OS disk. Hay que extender `prepare_vmx` y `generate_domain_xml`. |
| ¿If ESXi vs KVM en PHP? | **No.** Polimorfismo por `provisioningid`. Implementar los dos `load()`. |
| ¿El caso anidado necesita más que un disco vacío? | Para *ver* el disco: no. Para *datastore listo*: sí (fase 2 o NAS existente). |
| ¿Capture? | Extra ephemeral; **arreglar** el fail de VMware con múltiples vmdk. |

Cuando este plan esté aprobado, la implementación puede seguir las fases 1a–1d sin reabrir el modelo de datos.
)
