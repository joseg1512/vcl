# Imagen ESXi anidada (multi-instancia): hook de identidad de red

## Qué es

`vcl-vmk0-identity.sh` es el hook de arranque de las imágenes de ESXi anidado.
Se instala en `/etc/rc.local.d/` (ESXi ejecuta en cada arranque los archivos
ejecutables de ese directorio, en orden alfabético).

El problema que resuelve: el guest de un ESXi anidado conserva en su
configuración las MACs de sus interfaces VMkernel (vmk0 y vmk1) tal como
estaban al capturar la imagen, y **no** las re-deriva del NIC del clon. Como el
DHCP del nodo de gestión entrega la IP privada **según la MAC**, todos los
clones piden la misma IP y solo el primer nodo puede ser alcanzado: de una
misma imagen no se pueden reservar dos instancias a la vez.

El hook empareja cada VMkernel con su NIC física (vmk0↔vmnic0, vmk1↔vmnic1) y,
si la MAC no coincide con la del clon, recrea la interfaz con la MAC del NIC
físico (única por computadora: VCL la define en la fila de la computadora y
`VMware.pm` la escribe en el `.vmx`) y vuelve a pedir DHCP. Es idempotente: si
coinciden, no hace nada.

La IP pública de vmk1 la re-fija el `post_load` de VCL en cada carga
(`set_static_public_address`), así que recrear vmk1 durante el arranque no
rompe la configuración de cada computadora.

## Instalación en una imagen (antes de capturarla)

1. Con la sesión de construcción cargada, copiar el hook por la IP pública del
   nodo y hacerlo ejecutable:

   ```sh
   scp vcl-vmk0-identity.sh root@<ip-publica>:/etc/rc.local.d/
   ssh root@<ip-publica> chmod +x /etc/rc.local.d/vcl-vmk0-identity.sh
   ```

2. Verificar que el shell del guest lo acepte (sin salida = OK):

   ```sh
   ssh root@<ip-publica> 'sh -n /etc/rc.local.d/vcl-vmk0-identity.sh'
   ```

3. Validarlo EN EL GUEST (sección siguiente). Si no pasa, **no capturar**.

4. **Empaquetar el hook como módulo de arranque** (esto es lo que lo hace
   viajar en la imagen; verificado end-to-end en el guest):

   ```sh
   cd / && tar czf /bootbank/vclhook.tgz etc/rc.local.d/vcl-vmk0-identity.sh
   grep -q vclhook.tgz /bootbank/boot.cfg || \
     sed -i 's/^modules=\(.*state\.tgz\)$/modules=\1 --- vclhook.tgz/' /bootbank/boot.cfg
   sync
   ```

   ¿Por qué?: en ESXi 8 `/etc` se reconstruye en **cada arranque** a partir de
   los módulos `.v00` del bootbank + el estado (`state.tgz`), y el estado solo
   aplica los archivos "rastreados" del sistema (`esx.conf`, leases,
   certificados…). Un archivo nuevo en `/etc/rc.local.d` **no entra al estado ni
   sobrevive un reboot** (medido en el guest: desaparece, incluso después de un
   `auto-backup.sh` manual; los marcadores `.#archivo` del overlay no se pueden
   crear a mano). En cambio `boot.cfg` y `/bootbank/*` son **contenido físico
   del disco**: viajan en la copia de la captura, y el cargador de cada clon
   extrae el `.tgz` en `/` durante el arranque, dejando el hook en
   `/etc/rc.local.d/` **antes** de que corra el runner de rc.local.d. En el
   syslog del guest se ve: `init Running vcl-vmk0-identity.sh` y
   `Completed vcl-vmk0-identity.sh (exit 0)`. La ruta del `.tgz` dentro del
   tar es `etc/rc.local.d/vcl-vmk0-identity.sh` (relativa, sin `./`).

5. (recomendado) Reiniciar el guest y comprobar que el hook reaparece y actúa:

   ```sh
   esxcli system shutdown reboot --delay=10 --reason="validacion hook"
   # unos minutos después, por la IP privada:
   ls -l /etc/rc.local.d/vcl-vmk0-identity.sh
   grep "vcl-vmk0-identity" /var/log/syslog.log | tail -3
   ```

6. Correr `sh /sbin/auto-backup.sh` (deja consistente el resto del estado
   rastreado: `esx.conf`, leases), y capturar la imagen.

   Nota: `auto-backup.sh` **no** incluye al hook (no es un archivo rastreado);
   es el módulo del paso 4 lo que lo persiste. El auto-backup se mantiene por
   los demás archivos de estado.

## Validación obligatoria antes de cada captura

Regla de oro: un hook que toca la red del huésped se valida **dentro** del
huésped antes de capturarlo, y la validación no puede cortarse su propio
acceso. Ojo: el hook recrea también vmk1, así que la IP pública de esa sesión
se pierde al correrlo; los pasos previos se hacen por la IP pública y la
verificación final por la IP privada, que debe volver sola por DHCP.

1. Leer el estado (por la IP pública): MAC del NIC privado del clon
   (`esxcli network nic list | awk '/^vmnic0/ {print $8}'`) y la MAC y el
   portgroup actuales de vmk0.
2. Romper vmk0 a propósito, con una MAC del mismo rango que el NIC:

   ```sh
   esxcli network ip interface remove --interface-name=vmk0
   esxcli network ip interface add --interface-name=vmk0 \
       --portgroup-name="Management Network" --mac-address=52:54:00:b1:28:fe
   ```

3. Ejecutar el hook (por la IP pública):
   `/etc/rc.local.d/vcl-vmk0-identity.sh`
4. Esperar (~1 min) y comprobar **por la IP privada** que:
   - vmk0 volvió a la MAC del NIC del clon y tiene IP privada (`10.100.0.x`) por DHCP;
   - vmk1 quedó con la MAC del NIC público del clon;
   - el log del guest lo confirma:
     `grep vcl-identity /var/log/syslog.log` muestra las líneas
     "recreando en ...".
5. Correr el hook una segunda vez: no debe cambiar nada (idempotencia).

## Trampas conocidas (costaron horas; no repetirlas)

- El busybox del ESXi **no tiene `command` ni `command -v`** (rc 127): un guard
  del estilo `command -v esxcli || exit 0` sale **en silencio** sin hacer nada
  (síntoma: el hook corre con rc=0 pero no pasa nada y no deja log). Usar
  `[ -x /bin/esxcli ]`.
- El nombre del portgroup puede tener espacios ("Management Network"): hay que
  tomar **todo lo que sigue** a "Portgroup: " y no un campo de la línea.
- La salida de `esxcli network vswitch standard portgroup list` trae el nombre
  en la **primera** columna: para chequear existencia, cortar en el primer
  grupo de 2+ espacios y comparar exacto; un patrón que espere el nombre al
  final de la línea no matchea nunca.
- El log del hook va al syslog del guest (`/var/log/syslog.log`, tag
  `vcl-identity`). En ESXi no existe `/var/log/messages`.
- No validar conectándose por vmk0 si la prueba toca vmk0: se corta el propio
  acceso (falso negativo).
- ESXi rechaza MACs fuera del rango del host al recrear un vmk: usar MACs del
  mismo rango que el NIC (las de este proyecto lo están).
