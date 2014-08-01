#!/bin/sh
# -*- mode: shell-script; indent-tabs-mode: nil; sh-basic-offset: 4; -*-
# ex: ts=8 sw=4 sts=4 et filetype=sh

# NFS root might have reached here before /tmp/net.ifaces was written
type is_persistent_ethernet_name >/dev/null 2>&1 || . /lib/net-lib.sh

udevadm settle --timeout=30

if [ -e /tmp/bridge.info ]; then
    . /tmp/bridge.info
fi

if [ -e /tmp/vlan.info ]; then
    . /tmp/vlan.info
fi

mkdir -m 0755 -p /tmp/ifcfg/
mkdir -m 0755 -p /tmp/ifcfg-leases/

get_config_line_by_subchannel()
{
    local CHANNEL
    local line

    CHANNELS="$1"
    while read line; do
        if strstr "$line" "$CHANNELS"; then
            echo $line
            return 0
        fi
    done < /etc/ccw.conf
    return 1
}

print_s390() {
    local _netif
    local SUBCHANNELS
    local OPTIONS
    local NETTYPE
    local CONFIG_LINE
    local i
    local channel
    local OLD_IFS

    _netif="$1"
    # if we find ccw channel, then use those, instead of
    # of the MAC
    SUBCHANNELS=$({
        for i in /sys/class/net/$_netif/device/cdev[0-9]*; do
            [ -e $i ] || continue
            channel=$(readlink -f $i)
            echo -n "${channel##*/},"
        done
    })
    [ -n "$SUBCHANNELS" ] || return 1

    SUBCHANNELS=${SUBCHANNELS%,}
    echo "SUBCHANNELS=\"${SUBCHANNELS}\""

    CONFIG_LINE=$(get_config_line_by_subchannel $SUBCHANNELS)
    [ $? -ne 0 -o -z "$CONFIG_LINE" ] && return 0

    OLD_IFS=$IFS
    IFS=","
    set -- $CONFIG_LINE
    IFS=$OLD_IFS
    NETTYPE=$1
    shift
    SUBCHANNELS="$1"
    OPTIONS=""
    shift
    while [ $# -gt 0 ]; do
        case $1 in
            *=*) OPTIONS="$OPTIONS $1";;
        esac
        shift
    done
    OPTIONS=${OPTIONS## }
    echo "NETTYPE=\"${NETTYPE}\""
    echo "OPTIONS=\"${OPTIONS}\""
    return 0
}

for netup in /tmp/net.*.did-setup ; do
    [ -f $netup ] || continue

    netif=${netup%%.did-setup}
    netif=${netif##*/net.}
    strstr "$netif" ":*:*:*:*:" && continue
    [ -e /tmp/ifcfg/ifcfg-$netif ] && continue
    unset bridge
    unset bond
    unset bondslaves
    unset bondname
    unset bondoptions
    unset uuid
    unset ip
    unset gw
    unset mtu
    unset mask
    unset macaddr
    unset slave
    unset ethname
    [ -e /tmp/bond.${netif}.info ] && . /tmp/bond.${netif}.info

    uuid=$(cat /proc/sys/kernel/random/uuid)
    if [ "$netif" = "$bridgename" ]; then
        bridge=yes
    elif [ "$netif" = "$bondname" ]; then
    # $netif can't be bridge and bond at the same time
        bond=yes
    fi
    if [ "$netif" = "$vlanname" ]; then
        vlan=yes
    fi
    [ -e /sys/class/net/$netif/address ] && \
        cat /sys/class/net/$netif/address > /tmp/net.$netif.hwaddr
    {
        echo "# Generated by dracut initrd"
        echo "DEVICE=\"$netif\""
        echo "ONBOOT=yes"
        echo "NETBOOT=yes"
        echo "UUID=\"$uuid\""
        strstr "$(ip -6 addr show dev $netif)" 'inet6' && echo "IPV6INIT=yes"
        if [ -f /tmp/dhclient.$netif.lease ]; then
            [ -f /tmp/dhclient.$netif.dhcpopts ] && . /tmp/dhclient.$netif.dhcpopts
            if [ -f /tmp/net.$netif.has_ibft_config ]; then
                echo "BOOTPROTO=ibft"
            else
                echo "BOOTPROTO=dhcp"
            fi
            cp /tmp/dhclient.$netif.lease /tmp/ifcfg-leases/dhclient-$uuid-$netif.lease
        else
            # If we've booted with static ip= lines, the override file is there
            [ -e /tmp/net.$netif.override ] && . /tmp/net.$netif.override
            if strstr "$ip" '*:*:*'; then
                echo "IPV6INIT=yes"
                echo "IPV6_AUTOCONF=no"
                echo "IPV6ADDR=\"$ip/$mask\""
            else
                if [ -f /tmp/net.$netif.has_ibft_config ]; then
                    echo "BOOTPROTO=ibft"
                else
                    echo "BOOTPROTO=none"
                    echo "IPADDR=\"$ip\""
                    if strstr "$mask" "."; then
                        echo "NETMASK=\"$mask\""
                    else
                        echo "PREFIX=\"$mask\""
                    fi
                fi
            fi
            if strstr "$gw" '*:*:*'; then
                echo "IPV6_DEFAULTGW=\"$gw\""
            elif [ -n "$gw" ]; then
                echo "GATEWAY=\"$gw\""
            fi
        fi
        [ -n "$mtu" ] && echo "MTU=\"$mtu\""
    } > /tmp/ifcfg/ifcfg-$netif

    # bridge needs different things written to ifcfg
    if [ -z "$bridge" ] && [ -z "$bond" ] && [ -z "$vlan" ]; then
        # standard interface
        {
            [ -n "$macaddr" ] && echo "MACADDR=\"$macaddr\""
            if ! print_s390 $netif; then
                if [ -z "$macaddr" ] && \
                    ! is_persistent_ethernet_name "$netif" && \
                    [ -f /sys/class/net/$netif/addr_assign_type ] && \
                    [ "$(cat /sys/class/net/$netif/addr_assign_type)" = "0" ] && \
                    [ -f /sys/class/net/$netif/address ]; then
                    echo "HWADDR=\"$(cat /sys/class/net/$netif/address)\""
                fi
            fi
            echo "TYPE=Ethernet"
            echo "NAME=\"$netif\""
            [ -n "$mtu" ] && echo "MTU=\"$mtu\""
        } >> /tmp/ifcfg/ifcfg-$netif
    fi

    if [ -n "$vlan" ] ; then
        {
            echo "TYPE=Vlan"
            echo "NAME=\"$netif\""
            echo "VLAN=yes"
            echo "PHYSDEV=\"$phydevice\""
        } >> /tmp/ifcfg/ifcfg-$netif
    fi

    if [ -n "$bond" ] ; then
        # bond interface
        {
            # This variable is an indicator of a bond interface for initscripts
            echo "BONDING_OPTS=\"$bondoptions\""
            echo "NAME=\"$netif\""
            echo "TYPE=Bond"
        } >> /tmp/ifcfg/ifcfg-$netif

        for slave in $bondslaves ; do
            # write separate ifcfg file for the raw eth interface
            {
                echo "# Generated by dracut initrd"
                echo "DEVICE=\"$slave\""
                echo "TYPE=Ethernet"
                echo "ONBOOT=yes"
                echo "NETBOOT=yes"
                if [ -e /tmp/net.${netif}.${slave}.hwaddr ]; then
                   echo "HWADDR=\"$(cat /tmp/net.${netif}.${slave}.hwaddr)\""
                else
                   echo "HWADDR=\"$(cat /sys/class/net/$slave/address)\""
                fi
                echo "SLAVE=yes"
                echo "MASTER=\"$netif\""
                echo "NAME=\"$slave\""
                echo "UUID=\"$(cat /proc/sys/kernel/random/uuid)\""
            } >> /tmp/ifcfg/ifcfg-$slave
        done
    fi

    if [ -n "$bridge" ] ; then
        # bridge
        {
            echo "TYPE=Bridge"
            echo "NAME=\"$netif\""
        } >> /tmp/ifcfg/ifcfg-$netif
        for slave in $bridgeslaves ; do
            # write separate ifcfg file for the raw eth interface
            {
                echo "# Generated by dracut initrd"
                echo "DEVICE=\"$slave\""
                echo "TYPE=Ethernet"
                echo "ONBOOT=yes"
                echo "NETBOOT=yes"
                echo "HWADDR=\"$(cat /sys/class/net/$slave/address)\""
                echo "SLAVE=yes"
                echo "MASTER=\"$bridgename\""
                echo "NAME=\"$slave\""
                echo "UUID=\"$(cat /proc/sys/kernel/random/uuid)\""
            } >> /tmp/ifcfg/ifcfg-$slave
        done
    fi
    i=1
    for ns in $(getargs nameserver); do
        echo "DNS${i}=\"${ns}\"" >> /tmp/ifcfg/ifcfg-$netif
        i=$((i+1))
    done

    [ -f /tmp/net.route6."$netif" ] && cp /tmp/net.route6."$netif" /tmp/ifcfg/route6-"$netif"
    [ -f /tmp/net.route."$netif" ] && cp /tmp/net.route."$netif" /tmp/ifcfg/route-"$netif"
done

# Pass network opts
mkdir -m 0755 -p /run/initramfs/state/etc/sysconfig/network-scripts
mkdir -m 0755 -p /run/initramfs/state/var/lib/dhclient
echo "files /etc/sysconfig/network-scripts" >> /run/initramfs/rwtab
echo "files /var/lib/dhclient" >> /run/initramfs/rwtab
{
    cp /tmp/net.* /run/initramfs/
    cp /tmp/net.$netif.resolv.conf /run/initramfs/state/etc/resolv.conf
    copytree /tmp/ifcfg /run/initramfs/state/etc/sysconfig/network-scripts
    cp /tmp/ifcfg-leases/* /run/initramfs/state/var/lib/dhclient
} > /dev/null 2>&1
