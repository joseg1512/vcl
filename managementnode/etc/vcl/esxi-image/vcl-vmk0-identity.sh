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
#   scripts de ese directorio en cada arranque). Empareja cada VMkernel con el
#   NIC fisico que le corresponde (vmk0 con vmnic0, vmk1 con vmnic1) y, si la
#   MAC no coincide con la del clon, recrea la interfaz con la MAC del NIC
#   fisico y vuelve a pedir DHCP. Es idempotente: si coinciden no hace nada.
#
#   La MAC del NIC fisico del clon es unica por computadora porque VCL la define
#   en la fila de la computadora y VMware.pm la escribe en el .vmx.
#
# SEGURIDAD
#   Es preferible un nodo con la identidad vieja que un nodo sin interfaz de
#   gestion. Por eso: si no se puede determinar el portgroup, o el portgroup
#   detectado no existe, NO se toca nada; y si tras recrear la interfaz esta no
#   aparece, se reintenta con el portgroup por defecto. Todo queda en el log del
#   guest (tag vcl-identity).
PATH=/sbin:/bin:/usr/sbin:/usr/bin
command -v esxcli >/dev/null 2>&1 || exit 0

sync_vmk() {
    vmk="$1"
    pnic="$2"
    pg_default="$3"

    pnic_mac=$(esxcli network nic list 2>/dev/null | awk -v n="$pnic" '$1 == n {print $8; exit}')
    [ -n "$pnic_mac" ] || return 0

    vmk_mac=$(esxcli network ip interface list 2>/dev/null | awk -v n="$vmk" '$0 ~ ("Name: " n "$") {f=1} f && /MAC Address:/ {print $3; exit}')
    [ "$vmk_mac" = "$pnic_mac" ] && return 0

    pg=$(esxcli network ip interface list 2>/dev/null | awk -v n="$vmk" '$0 ~ ("Name: " n "$") {f=1} f && /Portgroup:/ {print $2; exit}')
    [ -n "$pg" ] || pg="$pg_default"

    # El portgroup tiene que existir; si no, no se toca la interfaz.
    if ! esxcli network vswitch standard portgroup list 2>/dev/null | grep -q "[[:space:]]$pg$"; then
        logger -t vcl-identity "$vmk: portgroup '$pg' no encontrado, no se modifica"
        return 0
    fi

    logger -t vcl-identity "$vmk MAC '${vmk_mac:-ausente}' != $pnic $pnic_mac: recreando en '$pg'"
    esxcli network ip interface remove --interface-name="$vmk" >/dev/null 2>&1
    esxcli network ip interface add --interface-name="$vmk" --portgroup-name="$pg" --mac-address="$pnic_mac" >/dev/null 2>&1

    if ! esxcli network ip interface list 2>/dev/null | grep -q "Name: $vmk$"; then
        logger -t vcl-identity "$vmk: fallo la recreacion en '$pg', reintentando en '$pg_default'"
        esxcli network ip interface add --interface-name="$vmk" --portgroup-name="$pg_default" --mac-address="$pnic_mac" >/dev/null 2>&1
    fi

    if esxcli network ip interface list 2>/dev/null | grep -q "Name: $vmk$"; then
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
