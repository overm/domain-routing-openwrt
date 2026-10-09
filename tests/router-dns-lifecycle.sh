#!/bin/sh
# Destructive tests for an expendable OpenWrt 25+ router AFTER installation.
# No public DNS/proxy endpoint is required: DNS fixtures use distinct local ports,
# TCP fixtures use a namespace and a more-specific test route in table vpn.
set -eu
[ "${GETDOMAINS_ALLOW_DESTRUCTIVE_TESTS:-}" = 1 ] || {
    echo 'Set GETDOMAINS_ALLOW_DESTRUCTIVE_TESTS=1 on an expendable router.' >&2; exit 2;
}
for command in nft ip dnsmasq nc uci conntrack; do command -v "$command" >/dev/null || {
    echo "Missing $command (install conntrack and kmod-veth on the test router)." >&2; exit 2;
}; done
[ -s /etc/getdomains/domains.source ] || { echo 'Install and refresh getdomains first.' >&2; exit 2; }
NS=gd-lifecycle
CLIENT=gd-client
for namespace in "$NS" "$CLIENT"; do
    ip netns list | grep -q "^$namespace\b" && { echo "Namespace $namespace already exists" >&2; exit 2; }
done
nft list set inet fw4 other4 >/dev/null 2>&1 && { echo 'Set other4 already exists' >&2; exit 2; }
nft list set inet fw4 gd_full4 >/dev/null 2>&1 && { echo 'Set gd_full4 already exists' >&2; exit 2; }
work=$(mktemp -d /tmp/getdomains-lifecycle.XXXXXX)
cp /etc/config/dhcp "$work/dhcp.before"
cp /etc/config/network "$work/network.before"
pids=
failures=0
number=0
check() {
    number=$((number+1)); message=$1; shift
    if "$@"; then printf 'ok %s - %s\n' "$number" "$message"
    else printf 'not ok %s - %s\n' "$number" "$message"; failures=$((failures+1)); fi
}
cleanup() {
    for pid in $pids; do kill "$pid" 2>/dev/null || true; done
    ip route del table vpn 192.0.2.202/32 2>/dev/null || true
    ip netns del "$NS" 2>/dev/null || true
    ip netns del "$CLIENT" 2>/dev/null || true
    ip link del gd-host 2>/dev/null || true
    ip link del gd-lan 2>/dev/null || true
    ip addr del 192.0.2.1/30 dev br-lan 2>/dev/null || true
    nft delete set inet fw4 other4 2>/dev/null || true
    nft delete set inet fw4 gd_full4 2>/dev/null || true
    for chain in mangle_output mangle_prerouting forward; do
        nft -a list chain inet fw4 "$chain" | sed -n '/gd-test-packet/ s/.*# handle \([0-9]*\).*/\1/p' |
            while read -r handle; do nft delete rule inet fw4 "$chain" handle "$handle"; done
    done
    nft delete element inet fw4 vpn_domains '{ 192.0.2.202 }' 2>/dev/null || true
    for address in 198.51.100.54 198.51.100.57; do
        nft delete element inet fw4 vpn_domains "{ $address }" 2>/dev/null || true
    done
    cp "$work/dhcp.before" /etc/config/dhcp
    cp "$work/network.before" /etc/config/network
    if [ -f "$work/source.before" ]; then cp "$work/source.before" /etc/getdomains/domains.source; fi
    /etc/init.d/network reload
    /usr/libexec/getdomains-runtime reload || true
    /etc/init.d/dnsmasq restart
    rm -rf "$work"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

# Exercise the SAME compiler with distinguishable upstream answers.
printf 'nftset=/selected.test/4#inet#fw4#vpn_domains\n' > "$work/source"
printf 'M\tmanual.test\t4#inet#fw4#vpn_domains\nM\tmanual.test\t4#inet#fw4#other4\n' > "$work/snapshot"
printf 'M\tfull.test\t4#inet#fw4#gd_full4\n' >> "$work/snapshot"
nft add set inet fw4 other4 '{ type ipv4_addr; }'
nft add set inet fw4 gd_full4 '{ type ipv4_addr; size 1; elements = { 198.51.100.99 }; }'
dnsmasq --keep-in-foreground --conf-file=/dev/null --pid-file="$work/wdns.pid" --port=1054 --listen-address=127.0.0.1 \
    --bind-interfaces --no-resolv --address=/#/198.51.100.54 > "$work/wdns.log" 2>&1 &
pids="$pids $!"
dnsmasq --keep-in-foreground --conf-file=/dev/null --pid-file="$work/provider.pid" --port=1055 --listen-address=127.0.0.1 \
    --bind-interfaces --no-resolv --address=/#/198.51.100.55 > "$work/provider.log" 2>&1 &
pids="$pids $!"
awk -v wdns='127.0.0.1#1054' -f /usr/libexec/getdomains-compile.awk \
    "$work/source" "$work/snapshot" > "$work/client.conf"
# Native UCI nftset directives follow confdir in OpenWrt's dnsmasq configuration.
# Verify equal-name native rows cannot replace the generated union.
printf 'nftset=/manual.test/4#inet#fw4#vpn_domains\nnftset=/manual.test/4#inet#fw4#other4\n' >> "$work/client.conf"
dnsmasq --keep-in-foreground --conf-file="$work/client.conf" --pid-file="$work/client.pid" --port=1053 \
    --listen-address=127.0.0.1 --bind-interfaces --no-resolv \
    --server='127.0.0.1#1055' > "$work/client.log" 2>&1 &
pids="$pids $!"
sleep 1
query() { nslookup "$1" 127.0.0.1:1053 2>/dev/null | grep -q "$2"; }
check 'listed domain uses WDNS' query selected.test 198.51.100.54
check 'unlisted domain uses provider' query ordinary.test 198.51.100.55
check 'manual IP Sets domain uses WDNS' query manual.test 198.51.100.54
check 'duplicate manual rows populate both sets' sh -c \
    "nft get element inet fw4 vpn_domains '{ 198.51.100.54 }' >/dev/null && nft get element inet fw4 other4 '{ 198.51.100.54 }' >/dev/null"
check 'a full set does not prevent a DNS answer' query full.test 198.51.100.55
check 'the full set cannot learn the new IP' sh -c "! nft get element inet fw4 gd_full4 '{ 198.51.100.55 }' >/dev/null 2>&1"
check 'dnsmasq reports the set insertion error' grep -Ei 'error|failed|No space' "$work/client.log"
for pid in $pids; do kill "$pid" 2>/dev/null || true; done
pids=
nft delete set inet fw4 other4
nft delete set inet fw4 gd_full4

# Real TCP conntrack entries, with both direct and vpn routes to a controlled peer.
ip netns add "$NS"
ip link add gd-host type veth peer name gd-peer
ip link set gd-peer netns "$NS"
ip addr add 192.0.2.201/30 dev gd-host
ip link set gd-host up
ip netns exec "$NS" ip addr add 192.0.2.202/30 dev gd-peer
ip netns exec "$NS" ip link set gd-peer up
ip netns exec "$NS" ip link set lo up
ip netns exec "$NS" ip route add default via 192.0.2.201
ip route add table vpn 192.0.2.202/32 dev gd-host src 192.0.2.201
ip netns add "$CLIENT"
ip link add gd-lan type veth peer name gd-client
ip link set gd-client netns "$CLIENT"
ip link set gd-lan master br-lan
ip link set gd-lan up
ip addr add 192.0.2.1/30 dev br-lan
ip netns exec "$CLIENT" ip addr add 192.0.2.2/30 dev gd-client
ip netns exec "$CLIENT" ip link set gd-client up
ip netns exec "$CLIENT" ip route add default via 192.0.2.1
nft insert rule inet fw4 forward iifname br-lan oifname gd-host ip daddr 192.0.2.202 \
    tcp dport '{ 18083, 18084 }' accept comment 'gd-test-packet-forward'
# fw4's WAN output policy may be REJECT on some images; fail visibly if so.
open_flow() {
    port=$1
    ip netns exec "$NS" sh -c "exec nc -l -p $port >/dev/null" &
    pids="$pids $!"
    mkfifo "$work/input-$port"
    if [ "${2:-}" = lan ]; then
        ip netns exec "$CLIENT" nc 192.0.2.202 "$port" < "$work/input-$port" > /dev/null &
    else nc 192.0.2.202 "$port" < "$work/input-$port" > /dev/null & fi
    pids="$pids $!"
    (i=0; while [ "$i" -lt 120 ]; do echo tick; sleep 1; i=$((i+1)); done) > "$work/input-$port" &
    pids="$pids $!"
    sleep 2
}
flow_mark() {
    conntrack -L -p tcp --dst 192.0.2.202 --dport "$1" -o extended 2>/dev/null |
        grep ESTABLISHED | grep -q "mark=$2\b"
}
packet_rule() {
    chain=$1; port=$2; mark=$3
    nft add rule inet fw4 "$chain" ip daddr 192.0.2.202 tcp dport "$port" \
        ct direction original meta mark \& 0x1 == "$mark" counter comment "gd-test-packet-$port"
}
packet_mark() {
    chain=$1; port=$2
    before=$(nft list chain inet fw4 "$chain" | sed -n "/gd-test-packet-$port/ s/.*counter packets \([0-9]*\).*/\1/p")
    sleep 2
    after=$(nft list chain inet fw4 "$chain" | sed -n "/gd-test-packet-$port/ s/.*counter packets \([0-9]*\).*/\1/p")
    [ "${after:-0}" -gt "${before:-0}" ]
}
nft delete element inet fw4 vpn_domains '{ 192.0.2.202 }' 2>/dev/null || true
open_flow 18081
open_flow 18083 lan
packet_rule mangle_output 18081 0
packet_rule mangle_output 18082 1
packet_rule mangle_prerouting 18083 0
packet_rule mangle_prerouting 18084 1
check 'direct flow starts with a saved direct decision' flow_mark 18081 1073741824
check 'LAN direct flow starts with a saved direct decision' flow_mark 18083 1073741824
nft add element inet fw4 vpn_domains '{ 192.0.2.202 timeout 2d }'
sleep 2
check 'learning an IP does not move an established direct flow' flow_mark 18081 1073741824
check 'LAN direct packets remain direct after learning the IP' packet_mark mangle_prerouting 18083
open_flow 18082
open_flow 18084 lan
check 'a new flow to the learned IP receives the VPN decision' flow_mark 18082 1073741825
# Force expiry AFTER classification; a first SYN normally refreshes it to 2d.
nft delete element inet fw4 vpn_domains '{ 192.0.2.202 }'
nft add element inet fw4 vpn_domains '{ 192.0.2.202 timeout 1s }'
sleep 3
check 'the test element really expired' sh -c "! nft get element inet fw4 vpn_domains '{ 192.0.2.202 }' >/dev/null 2>&1"
check 'VPN flow remains pinned after the IP expires' flow_mark 18082 1073741825
check 'router VPN packets keep the mark after expiry' packet_mark mangle_output 18082
check 'LAN VPN packets keep the mark after expiry' packet_mark mangle_prerouting 18084

# Save & Apply equivalent: native UCI + procd event, then wait for reconciliation.
uci -q batch <<'EOF'
set dhcp.gd_test_manual=ipset
add_list dhcp.gd_test_manual.name='vpn_domains'
add_list dhcp.gd_test_manual.domain='manual-lifecycle.test'
set dhcp.gd_test_host=domain
set dhcp.gd_test_host.name='manual-lifecycle.test'
set dhcp.gd_test_host.ip='198.51.100.57'
commit dhcp
EOF
ubus call service event '{"type":"config.change","data":{"package":"dhcp"}}'
sleep 5
confdir=$(uci -q get dhcp.@dnsmasq[0].confdir)
check 'LuCI manual domain is compiled after Apply' grep -q '^nftset=/manual-lifecycle.test/' "$confdir/domains.lst"
check 'local LuCI hostname resolves to its configured IP' sh -c 'nslookup manual-lifecycle.test 127.0.0.1 | grep -q 198.51.100.57'
check 'local answers seed the routing set' nft get element inet fw4 vpn_domains '{ 198.51.100.57 }'
check 'DNS regeneration preserves the existing direct flow' flow_mark 18081 1073741824
check 'DNS regeneration preserves the existing VPN flow' flow_mark 18082 1073741825
check 'router direct packets remain direct after DNS regeneration' packet_mark mangle_output 18081
check 'LAN VPN packets keep the mark after DNS regeneration' packet_mark mangle_prerouting 18084
uci -q delete dhcp.gd_test_manual
uci -q delete dhcp.gd_test_host
uci commit dhcp
ubus call service event '{"type":"config.change","data":{"package":"dhcp"}}'
sleep 5
check 'deleting the manual row removes its DNS rule' sh -c "! grep -q manual-lifecycle.test '$confdir/domains.lst'"
check 'manual deletion preserves the existing VPN flow' flow_mark 18082 1073741825

# A refreshed list must preserve learned elements and conntrack, even if names
# disappear. Use a private source snapshot; restore it before cleanup.
cp /etc/getdomains/domains.source "$work/source.before"
printf 'nftset=/replacement.test/4#inet#fw4#vpn_domains\n' > /etc/getdomains/domains.source
/usr/libexec/getdomains-runtime reload
check 'source replacement installs the new domain' grep -q '/replacement.test/' "$confdir/domains.lst"
check 'source replacement keeps learned IPs rather than flushing shared sets' nft get element inet fw4 vpn_domains '{ 198.51.100.57 }'
check 'source replacement keeps the established VPN flow' flow_mark 18082 1073741825
cp "$work/source.before" /etc/getdomains/domains.source
/usr/libexec/getdomains-runtime reload

# Other users of packet/conntrack marks must survive route restoration. Replies
# belong to the same tracked flow but must not receive the VPN routing bit.
conntrack -U -p tcp --dst 192.0.2.202 --dport 18082 --mark 1610612737 >/dev/null 2>&1
nft insert rule inet fw4 mangle_output ip daddr 192.0.2.202 tcp dport 18082 \
    meta mark set meta mark \| 0x20000000 comment 'gd-test-packet-extra'
nft add rule inet fw4 mangle_output ip daddr 192.0.2.202 tcp dport 18082 \
    ct direction original meta mark \& 0x20000001 == 0x20000001 counter comment 'gd-test-packet-preserve'
nft add rule inet fw4 mangle_prerouting ip saddr 192.0.2.202 tcp sport 18082 \
    ct direction reply meta mark \& 0x1 == 0 counter comment 'gd-test-packet-reply'
check 'route restoration preserves unrelated conntrack bits' flow_mark 18082 1610612737
check 'route restoration preserves unrelated packet bits' packet_mark mangle_output preserve
check 'reply packets do not receive the VPN routing bit' packet_mark mangle_prerouting reply

printf '1..%s\n' "$number"
exit "$failures"
