#!/bin/sh
# VCL - identidad de red del ESXi anidado (multi-instancia)
#
# PROBLEMA
#   El guest de un ESXi anidado conserva en su configuracion las MACs de sus
#   interfaces VMkernel (vmk0 de gestion, vmk1 publica) tal como estaban cuando
#   se capturo la imagen, y NO las re-deriva del NIC del clon. Como el DHCP del
#   nodo de gestion entrega la IP privada segun la MAC, todos los clones piden
#   la misma IP y solo el primer nodo puede ser alcanzado.
#
# SOLUCION
#   Este script se instala en la imagen, en /etc/rc.local.d/ (ESXi ejecuta los
#   archivos ejecutables de ese directorio en cada arranque, en orden
#   alfabetico). Empareja cada VMkernel con el NIC fisico que le corresponde
#   (vmk0 con vmnic0, vmk1 con vmnic1) y, si la MAC no coincide con la del
#   clon, recrea la interfaz con la MAC del NIC fisico y vuelve a pedir DHCP.
#   Es idempotente: si coinciden no hace nada.
#
#   La MAC del NIC fisico del clon es unica por computadora porque VCL la define
#   en la fila de la computadora y VMware.pm la escribe en el .vmx. La
#   direccion publica de vmk1 la vuelve a fijar el post_load de VCL despues del
#   arranque (set_static_public_address).
#
# SEGURIDAD
#   Es preferible un nodo con la identidad vieja que un nodo sin interfaz de
#   gestion. Por eso: si no se puede determinar el portgroup, o el portgroup
#   detectado no existe, NO se toca la interfaz; y si tras recrear la interfaz
#   no queda con la MAC esperada, se reintenta con el portgroup por defecto.
#   Todo queda en el log del guest (tag vcl-identity).
PATH=/sbin:/bin:/usr/sbin:/usr/bin
# OJO: el busybox del ESXi no tiene `command` ni `command -v` (da rc=127), asi
# que un "command -v esxcli || exit 0" saldria SIEMPRE en silencio sin hacer
# nada (paso de verdad: por eso este hook no actuaba y solo se veia rc=0).
# Se chequea el binario directo.
[ -x /bin/esxcli ] || { logger -t vcl-identity "esxcli no encontrado, no se verifica la identidad"; exit 0; }

# Al arrancar, rc.local.d puede ejecutarse antes de que hostd termine de
# responder: esperar (acotado, 60s) a que esxcli funcione para no decidir
# sobre una salida incompleta.
ready=0
intentos=0
while [ "$intentos" -lt 30 ]; do
    if esxcli network nic list >/dev/null 2>&1 && esxcli network ip interface list >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 2
    intentos=$((intentos + 1))
done
[ "$ready" = "1" ] || {
    logger -t vcl-identity "CRITICO: esxcli no respondio en 60s; no se verifica la identidad de red"
    exit 0
}

vmk_mac_actual() {
    esxcli network ip interface list 2>/dev/null | awk -v n="$1" '$0 ~ ("Name: " n "$") {f=1} f && /MAC Address:/ {print $3; exit}'
}

vmk_portgroup() {
    # El nombre del portgroup puede tener espacios ("Management Network"): se
    # toma todo lo que sigue a "Portgroup: " y no el segundo campo.
    esxcli network ip interface list 2>/dev/null | awk -v n="$1" '$0 ~ ("Name: " n "$") {f=1} f && /Portgroup:/ {sub(/^[ \t]*Portgroup:[ \t]*/, ""); print; exit}'
}

portgroup_existe() {
    # La salida lista el nombre en la primera columna ("Management Network  vSwitch0 ..."):
    # se corta cada linea en el primer grupo de 2+ espacios y se compara exacto.
    # (El chequeo anterior grep "[[:space:]]$pg$" no podia matchear nunca: el
    #  nombre no esta al final de la linea, asi que el hook no hacia nada.)
    esxcli network vswitch standard portgroup list 2>/dev/null | awk 'NR>1{sub(/  +.*/, ""); print}' | grep -qxF "$1"
}

sync_vmk() {
    vmk="$1"
    pnic="$2"
    pg_default="$3"

    pnic_mac=$(esxcli network nic list 2>/dev/null | awk -v n="$pnic" '$1 == n {print $8; exit}')
    [ -n "$pnic_mac" ] || return 0

    vmk_mac=$(vmk_mac_actual "$vmk")
    [ "$vmk_mac" = "$pnic_mac" ] && return 0

    pg=$(vmk_portgroup "$vmk")
    [ -n "$pg" ] || pg="$pg_default"

    if ! portgroup_existe "$pg"; then
        logger -t vcl-identity "$vmk: portgroup '$pg' no encontrado, no se modifica"
        return 0
    fi

    logger -t vcl-identity "$vmk MAC '${vmk_mac:-ausente}' != $pnic $pnic_mac: recreando en '$pg'"
    esxcli network ip interface remove --interface-name="$vmk" >/dev/null 2>&1
    esxcli network ip interface add --interface-name="$vmk" --portgroup-name="$pg" --mac-address="$pnic_mac" >/dev/null 2>&1

    if [ "$(vmk_mac_actual "$vmk")" != "$pnic_mac" ]; then
        logger -t vcl-identity "$vmk: fallo la recreacion en '$pg', reintentando en '$pg_default'"
        esxcli network ip interface remove --interface-name="$vmk" >/dev/null 2>&1
        esxcli network ip interface add --interface-name="$vmk" --portgroup-name="$pg_default" --mac-address="$pnic_mac" >/dev/null 2>&1
    fi

    if [ -n "$(vmk_mac_actual "$vmk")" ]; then
        esxcli network ip interface ipv4 set --interface-name="$vmk" --type=dhcp >/dev/null 2>&1
        esxcli network firewall ruleset set --ruleset-id=dhcp --enabled true >/dev/null 2>&1
    else
        logger -t vcl-identity "CRITICO: $vmk quedo ausente; revisar el nodo"
    fi
    return 0
}

# vmk0 = red privada de gestion (vmnic0) | vmk1 = red publica (vmnic1)
sync_vmk vmk0 vmnic0 "Management Network"
sync_vmk vmk1 vmnic1 "VM Network"
exit 0
