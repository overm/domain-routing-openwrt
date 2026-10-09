#!/bin/sh
# Destructive two-stage test on an expendable router with getdomains installed.
# Run prepare, reboot the router, then run verify. Keep this script in /root.
set -eu
[ "${GETDOMAINS_ALLOW_DESTRUCTIVE_TESTS:-}" = 1 ] || {
    echo 'Set GETDOMAINS_ALLOW_DESTRUCTIVE_TESTS=1 on a test router.' >&2; exit 2;
}
state=/root/getdomains-boot-test
case ${1:-} in
    prepare)
        [ ! -e "$state" ] || { echo "Test state already exists: $state" >&2; exit 2; }
        for section in gd_boot_manual gd_boot_host gd_boot_alias; do
            if uci -q get "dhcp.$section" >/dev/null; then
                echo "Test section already exists: $section" >&2; exit 2
            fi
        done
        [ -s /etc/getdomains/domains.source ]
        mkdir "$state"
        cp /etc/config/dhcp "$state/dhcp.before"
        uci -q batch <<'EOF'
set dhcp.gd_boot_manual=ipset
add_list dhcp.gd_boot_manual.name='vpn_domains'
add_list dhcp.gd_boot_manual.domain='boot-restore.test'
set dhcp.gd_boot_host=domain
set dhcp.gd_boot_host.name='boot-restore.test'
set dhcp.gd_boot_host.ip='198.51.100.58'
set dhcp.gd_boot_alias=cname
set dhcp.gd_boot_alias.cname='alias.boot-restore.test'
set dhcp.gd_boot_alias.target='boot-restore.test'
commit dhcp
EOF
        ubus call service event '{"type":"config.change","data":{"package":"dhcp"}}'
        sleep 5
        /usr/libexec/getdomains-runtime check
        confdir=$(uci -q get dhcp.@dnsmasq[0].confdir)
        sha256sum /etc/getdomains/domains.source /etc/sing-box/config.json "$confdir/domains.lst" > "$state/files.sha256"
        nft get element inet fw4 vpn_domains '{ 198.51.100.58 }' >/dev/null
        echo 'Prepared. Reboot, then run this script with verify.'
        ;;
    verify)
        [ -s "$state/dhcp.before" ] && [ -s "$state/files.sha256" ]
        failures=0; number=0
        check() {
            number=$((number+1)); description=$1; shift
            if "$@"; then printf 'ok %s - %s\n' "$number" "$description"
            else printf 'not ok %s - %s\n' "$number" "$description"; failures=$((failures+1)); fi
        }
        check 'cached source, sing-box config and compiled DNS survive reboot' sha256sum -c "$state/files.sha256"
        # Check before DNS queries: boot reconciliation must seed local records.
        check 'static local IP is seeded before a client query' nft get element inet fw4 vpn_domains '{ 198.51.100.58 }'
        check 'manual DNS rule is restored' sh -c 'grep -q "^nftset=/boot-restore.test/" "$(uci -q get dhcp.@dnsmasq[0].confdir)/domains.lst"'
        check 'local hostname resolves after reboot' sh -c 'nslookup boot-restore.test 127.0.0.1 | grep -q 198.51.100.58'
        check 'local CNAME resolves after reboot' sh -c 'nslookup alias.boot-restore.test 127.0.0.1 | grep -q 198.51.100.58'
        check 'runtime matches current LuCI settings' /usr/libexec/getdomains-runtime check
        check 'synchronization monitor is running' sh -c 'service getdomains status | grep -q running'
        check 'temporary WDNS guards are cleared' test ! -e /tmp/getdomains-wdns-guards
        check 'full diagnostic passes after reboot' /usr/bin/getdomains-check --lang=en
        cp "$state/dhcp.before" /etc/config/dhcp
        ubus call service event '{"type":"config.change","data":{"package":"dhcp"}}'
        sleep 5
        nft delete element inet fw4 vpn_domains '{ 198.51.100.58 }' 2>/dev/null || true
        check 'cleanup restores the original DHCP configuration' cmp -s "$state/dhcp.before" /etc/config/dhcp
        check 'cleanup regenerates DNS without the test rows' /usr/libexec/getdomains-runtime check
        rm -rf "$state"
        printf '1..%s\n' "$number"
        exit "$failures"
        ;;
    *) echo "Usage: $0 {prepare|verify}" >&2; exit 2;;
esac
