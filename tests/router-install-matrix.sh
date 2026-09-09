#!/bin/sh

# Destructive integration tests for an expendable OpenWrt router.
# The suite repeatedly installs and removes domain-routing configuration.

set -u

if [ "${GETDOMAINS_ALLOW_DESTRUCTIVE_TESTS:-}" != 1 ]; then
    echo "Refusing to reconfigure this router without GETDOMAINS_ALLOW_DESTRUCTIVE_TESTS=1" >&2
    exit 2
fi

INPUT_SOURCE_DIR=${GETDOMAINS_TEST_SOURCE_DIR:-/tmp/domain-routing-source}
RESULT_DIR=${GETDOMAINS_TEST_RESULT_DIR:-/tmp/domain-routing-results}
case $INPUT_SOURCE_DIR in
    /tmp/?*) ;;
    *) echo "Source directory must be a specific path below /tmp" >&2; exit 2 ;;
esac
case $RESULT_DIR in
    /tmp/?*) ;;
    *) echo "Result directory must be a specific path below /tmp" >&2; exit 2 ;;
esac
case $INPUT_SOURCE_DIR:$RESULT_DIR in
    *../*|*/..) echo "Source and result directories must not contain '..'" >&2; exit 2 ;;
esac
SOURCE_DIR=$RESULT_DIR/source-under-test
INSTALLER=$SOURCE_DIR/getdomains-install.sh
UNINSTALLER=$SOURCE_DIR/getdomains-uninstall.sh
WDNS_ADDRESS=192.0.2.53
TEST_IPV4_OUTPUT=198.51.100.10
TEST_IPV4_LAN=198.51.100.11
TEST_IPV4_ROUTE=198.51.100.200
TEST_IPV6_OUTPUT=2001:db8::10
TEST_IPV6_LAN=2001:db8::11
NETNS=getdomains-test
VETH_HOST=gdt-host
VETH_PEER=gdt-peer
LAN_TEST_IPV4=192.0.2.1/24
CLIENT_TEST_IPV4=192.0.2.2/24
LAN_TEST_IPV6=fd42:6764:74::1/64
CLIENT_TEST_IPV6=fd42:6764:74::2/64
LAN_TEST_IPV4_ADDED=0
LAN_TEST_IPV6_ADDED=0

TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0
CURRENT_CASE=preflight

mkdir -p "$RESULT_DIR/logs"
rm -rf "$SOURCE_DIR"
mkdir -p "$SOURCE_DIR"
rm -f "$RESULT_DIR/assertions.tap" "$RESULT_DIR/assertions.body" \
    "$RESULT_DIR/cases.tsv" "$RESULT_DIR/metadata.txt" "$RESULT_DIR/runner.exit"
printf 'case\tstatus\tnew_failures\n' > "$RESULT_DIR/cases.tsv"

record() {
    result=$1
    description=$2
    TOTAL=$((TOTAL + 1))
    case $result in
        pass)
            PASSED=$((PASSED + 1))
            printf 'ok %s - %s: %s\n' "$TOTAL" "$CURRENT_CASE" "$description" >> "$RESULT_DIR/assertions.body"
            ;;
        skip)
            SKIPPED=$((SKIPPED + 1))
            printf 'ok %s - %s: %s # SKIP\n' "$TOTAL" "$CURRENT_CASE" "$description" >> "$RESULT_DIR/assertions.body"
            ;;
        *)
            FAILED=$((FAILED + 1))
            printf 'not ok %s - %s: %s\n' "$TOTAL" "$CURRENT_CASE" "$description" >> "$RESULT_DIR/assertions.body"
            ;;
    esac
}

pass() { record pass "$1"; }
fail() { record fail "$1"; }
skip() { record skip "$1"; }

expect_eq() {
    description=$1
    expected=$2
    actual=$3
    if [ "$actual" = "$expected" ]; then
        pass "$description"
    else
        fail "$description (expected '$expected', got '$actual')"
    fi
}

expect_present() {
    description=$1
    shift
    if "$@" >/dev/null 2>&1; then pass "$description"; else fail "$description"; fi
}

expect_absent() {
    description=$1
    shift
    if "$@" >/dev/null 2>&1; then fail "$description"; else pass "$description"; fi
}

begin_case() {
    CURRENT_CASE=$1
    CASE_FAILURES=$FAILED
    printf '%s\n' "CASE $CURRENT_CASE"
}

end_case() {
    new_failures=$((FAILED - CASE_FAILURES))
    if [ "$new_failures" -eq 0 ]; then
        status=PASS
    else
        status=FAIL
    fi
    printf '%s\t%s\t%s\n' "$CURRENT_CASE" "$status" "$new_failures" >> "$RESULT_DIR/cases.tsv"
    printf '%s\n' "CASE $CURRENT_CASE: $status"
}

cleanup_network_fixture() {
    ip netns del "$NETNS" >/dev/null 2>&1 || true
    ip link del "$VETH_HOST" >/dev/null 2>&1 || true
    if [ "$LAN_TEST_IPV4_ADDED" -eq 1 ]; then
        ip addr del "$LAN_TEST_IPV4" dev br-lan >/dev/null 2>&1 || true
        LAN_TEST_IPV4_ADDED=0
    fi
    if [ "$LAN_TEST_IPV6_ADDED" -eq 1 ]; then
        ip -6 addr del "$LAN_TEST_IPV6" dev br-lan >/dev/null 2>&1 || true
        LAN_TEST_IPV6_ADDED=0
    fi
    ip -6 route del "$TEST_IPV6_OUTPUT/128" dev br-lan >/dev/null 2>&1 || true
}

finish() {
    cleanup_network_fixture
    {
        printf 'TAP version 13\n'
        cat "$RESULT_DIR/assertions.body"
        printf '1..%s\n' "$TOTAL"
    } > "$RESULT_DIR/assertions.tap"
    {
        printf 'TOTAL=%s\n' "$TOTAL"
        printf 'PASSED=%s\n' "$PASSED"
        printf 'FAILED=%s\n' "$FAILED"
        printf 'SKIPPED=%s\n' "$SKIPPED"
    } > "$RESULT_DIR/summary.env"
}
trap finish 0
trap 'exit 130' HUP INT TERM

config_fingerprint() {
    temporary=$RESULT_DIR/config-fingerprint.$$
    {
        uci export network
        uci export firewall
        uci export dhcp
        sed -n '/getdomains/p' /etc/crontabs/root 2>/dev/null || true
        sed -n '/[[:space:]]vpn$/p' /etc/iproute2/rt_tables 2>/dev/null || true
    } > "$temporary"
    sha256sum "$temporary" | awk '{print $1}'
    rm -f "$temporary"
}

singbox_config_hash() {
    sha256sum /etc/sing-box/config.json | awk '{print $1}'
}

run_installer() {
    country=$1
    log_name=$2
    shift 2
    printf '%s\nn\n' "$country" |
        GETDOMAINS_SCRIPT_BASE_URL="file://$SOURCE_DIR" \
        sh "$INSTALLER" "$@" > "$RESULT_DIR/logs/$log_name.log" 2>&1
}

reset_domain_routing() {
    cleanup_network_fixture
    if [ -x /usr/bin/getdomains-uninstall ]; then
        /usr/bin/getdomains-uninstall
    else
        sh "$UNINSTALLER"
    fi
    wait_for_wan
}

wait_for_wan() {
    attempt=0
    while [ "$attempt" -lt 30 ]; do
        if ip route show default | grep -q '^default ' &&
            nslookup downloads.openwrt.org 127.0.0.1 >/dev/null 2>&1 &&
            wget -q -T 5 -O /dev/null https://downloads.openwrt.org/; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    return 1
}

domain_list_valid() {
    ipv6=$1
    [ -s /tmp/dnsmasq.d/domains.lst ] || return 1
    if [ "$ipv6" -eq 1 ]; then
        pattern='^nftset=/[A-Za-z0-9_.-]+/4#inet#fw4#vpn_domains,6#inet#fw4#vpn_domains6$'
    else
        pattern='^nftset=/[A-Za-z0-9_.-]+/4#inet#fw4#vpn_domains$'
    fi
    ! grep -Ev "$pattern" /tmp/dnsmasq.d/domains.lst >/dev/null 2>&1
}

verify_or_recover_domain_list() {
    ipv6=$1
    if domain_list_valid "$ipv6"; then
        pass "initial installation downloads a valid domain list"
        skip "domain-list retry is not needed"
        return 0
    fi

    fail "initial installation downloads a valid domain list"
    attempt=0
    while [ "$attempt" -lt 6 ]; do
        sleep 3
        /etc/init.d/getdomains start >/dev/null 2>&1 || true
        if domain_list_valid "$ipv6"; then
            pass "domain-list download recovers after the tunnel becomes ready"
            return 0
        fi
        attempt=$((attempt + 1))
    done
    fail "domain-list download recovers after the tunnel becomes ready"
    return 1
}

runtime_refresh_rules_valid() {
    ipv6=$1
    nft list chain inet fw4 mangle_prerouting 2>/dev/null |
        grep -q 'ip daddr @vpn_domains.*update @vpn_domains.*ip daddr timeout 2d' || return 1
    nft list chain inet fw4 mangle_output 2>/dev/null |
        grep -q 'ip daddr @vpn_domains.*update @vpn_domains.*ip daddr timeout 2d' || return 1
    if [ "$ipv6" -eq 1 ]; then
        nft list chain inet fw4 mangle_prerouting 2>/dev/null |
            grep -q 'ip6 daddr @vpn_domains6.*update @vpn_domains6.*ip6 daddr timeout 2d' || return 1
        nft list chain inet fw4 mangle_output 2>/dev/null |
            grep -q 'ip6 daddr @vpn_domains6.*update @vpn_domains6.*ip6 daddr timeout 2d' || return 1
    fi
}

set_has_long_expiry() {
    family=$1
    set_name=$2
    address=$3
    nft list set inet fw4 "$set_name" 2>/dev/null |
        grep "$address" |
        grep -Eq 'expires (2d|1d[0-9]+h)'
}

test_output_timeout_refresh() {
    ipv6=$1
    nft delete element inet fw4 vpn_domains "{ $TEST_IPV4_OUTPUT }" >/dev/null 2>&1 || true
    if nft add element inet fw4 vpn_domains "{ $TEST_IPV4_OUTPUT timeout 5s }" >/dev/null 2>&1; then
        ping -c 1 -W 1 "$TEST_IPV4_OUTPUT" >/dev/null 2>&1 || true
        if set_has_long_expiry ipv4 vpn_domains "$TEST_IPV4_OUTPUT"; then
            pass "router-local IPv4 traffic refreshes a five-second element to two days"
        else
            fail "router-local IPv4 traffic refreshes a five-second element to two days"
        fi
    else
        fail "temporary IPv4 timeout element can be inserted"
    fi
    nft delete element inet fw4 vpn_domains "{ $TEST_IPV4_OUTPUT }" >/dev/null 2>&1 || true

    if [ "$ipv6" -eq 1 ]; then
        nft delete element inet fw4 vpn_domains6 "{ $TEST_IPV6_OUTPUT }" >/dev/null 2>&1 || true
        ip -6 route replace "$TEST_IPV6_OUTPUT/128" dev br-lan >/dev/null 2>&1 || true
        if nft add element inet fw4 vpn_domains6 "{ $TEST_IPV6_OUTPUT timeout 5s }" >/dev/null 2>&1; then
            ping -6 -c 1 -W 1 "$TEST_IPV6_OUTPUT" >/dev/null 2>&1 || true
            if set_has_long_expiry ipv6 vpn_domains6 "$TEST_IPV6_OUTPUT"; then
                pass "router-local IPv6 traffic refreshes a five-second element to two days"
            else
                fail "router-local IPv6 traffic refreshes a five-second element to two days"
            fi
        else
            fail "temporary IPv6 timeout element can be inserted"
        fi
        nft delete element inet fw4 vpn_domains6 "{ $TEST_IPV6_OUTPUT }" >/dev/null 2>&1 || true
        ip -6 route del "$TEST_IPV6_OUTPUT/128" dev br-lan >/dev/null 2>&1 || true
    fi
}

setup_network_fixture() {
    cleanup_network_fixture
    ip addr add "$LAN_TEST_IPV4" dev br-lan || return 1
    LAN_TEST_IPV4_ADDED=1
    ip -6 addr add "$LAN_TEST_IPV6" dev br-lan nodad || return 1
    LAN_TEST_IPV6_ADDED=1
    ip netns add "$NETNS" || return 1
    ip link add "$VETH_HOST" type veth peer name "$VETH_PEER" || return 1
    ip link set "$VETH_HOST" master br-lan || return 1
    ip link set "$VETH_HOST" up || return 1
    ip link set "$VETH_PEER" netns "$NETNS" || return 1
    ip -n "$NETNS" link set lo up || return 1
    ip -n "$NETNS" link set "$VETH_PEER" name eth0 || return 1
    ip -n "$NETNS" addr add "$CLIENT_TEST_IPV4" dev eth0 || return 1
    ip -n "$NETNS" -6 addr add "$CLIENT_TEST_IPV6" dev eth0 nodad || return 1
    ip -n "$NETNS" link set eth0 up || return 1
    ip -n "$NETNS" route add default via 192.0.2.1 || return 1
    ip -n "$NETNS" -6 route add default via fd42:6764:74::1 || return 1
    sleep 1
}

test_lan_timeout_refresh() {
    ipv6=$1
    if ! setup_network_fixture; then
        fail "isolated LAN network namespace can be created"
        cleanup_network_fixture
        return
    fi
    pass "isolated LAN network namespace can be created"

    nft delete element inet fw4 vpn_domains "{ $TEST_IPV4_LAN }" >/dev/null 2>&1 || true
    nft add element inet fw4 vpn_domains "{ $TEST_IPV4_LAN timeout 5s }" >/dev/null 2>&1 || true
    ip netns exec "$NETNS" ping -c 1 -W 1 "$TEST_IPV4_LAN" >/dev/null 2>&1 || true
    if set_has_long_expiry ipv4 vpn_domains "$TEST_IPV4_LAN"; then
        pass "LAN IPv4 traffic refreshes a five-second element to two days"
    else
        fail "LAN IPv4 traffic refreshes a five-second element to two days"
    fi
    nft delete element inet fw4 vpn_domains "{ $TEST_IPV4_LAN }" >/dev/null 2>&1 || true

    if [ "$ipv6" -eq 1 ]; then
        nft delete element inet fw4 vpn_domains6 "{ $TEST_IPV6_LAN }" >/dev/null 2>&1 || true
        nft add element inet fw4 vpn_domains6 "{ $TEST_IPV6_LAN timeout 5s }" >/dev/null 2>&1 || true
        ip netns exec "$NETNS" ping -6 -c 1 -W 1 "$TEST_IPV6_LAN" >/dev/null 2>&1 || true
        if set_has_long_expiry ipv6 vpn_domains6 "$TEST_IPV6_LAN"; then
            pass "LAN IPv6 traffic refreshes a five-second element to two days"
        else
            fail "LAN IPv6 traffic refreshes a five-second element to two days"
        fi
        nft delete element inet fw4 vpn_domains6 "{ $TEST_IPV6_LAN }" >/dev/null 2>&1 || true
    fi
    cleanup_network_fixture
}

test_marked_route_behavior() {
    kill_switch=$1
    ip route del table vpn default >/dev/null 2>&1 || true
    if ip route get "$TEST_IPV4_ROUTE" mark 1 > "$RESULT_DIR/logs/$CURRENT_CASE.route" 2>&1; then
        route_rc=0
    else
        route_rc=$?
    fi
    /etc/hotplug.d/iface/30-vpnroute >/dev/null 2>&1 || true
    if [ "$kill_switch" -eq 1 ]; then
        if [ "$route_rc" -ne 0 ]; then
            pass "marked IPv4 becomes unreachable when the vpn table has no route"
        else
            fail "marked IPv4 becomes unreachable when the vpn table has no route"
        fi
    elif [ "$route_rc" -eq 0 ]; then
        pass "marked IPv4 falls through to the main table when the vpn table has no route"
    else
        fail "marked IPv4 falls through to the main table when the vpn table has no route"
    fi
    expect_present "vpn route is restored after the failover probe" sh -c "ip route show table vpn | grep -q '^default dev tun0'"
}

test_dnsmasq_population() {
    ipv6=$1
    icanhazip=$2
    nft flush set inet fw4 vpn_domains >/dev/null 2>&1 || true
    if [ "$ipv6" -eq 1 ]; then
        nft flush set inet fw4 vpn_domains6 >/dev/null 2>&1 || true
    fi

    candidates=$RESULT_DIR/dns-candidates.$$
    if [ "$icanhazip" -eq 1 ]; then
        printf '%s\n' icanhazip.com > "$candidates"
    else
        sed -n 's|^nftset=/\([^/]*\)/.*|\1|p' /tmp/dnsmasq.d/domains.lst | head -n 30 > "$candidates"
    fi
    while IFS= read -r domain; do
        nslookup "$domain" 127.0.0.1 >/dev/null 2>&1 || true
        if nft list set inet fw4 vpn_domains 2>/dev/null | grep -q 'elements = {'; then
            ipv4_populated=1
        else
            ipv4_populated=0
        fi
        if [ "$ipv6" -eq 0 ] || nft list set inet fw4 vpn_domains6 2>/dev/null | grep -q 'elements = {'; then
            ipv6_populated=1
        else
            ipv6_populated=0
        fi
        [ "$ipv4_populated" -eq 1 ] && [ "$ipv6_populated" -eq 1 ] && break
    done < "$candidates"
    rm -f "$candidates"

    if [ "${ipv4_populated:-0}" -eq 1 ]; then
        pass "dnsmasq populates vpn_domains from a configured domain"
    else
        fail "dnsmasq populates vpn_domains from a configured domain"
    fi
    if [ "$ipv6" -eq 1 ]; then
        if [ "${ipv6_populated:-0}" -eq 1 ]; then
            pass "dnsmasq populates vpn_domains6 from an AAAA answer"
        else
            fail "dnsmasq populates vpn_domains6 from an AAAA answer"
        fi
    fi
}

assert_installed_mode() {
    ipv6=$1
    kill_switch=$2
    icanhazip=$3
    wdns=$4
    expected_url=$5

    expect_eq "sing-box configuration is preserved" "$SINGBOX_HASH_BEFORE" "$(singbox_config_hash)"
    expect_eq "vpn_domains is an IPv4 dst_ip set" "ipset|vpn_domains|dst_ip|ipv4|172800|65536" \
        "$(uci -q get firewall.vpn_domains)|$(uci -q get firewall.vpn_domains.name)|$(uci -q get firewall.vpn_domains.match)|$(uci -q get firewall.vpn_domains.family)|$(uci -q get firewall.vpn_domains.timeout)|$(uci -q get firewall.vpn_domains.maxelem)"
    expect_present "vpn_domains exists in the active nft ruleset" nft list set inet fw4 vpn_domains
    expect_present "both timeout-refresh includes are configured" sh -c \
        "[ \"\$(uci -q get firewall.refresh_domains_prerouting.chain)\" = mangle_prerouting ] && [ \"\$(uci -q get firewall.refresh_domains_output.chain)\" = mangle_output ]"
    if runtime_refresh_rules_valid "$ipv6"; then pass "active nft rules contain the expected timeout refreshes"; else fail "active nft rules contain the expected timeout refreshes"; fi
    if domain_list_valid "$ipv6"; then pass "downloaded domain list targets the expected address families"; else fail "downloaded domain list targets the expected address families"; fi
    expect_present "getdomains service embeds the selected source URL" grep -F "wait_for_download_path '$expected_url'" /etc/init.d/getdomains
    expect_eq "cron contains one getdomains refresh" 1 "$(grep -c '/etc/init.d/getdomains start' /etc/crontabs/root)"
    expect_eq "rt_tables contains one vpn entry" 1 "$(grep -c '^[[:space:]]*99[[:space:]]\+vpn$' /etc/iproute2/rt_tables)"
    expect_present "dnsmasq is running" sh -c "service dnsmasq status | grep -q running"
    expect_present "sing-box is running" sh -c "service sing-box status | grep -q running"

    if [ "$kill_switch" -eq 1 ]; then
        expect_eq "kill-switch UCI rule is enabled" "rule|0x1|110|unreachable" \
            "$(uci -q get network.domain_kill_switch)|$(uci -q get network.domain_kill_switch.mark)|$(uci -q get network.domain_kill_switch.priority)|$(uci -q get network.domain_kill_switch.action)"
        expect_present "kill-switch policy rule is active" sh -c "ip rule show | grep -q '110:.*fwmark 0x1.*unreachable'"
    else
        expect_absent "kill-switch UCI rule is absent" uci -q get network.domain_kill_switch
        expect_absent "kill-switch policy rule is absent" sh -c "ip rule show | grep -q 'fwmark 0x1.*unreachable'"
    fi

    if [ "$ipv6" -eq 1 ]; then
        expect_eq "vpn_domains6 is an IPv6 dst_ip set" "ipset|vpn_domains6|dst_ip|ipv6|172800|65536" \
            "$(uci -q get firewall.vpn_domains6)|$(uci -q get firewall.vpn_domains6.name)|$(uci -q get firewall.vpn_domains6.match)|$(uci -q get firewall.vpn_domains6.family)|$(uci -q get firewall.vpn_domains6.timeout)|$(uci -q get firewall.vpn_domains6.maxelem)"
        expect_present "vpn_domains6 exists in the active nft ruleset" nft list set inet fw4 vpn_domains6
        expect_present "LAN IPv6 reject rule is active" sh -c "nft list ruleset | grep -q 'Reject selected domains over IPv6'"
        expect_present "router-local IPv6 reject rule is active" sh -c "nft list ruleset | grep -q 'Reject router-local selected domains over IPv6'"
        expect_present "IPv6 timeout refresh is present only when requested" grep -q 'ip6 daddr @vpn_domains6' /etc/getdomains/refresh-output.nft
    else
        expect_absent "vpn_domains6 UCI set is absent" uci -q get firewall.vpn_domains6
        expect_absent "vpn_domains6 is absent from the active nft ruleset" nft list set inet fw4 vpn_domains6
        expect_absent "IPv6 timeout refresh is absent" grep -q 'ip6 daddr @vpn_domains6' /etc/getdomains/refresh-output.nft
    fi

    if [ "$icanhazip" -eq 1 ]; then
        expected_sets=vpn_domains
        [ "$ipv6" -eq 1 ] && expected_sets='vpn_domains vpn_domains6'
        expect_eq "icanhazip.com mapping uses the expected sets" "$expected_sets|icanhazip.com|fw4|inet" \
            "$(uci -q get dhcp.vpn_icanhazip.name)|$(uci -q get dhcp.vpn_icanhazip.domain)|$(uci -q get dhcp.vpn_icanhazip.table)|$(uci -q get dhcp.vpn_icanhazip.table_family)"
    else
        expect_absent "icanhazip.com mapping is absent" uci -q get dhcp.vpn_icanhazip
    fi

    if [ "$wdns" -eq 1 ]; then
        expect_eq "WDNS tag advertises the requested IPv4 resolver" "tag|6,$WDNS_ADDRESS" \
            "$(uci -q get dhcp.wdns)|$(uci -q get dhcp.wdns.dhcp_option)"
    else
        expect_absent "WDNS tag is absent in an independently installed mode" uci -q get dhcp.wdns
    fi
}

run_matrix_case() {
    mask=$1
    ipv6=0
    kill_switch=0
    icanhazip=1
    wdns=0
    set --
    if [ $((mask & 1)) -ne 0 ]; then icanhazip=0; set -- "$@" --no-icanhazip; fi
    if [ $((mask & 2)) -ne 0 ]; then ipv6=1; set -- "$@" --ipv6-deny; fi
    if [ $((mask & 4)) -ne 0 ]; then kill_switch=1; set -- "$@" --kill-switch; fi
    if [ $((mask & 8)) -ne 0 ]; then wdns=1; set -- "$@" --wdns "$WDNS_ADDRESS"; fi

    CURRENT_CASE="matrix-$mask-ican$icanhazip-ipv6$ipv6-kill$kill_switch-wdns$wdns"
    begin_case "$CURRENT_CASE"
    if reset_domain_routing > "$RESULT_DIR/logs/$CURRENT_CASE.uninstall.log" 2>&1; then
        pass "WAN and DNS recover after removing the previous mode"
    else
        fail "WAN and DNS recover after removing the previous mode"
    fi
    if run_installer 1 "$CURRENT_CASE.install" "$@"; then
        pass "installer exits successfully"
        verify_or_recover_domain_list "$ipv6" || true
        assert_installed_mode "$ipv6" "$kill_switch" "$icanhazip" "$wdns" \
            'https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst'
        test_marked_route_behavior "$kill_switch"
        test_dnsmasq_population "$ipv6" "$icanhazip"
        test_output_timeout_refresh "$ipv6"
        if /usr/bin/getdomains-check --lang=en > "$RESULT_DIR/logs/$CURRENT_CASE.check.log" 2>&1; then
            pass "getdomains-check accepts the deployed mode"
        else
            fail "getdomains-check accepts the deployed mode"
        fi
        [ "$mask" -eq 0 ] && test_lan_timeout_refresh 0
        [ "$mask" -eq 2 ] && test_lan_timeout_refresh 1
    else
        fail "installer exits successfully"
    fi
    end_case
}

run_country_case() {
    choice=$1
    label=$2
    expected_url=$3
    begin_case "country-$choice-$label"
    if reset_domain_routing > "$RESULT_DIR/logs/$CURRENT_CASE.uninstall.log" 2>&1; then
        pass "WAN and DNS recover before country selection $choice"
    else
        fail "WAN and DNS recover before country selection $choice"
    fi
    if run_installer "$choice" "$CURRENT_CASE.install"; then
        pass "installer accepts country selection $choice"
        verify_or_recover_domain_list 0 || true
        assert_installed_mode 0 0 1 0 "$expected_url"
    else
        fail "installer accepts country selection $choice"
    fi
    end_case
}

run_cli_validation() {
    name=$1
    expected_rc=$2
    shift 2
    begin_case "cli-$name"
    before=$(config_fingerprint)
    sh "$INSTALLER" "$@" > "$RESULT_DIR/logs/$CURRENT_CASE.log" 2>&1
    actual_rc=$?
    after=$(config_fingerprint)
    expect_eq "exit status" "$expected_rc" "$actual_rc"
    expect_eq "invalid or informational CLI invocation does not mutate UCI" "$before" "$after"
    end_case
}

for script_name in getdomains-install.sh getdomains-check.sh getdomains-uninstall.sh; do
    required=$INPUT_SOURCE_DIR/$script_name
    if [ ! -s "$required" ]; then
        echo "Missing test source: $required" >&2
        exit 2
    fi
    # A Windows checkout may be transferred to the router without Git's LF
    # conversion. Test the same contents after normalizing only the staged copy.
    sed 's/\r$//' "$required" > "$SOURCE_DIR/$script_name"
    chmod 0755 "$SOURCE_DIR/$script_name"
done

begin_case preflight
. /etc/os-release
openwrt_major=${VERSION_ID%%.*}
case $openwrt_major in
    ''|*[!0-9]*)
        fail "OpenWrt VERSION_ID has a numeric major version"
        end_case
        exit 2
        ;;
esac
if [ "$openwrt_major" -lt 25 ]; then
    fail "OpenWrt major version is supported"
    end_case
    exit 2
fi
pass "OpenWrt major version is supported"
for command_name in apk curl dnsmasq ip nft nslookup sha256sum sing-box uci; do
    expect_present "$command_name is available" command -v "$command_name"
done
if apk add kmod-veth > "$RESULT_DIR/logs/preflight-kmod-veth.log" 2>&1; then
    pass "kmod-veth is available for isolated LAN packet generation"
else
    fail "kmod-veth is available for isolated LAN packet generation"
fi
SINGBOX_HASH_BEFORE=$(singbox_config_hash)
expect_present "working sing-box configuration passes validation" sing-box check -c /etc/sing-box/config.json
{
    printf 'OPENWRT_VERSION=%s\n' "$VERSION_ID"
    printf 'KERNEL_VERSION=%s\n' "$(uname -r)"
    printf 'NFT_VERSION=%s\n' "$(nft --version)"
    printf 'DNSMASQ_VERSION=%s\n' "$(dnsmasq --version | sed -n '1p')"
    printf 'SINGBOX_VERSION=%s\n' "$(sing-box version | sed -n '1p')"
    printf 'SINGBOX_CONFIG_SHA256_BEFORE=%s\n' "$SINGBOX_HASH_BEFORE"
} > "$RESULT_DIR/metadata.txt"
end_case

run_cli_validation help 0 --help
run_cli_validation unknown-option 2 --does-not-exist
run_cli_validation wdns-missing-value 2 --wdns
run_cli_validation wdns-too-short 2 --wdns 1.2.3
run_cli_validation wdns-octet-overflow 2 --wdns 256.1.1.1
run_cli_validation wdns-leading-zero 2 --wdns 01.2.3.4
run_cli_validation wdns-nonnumeric 2 --wdns a.b.c.d

mask=0
while [ "$mask" -lt 16 ]; do
    run_matrix_case "$mask"
    mask=$((mask + 1))
done

begin_case idempotent-all-options
before=$(config_fingerprint)
if run_installer 1 "$CURRENT_CASE.install" --no-icanhazip --ipv6-deny --kill-switch --wdns "$WDNS_ADDRESS"; then
    pass "second installation with identical options succeeds"
    after=$(config_fingerprint)
    expect_eq "second installation leaves normalized configuration unchanged" "$before" "$after"
    expect_eq "sing-box configuration remains unchanged" "$SINGBOX_HASH_BEFORE" "$(singbox_config_hash)"
else
    fail "second installation with identical options succeeds"
fi
end_case

begin_case reordered-and-duplicate-options
if reset_domain_routing > "$RESULT_DIR/logs/$CURRENT_CASE.uninstall.log" 2>&1; then
    pass "WAN and DNS recover before the reordered-argument case"
else
    fail "WAN and DNS recover before the reordered-argument case"
fi
if run_installer 1 "$CURRENT_CASE.install" --wdns 192.0.2.1 --kill-switch --ipv6-deny \
    --no-icanhazip --kill-switch --wdns "$WDNS_ADDRESS"; then
    pass "reordered and repeated options are accepted"
    verify_or_recover_domain_list 1 || true
    assert_installed_mode 1 1 0 1 \
        'https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst'
else
    fail "reordered and repeated options are accepted"
fi
end_case

begin_case transition-all-options-to-default
if run_installer 1 "$CURRENT_CASE.install"; then
    pass "reinstallation without mode flags succeeds"
    verify_or_recover_domain_list 0 || true
    expect_absent "omitting --kill-switch removes its UCI rule" uci -q get network.domain_kill_switch
    expect_absent "omitting --ipv6-deny removes vpn_domains6" uci -q get firewall.vpn_domains6
    expect_eq "omitting --no-icanhazip restores the default mapping" vpn_domains "$(uci -q get dhcp.vpn_icanhazip.name)"
    expect_eq "WDNS remains configured because no removal option exists" "6,$WDNS_ADDRESS" "$(uci -q get dhcp.wdns.dhcp_option)"
    expect_eq "sing-box configuration remains unchanged" "$SINGBOX_HASH_BEFORE" "$(singbox_config_hash)"
else
    fail "reinstallation without mode flags succeeds"
fi
end_case

run_country_case 2 russia-outside \
    'https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/outside-dnsmasq-nfset.lst'
run_country_case 3 ukraine \
    'https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Ukraine/inside-dnsmasq-nfset.lst'

begin_case invalid-country-selection
if reset_domain_routing > "$RESULT_DIR/logs/$CURRENT_CASE.uninstall.log" 2>&1; then
    pass "WAN and DNS recover before the invalid country case"
else
    fail "WAN and DNS recover before the invalid country case"
fi
before=$(config_fingerprint)
run_installer 9 "$CURRENT_CASE.install"
actual_rc=$?
after=$(config_fingerprint)
expect_eq "unknown country selection is rejected" 1 "$actual_rc"
expect_eq "unknown country selection is rejected before persistent configuration changes" "$before" "$after"
end_case

begin_case final-default-restoration
if reset_domain_routing > "$RESULT_DIR/logs/$CURRENT_CASE.uninstall.log" 2>&1; then
    pass "WAN and DNS recover before final restoration"
else
    fail "WAN and DNS recover before final restoration"
fi
if run_installer 1 "$CURRENT_CASE.install"; then
    pass "default installation is restored after the suite"
    verify_or_recover_domain_list 0 || true
    assert_installed_mode 0 0 1 0 \
        'https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst'
    expect_eq "sing-box configuration hash matches the initial value" "$SINGBOX_HASH_BEFORE" "$(singbox_config_hash)"
else
    fail "default installation is restored after the suite"
fi
printf 'SINGBOX_CONFIG_SHA256_AFTER=%s\n' "$(singbox_config_hash)" >> "$RESULT_DIR/metadata.txt"
end_case

printf '%s\n' "Assertions: $TOTAL total, $PASSED passed, $FAILED failed, $SKIPPED skipped"
[ "$FAILED" -eq 0 ]
