#!/bin/sh
# Run ONLY on an expendable OpenWrt target. Never on a development host.
set -eu
[ "${GETDOMAINS_ALLOW_DESTRUCTIVE_TESTS:-}" = 1 ] || exit 2
[ "$#" = 2 ] || exit 2
action=$1 backup=$2
case "$backup" in /root/getdomains-lifecycle-*) ;; *) exit 2 ;; esac
case "$backup" in *[!a-zA-Z0-9/_-]*) exit 2 ;; esac
files='/etc/config/network /etc/config/firewall /etc/config/dhcp /etc/sing-box/config.json /etc/getdomains/domains.source /sbin/fw4 /sbin/reload_config /etc/init.d/network /usr/share/ucode/luci/controller/admin/uci.uc'
case "$action" in
    setup)
        test ! -e "$backup"
        test ! -e /tmp/gd-life-lab
        [ "$(uci -q get firewall.@defaults[0].flow_offloading)" = 0 ]
        if cat /sys/kernel/debug/ppe0/bind /sys/kernel/debug/ppe1/bind | grep -q ' BND '; then exit 1; fi
        mkdir -m 700 "$backup"
        for file in $files; do cp -p "$file" "$backup/$(echo "$file" | tr / _)"; done
        sha256sum $files > "$backup/hashes.before"
        apk info -v 2>/dev/null | sort > "$backup/packages.before"
        {
            printf '#!/bin/sh\nset -eu\nw=%s\n' "$backup"
            printf 'for file in %s; do\n' "$files"
            printf ' cp -p "$w/$(echo "$file" | tr / _)" "$file"\ndone\n'
            printf 'rm -f /usr/share/ucode/luci/controller/admin/gd_offload_lab.uc /usr/share/luci/menu.d/zz-getdomains-offload-lab.json\nreboot\n'
        } > "$backup/restore.sh"
        ;;
    rearm)
        sha256sum -c "$backup/hashes.before"
        test ! -e /tmp/gd-life-lab
        ;;
    restore)
        touch "$backup/watchdog.stop"
        exec sh "$backup/restore.sh"
        ;;
    *) exit 2 ;;
esac
mkdir -m 700 /tmp/gd-life-lab
rm -f "$backup/watchdog.stop"
( trap "" HUP; sleep 3600; [ -f "$backup/watchdog.stop" ] || sh "$backup/restore.sh" ) > "$backup/watchdog.log" 2>&1 < /dev/null &
ip link add gd-life-sync0 type veth peer name gd-life-sync1
ip link set dev gd-life-sync0 up
ip link set dev gd-life-sync0 down
printf 'READY\n'
