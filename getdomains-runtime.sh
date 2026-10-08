#!/bin/sh
# Device actions are deliberately separate from the pure awk compiler.
# OpenWrt's /lib/functions.sh intentionally reads unset optional variables.
set -e

ROOT=/etc/getdomains
COMPILER=/usr/libexec/getdomains-compile.awk
PENDING=/tmp/getdomains-restart-pending
STATIC=/tmp/getdomains-static.nft
GUARDS=/tmp/getdomains-wdns-guards
log() { logger -t getdomains "$*"; }
restart_dnsmasq() { /etc/init.d/dnsmasq restart; }
reload_network() { /etc/init.d/network reload; }

load_config_snapshot() {
    # libuci loads one package into shell variables; never eval textual uci output.
    . /lib/functions.sh
    config_load firewall
    config_foreach set_family ipset > "$work/families"
    config_load dhcp
}
first_dnsmasq() { [ -n "$instance" ] || instance=$1; }
snapshot() {
    load_config_snapshot || return 1
    instance=
    config_foreach first_dnsmasq dnsmasq
    [ -n "$instance" ] || { printf 'E\tNo dnsmasq instance configured\n'; return 0; }
    config_get options wdns dhcp_option
    wdns=
    for option in $options; do
        case $option in 6,*) wdns=${option#6,}; break;; esac
    done
    if [ -n "$wdns" ] && ! printf '%s\n' "$wdns" | awk -F. '
        NF!=4 {exit 1} {for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || $i>255 || (length($i)>1 && substr($i,1,1)=="0")) exit 1}'; then
        printf 'E\twdns must contain one IPv4 DNS server\n'
        wdns=
    fi
    ipv6=0
    uci -q get firewall.vpn_domains6 >/dev/null && ipv6=1
    config_foreach ipsets ipset
    config_get servers "$instance" server
    config_get addresses "$instance" address
    config_get local_zone "$instance" local
    for entry in $servers $addresses "$local_zone"; do
        case $entry in
            /*) zones=${entry%/*}; zones=${zones#/}
                if [ -z "$zones" ]; then printf 'X\t*\n'; fi
                old_ifs=$IFS; IFS=/
                for zone in $zones; do
                    case $zone in '#') printf 'X\t*\n';; *) printf 'X\t%s\n' "$zone";; esac
                done
                IFS=$old_ifs;;
        esac
    done
    for entry in $addresses; do
        case $entry in /*/*)
            ip=${entry##*/}; zones=${entry%/*}; zones=${zones#/}
            old_ifs=$IFS; IFS=/
            for zone in $zones; do
                case $zone in '#') zone='*';; esac
                printf 'P\t%s\t%s\n' "$zone" "$ip"
            done
            IFS=$old_ifs;;
        esac
    done
    config_foreach hosts domain
    config_foreach hostrecords hostrecord
    config_foreach cnames cname
    # Metadata is consumed by compile(), not passed through as dnsmasq syntax.
    printf 'S\t%s\t%s\n' "$wdns" "$ipv6"
}
set_family() {
    config_get set_name "$1" name "$1"
    config_get set_af "$1" family
    case $set_af in ipv4) printf '%s\t4\n' "$set_name";; ipv6) printf '%s\t6\n' "$set_name";; esac
}
applies() {
    config_get bound "$1" instance
    [ -z "$bound" ] || [ "$bound" = "$instance" ]
}
ipsets() {
    applies "$1" || return 0
    config_get names "$1" name
    config_get domains "$1" domain
    config_get table "$1" table fw4
    config_get family "$1" table_family inet
    config_get forced_family "$1" family
    case $family in ip) forced_family=4;; ip6) forced_family=6;; esac
    targets=
    names=$(printf '%s' "$names" | tr ',' ' ')
    for name in $names; do
        # Match native dnsmasq init's family selection, including arbitrary names.
        ipfamily=$forced_family
        if [ -z "$ipfamily" ]; then
            ipfamily=$(printf '%s\n' "$name" | sed -nE 's/^.*[^0-9]([46])$|^.*[-_]([46])[-_].*$|^([46])[^0-9].*$/\1\2\3/p')
        fi
        if [ -z "$ipfamily" ]; then
            if [ "$table:$family" = fw4:inet ]; then
                ipfamily=$(awk -F '\t' -v name="$name" '$1==name {print $2; exit}' "$work/families")
            fi
        fi
        if [ -z "$ipfamily" ]; then
            datatype=$(nft -t list set "$family" "$table" "$name" 2>/dev/null | sed -n 's/.*type \(ipv[46]_addr\).*/\1/p' || true)
            case $datatype in ipv4_addr) ipfamily=4;; ipv6_addr) ipfamily=6;; *)
                printf 'E\tCannot determine IP family of set %s\n' "$name"; continue;; esac
        fi
        targets="${targets}${targets:+,}$ipfamily#$family#$table#$name"
    done
    [ -n "$targets" ] || return 0
    for name in $domains; do printf 'M\t%s\t%s\n' "$name" "$targets"; done
}
hosts() {
    applies "$1" || return 0
    config_get names "$1" name
    config_get ips "$1" ip
    for name in $names; do for ip in $ips; do printf 'H\t%s\t%s\n' "$name" "$ip"; done; done
}
hostrecords() {
    applies "$1" || return 0
    config_get names "$1" name
    config_get ips "$1" ip
    config_get ip6 "$1" ip6
    for name in $names; do for ip in $ips $ip6; do printf 'H\t%s\t%s\n' "$name" "$ip"; done; done
}
cnames() {
    applies "$1" || return 0
    config_get names "$1" cname
    config_get target "$1" target
    [ -n "$target" ] || return 0
    for name in $names; do printf 'C\t%s\t%s\n' "$name" "$target"; done
}
compile() {
    source=$1; output=$2; static=$3; config=$4
    wdns=$(awk -F '\t' '$1=="S" {print $2}' "$config")
    ipv6=$(awk -F '\t' '$1=="S" {print $3}' "$config")
    awk -v wdns="$wdns" -v ipv6="${ipv6:-0}" -v static_file="$static" \
        -f "$COMPILER" "$source" "$config" > "$output.unsorted" || return 1
    LC_ALL=C sort "$output.unsorted" > "$output"
}
fingerprint() { uci export dhcp || return 1; uci export firewall; }
wdns_routes_ready() {
    rules=$(ip -4 rule show)
    printf '%s\n' "$rules" | grep '^80:' | grep -F "to $wdns " | grep -q 'lookup vpn' &&
        printf '%s\n' "$rules" | grep '^81:' | grep -F "to $wdns " | grep -q unreachable
}
guard_wdns() {
    address=$1
    [ -n "$address" ] || return 0
    if ! grep -Fx "$address" "$GUARDS" >/dev/null 2>&1; then
        ip -4 rule add priority 79 to "$address" unreachable || return 1
        printf '%s\n' "$address" >> "$GUARDS"
    fi
}
clear_wdns_guards() {
    [ -f "$GUARDS" ] || return 0
    while read -r address; do
        if ! ip -4 rule del priority 79 to "$address" unreachable; then
            # A previous retry may already have removed this guard.
            if ip -4 rule show | grep '^79:' | grep -F "to ${address%/32} " | grep -q unreachable; then return 1; fi
        fi
    done < "$GUARDS"
    rm -f "$GUARDS"
}
sync_wdns_route() {
    old_destination=$(uci -q get network.wdns_tunnel.dest || true)
    if [ -n "$old_destination" ] && [ "$old_destination" != "${wdns}/32" ]; then
        # Keep old daemon queries from falling back during a LuCI server change.
        guard_wdns "$old_destination" || return 1
    fi
    if [ -n "$wdns" ]; then
        if [ "$(uci -q get network.wdns_tunnel.dest || true)" = "$wdns/32" ] &&
            [ "$(uci -q get network.wdns_no_fallback.dest || true)" = "$wdns/32" ] &&
            wdns_routes_ready; then return; fi
        guard_wdns "$wdns/32" || return 1
        uci -q delete network.wdns_tunnel.action || true
        uci -q delete network.wdns_no_fallback.lookup || true
        uci -q batch <<EOF || return 1
set network.wdns_tunnel=rule
set network.wdns_tunnel.dest='$wdns/32'
set network.wdns_tunnel.priority='80'
set network.wdns_tunnel.lookup='vpn'
set network.wdns_no_fallback=rule
set network.wdns_no_fallback.dest='$wdns/32'
set network.wdns_no_fallback.priority='81'
set network.wdns_no_fallback.action='unreachable'
EOF
    else
        if ! uci -q get network.wdns_tunnel >/dev/null &&
            ! uci -q get network.wdns_no_fallback >/dev/null; then return; fi
        uci -q delete network.wdns_tunnel || true
        uci -q delete network.wdns_no_fallback || true
    fi
    uci commit network || return 1
    [ "${action:-}" != prepare ] || return 0
    reload_network || return 1
    if [ -n "$wdns" ]; then
        waited=0
        until wdns_routes_ready; do
            [ "$waited" -lt 10 ] || { log 'WDNS routing rules are not active yet'; return 1; }
            waited=$((waited+1)); sleep 1
        done
    fi
}
apply() {
    source=$1
    confdir=$(uci -q get dhcp.@dnsmasq[0].confdir)
    case $confdir in *,*) log 'confdir extension filters are unsupported'; return 1;; esac
    confdir=${confdir%%,*}
    [ -d "$confdir" ] || mkdir -p "$confdir" || return 1
    fingerprint > "$work/before" || return 1
    snapshot > "$work/config" || return 1
    compile "$source" "$work/domains" "$work/static" "$work/config" || return 1
    dnsmasq --conf-file="$work/domains" --test >/dev/null 2>&1 || return 1
    fingerprint > "$work/after" || return 1
    cmp -s "$work/before" "$work/after" || { log 'configuration changed during compilation; retry later'; return 1; }
    sync_wdns_route || return 1
    changed=0
    if ! cmp -s "$work/domains" "$confdir/domains.lst"; then
        # Hidden candidate is ignored by concurrent LuCI dnsmasq restarts.
        cp "$work/domains" "$confdir/.getdomains.$$" || return 1
        [ "${2:-}" = prepare ] || touch "$PENDING" || return 1
        mv -f "$confdir/.getdomains.$$" "$confdir/domains.lst" || return 1
        changed=1
    fi
    if [ "${action:-}" = refresh ] && ! cmp -s "$source" "$ROOT/domains.source"; then
        cp "$source" "$ROOT/.domains.source.$$" || return 1
        mv -f "$ROOT/.domains.source.$$" "$ROOT/domains.source" || return 1
    fi
    cp "$work/static" "$STATIC" || return 1
    # The kernel leaves expiry unchanged on duplicate adds with the same timeout.
    # Alternating by one second hourly renews local answers even without queries.
    hour=$(($(date +%s) / 3600))
    ttl=$((172800 - hour % 2))
    sed "s/timeout 2d/timeout ${ttl}s/" "$work/static" > "$work/static-refresh"
    if [ -s "$work/static" ] && ! nft -f "$work/static-refresh"; then
        log 'static DNS addresses could not be seeded; will retry'
        return 1
    fi
    if [ "${2:-}" != prepare ] && { [ "$changed" -eq 1 ] || [ -f "$PENDING" ]; }; then
        restart_dnsmasq || return 1
        rm -f "$PENDING"
    fi
    [ "${2:-}" = prepare ] || clear_wdns_guards
}
refresh() {
    url=$(cat "$ROOT/source-url")
    host=${url#*://}; host=${host%%/*}; host=${host%%:*}
    waited=0
    while ! ip link show dev tun0 >/dev/null 2>&1 || ! nslookup "$host" >/dev/null 2>&1; do
        [ "$waited" -lt 30 ] || { log 'download path is not ready'; return 1; }
        waited=$((waited + 1)); sleep 1
    done
    curl -fL --interface tun0 --connect-timeout 10 --max-time 120 --retry 5 \
        --retry-delay 2 --max-filesize 2097152 "$url" -o "$work/download" || return 1
    [ -s "$work/download" ] && [ "$(wc -c < "$work/download")" -le 2097152 ] || return 1
    apply "$work/download" || return 1
}

case ${1:-} in
    watch)
        # A content change also catches LuCI applies which produce unchanged
        # generated dnsmasq UCI files. No firewall reload or conntrack flush.
        previous=
        while :; do
            current=$(fingerprint | sha256sum)
            sets=$(nft -t list set inet fw4 vpn_domains 2>/dev/null | sha256sum)
            hour=$(($(date +%s) / 3600))
            if [ "$current:$sets:$hour" != "$previous" ] || [ -f "$PENDING" ] || [ -f "$GUARDS" ]; then
                if "$0" reload; then previous="$current:$sets:$hour"; fi
            fi
            sleep 2
        done;;
    reload|prepare|refresh|check) ;;
    *) echo "Usage: $0 {refresh|reload|prepare|watch|check}" >&2; exit 2;;
esac
action=$1
work=$(mktemp -d /tmp/getdomains.XXXXXX)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
if [ "$action" = check ]; then
    snapshot > "$work/config"
    compile "$ROOT/domains.source" "$work/domains" "$work/static" "$work/config"
    confdir=$(uci -q get dhcp.@dnsmasq[0].confdir); confdir=${confdir%%,*}
    cmp -s "$work/domains" "$confdir/domains.lst"
    exit
fi
lock=/var/lock/getdomains.lock
mkdir "$lock" 2>/dev/null || exit 1
trap 'rmdir "$lock"; rm -rf "$work"' 0
if [ "$action" = refresh ]; then refresh
elif [ -f "$ROOT/domains.source" ]; then apply "$ROOT/domains.source" "$action"
else log 'no validated domain list cached yet'; fi
