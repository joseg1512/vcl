# Firewall de las computadoras Linux (Ubuntu y Red Hat)

VCL configura el firewall de las computadoras Linux en cada etapa de la reserva. Este documento describe el comportamiento actual, las dos claves de `vcld.conf` que definen el origen permitido y los requisitos de las imágenes.

## Comportamiento

Cuando el usuario hace clic en Connect, los puertos de los connect methods de la imagen (SSH, RDP) se abren al origen que indica la configuración del nodo de gestión:

- `button` (por defecto): los puertos se abren solo a la dirección que hizo el Connect, guardada en `reservation.remoteIP`. Es el comportamiento estándar de VCL.
- `ip_range`: los puertos se abren al rango configurado, tanto en la etapa `reserved` como en la etapa `inuse`.

## Etapas y cadenas

El módulo `managementnode/lib/VCL/Module/OS/Linux/firewall/iptables.pm` crea una cadena por etapa y una regla en `INPUT` que salta a ella:

- `post_load`: cadena `vcl-post_load`, permite el tráfico desde las IPs de la máquina de gestión.
- `reserved`: cadena `vcl-reserved`, abre los puertos de los connect methods al origen de la etapa (sin restricción en modo `button`).
- `inuse` (al hacer Connect): cadena `vcl-inuse`, abre esos puertos al origen de la etapa y borra `vcl-reserved`.
- `sanitize` y `pre_capture`: cierran y limpian las cadenas.

Las reglas se insertan al principio de `INPUT` (`iptables --insert`), por encima de las reglas que la imagen pudiera tener.

## Configuración en `vcld.conf`

Se configura en `/etc/vcl/vcld.conf` del nodo de gestión. La plantilla instalada (`managementnode/etc/vcl/vcld.conf`) ya trae las dos claves documentadas; eso aplica a una instalación nueva. En una actualización, `vcl-upgrade.sh` no toca `/etc/vcl/vcld.conf`: hay que agregarlas a mano. Si faltan, el comportamiento es el actual (modo `button`), sin error.

| `CONNECT_MODE` | `CONNECT_IP_RANGE` | Origen en `reserved` | Origen en `inuse` |
| --- | --- | --- | --- |
| ausente, vacío o `button` | se ignora | sin restricción | `reservation.remoteIP` |
| `ip_range` | rango IPv4 | el rango | el rango |

`CONNECT_IP_RANGE` es IPv4 únicamente y acepta:

| Valor | Equivale a | Efecto |
| --- | --- | --- |
| `10.0.0.0/8`, `192.168.0.0/24` | igual | esa red |
| `10.0.0.7` (sin máscara) | `10.0.0.7/32` | esa dirección sola |
| `0.0.0.0` | `0.0.0.0/0` | cualquier dirección IPv4 |

Ejemplos:

```sh
# comportamiento estándar de VCL: solo la IP que hizo el Connect
CONNECT_MODE=button

# solo la red del campus, en reserved y en inuse
CONNECT_MODE=ip_range
CONNECT_IP_RANGE=10.0.0.0/8

# cualquier dirección IPv4 (útil detrás de una VPN que ya filtra)
CONNECT_MODE=ip_range
CONNECT_IP_RANGE=0.0.0.0

# una sola dirección
CONNECT_MODE=ip_range
CONNECT_IP_RANGE=10.0.0.7
```

Los valores se leen cuando se carga el módulo, al arrancar `vcld`: hay que reiniciar el demonio para que un cambio tenga efecto. Las reservas en curso no se ven afectadas hasta el siguiente Connect.

Un valor inválido no impide la reserva: el módulo cae a modo `button` y deja un `WARNING` en el log del nodo de gestión (`/var/log/vcld.log`). Eso cubre un modo desconocido, `ip_range` sin rango y un rango que no es una IPv4 válida.

Ojo con dos consecuencias de ese fallback: un `CONNECT_IP_RANGE` inválido con `CONNECT_MODE=button` no genera ningún `WARNING`, porque en modo `button` el rango ni se lee; y caer a `button` deja la etapa `reserved` abierta a cualquier dirección alcanzable (solo `inuse` queda limitada a la IP que hizo el Connect). Si esperaba un rango, verifique `/var/log/vcld.log` antes de asumir que se aplicó.

## Selección del módulo

`Linux.pm` usa únicamente `iptables.pm`. Antes se recorrían los archivos del directorio con `find` y se usaba el primero que inicializara, lo que hacía la selección dependiente del sistema de archivos: en Ubuntu podía ganar `ufw.pm` (que no inserta reglas de reserva) y en Red Hat `firewalld.pm` en lugar de `iptables.pm`.

`ufw.pm` y `firewalld.pm` quedan en el repositorio como referencia, pero no se seleccionan.

## Requisitos de las imágenes

- Tener el comando `iptables` instalado: paquete `iptables` en Ubuntu, `iptables-nft` en Red Hat 8, 9 y 10.
- Tener el módulo del kernel `xt_comment`, que implementa `--match comment` y que las reglas de VCL usan en el comentario de cada regla. En Red Hat 10 viene en el paquete `kernel-modules-extra` (de la misma versión del kernel en ejecución). Si falta, la inserción falla con "Extension comment revision 0 not supported, missing kernel module?" y VCL no puede instalar sus reglas. Verificar con `modprobe xt_comment` y `lsmod | grep xt_comment`.
- Construir la imagen con `systemctl disable --now ufw` (Ubuntu) y `systemctl disable --now firewalld` (Red Hat). VCL además lo verifica y lo desactiva en `post_load` si el servicio está activo, para cubrir imágenes capturadas antes de este cambio.

Con eso, las reglas de VCL son las únicas que se evalúan durante la reserva.

## Rollback

Volver al comportamiento estándar de VCL:

```sh
CONNECT_MODE=button
```

y reiniciar `vcld`. No requiere cambios de código ni volver a desplegar.

## Fuera de alcance

- IPv6: VCL maneja solo `iptables` (IPv4). En modo `button` el origen es la IPv4 de `reservation.remoteIP`; si el Connect llega por IPv6 no hay regla IPv6 que aplicar y el acceso queda sujeto a las reglas de la imagen. Replicar el comportamiento con `ip6tables` no está implementado.
- Windows Server: el mismo comportamiento requiere reglas de `netsh` con `scope = ALL` para abrir a cualquier origen, y ese valor solo se aplica cuando el origen es exactamente `0.0.0.0/0.0.0.0`. No está implementado: `CONNECT_MODE` y `CONNECT_IP_RANGE` solo afectan a las computadoras Linux.

## Verificación

```sh
iptables -L INPUT -n
iptables -L vcl-inuse -n
iptables -S | grep vcl
systemctl is-active ufw      # inactive en Ubuntu
systemctl is-active firewalld # inactive en Red Hat
```

Desde otra máquina de la red: en modo `button` solo la que hizo el Connect debe alcanzar el puerto de SSH o RDP hasta el login; en modo `ip_range`, cualquier dirección del rango debe alcanzarlo.

## Tests

No hay runner en CI: los tests se corren a mano, desde la raíz del repositorio.

```sh
perl managementnode/tests/firewall/test_vcld_conf.pl
perl managementnode/tests/firewall/test_allowed_source.pl
perl managementnode/tests/firewall/test_ubuntu_paths.pl
managementnode/tests/run_firewall_tests.sh
```

`test_vcld_conf.pl` verifica que las claves se lean del archivo de configuración (y que ausentes queden indefinidas), `test_allowed_source.pl` cubre la resolución del origen por modo, rango y etapa, y `test_ubuntu_paths.pl` cubre con stubs las decisiones de las rutas Ubuntu (desactivar `ufw`/`firewalld` y la ruta del archivo de `iptables-save`). Todos imprimen una línea por caso y salen con código distinto de cero si algún caso falla; `run_firewall_tests.sh` corre los tres y devuelve el peor código de salida.
