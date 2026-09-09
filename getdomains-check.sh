#!/bin/sh

LANGUAGE=ru
case ${1:-} in
    --lang=en) LANGUAGE=en ;;
    --lang=ru|'') ;;
    *) echo "Usage: $0 [--lang=ru|--lang=en]" >&2; exit 2 ;;
esac

ok() { printf '\033[32;1m[OK]\033[0m %s\n' "$*"; }
fail() { printf '\033[31;1m[ERROR]\033[0m %s\n' "$*"; ERRORS=$((ERRORS + 1)); }
ERRORS=0

if [ "$LANGUAGE" = en ]; then
    UNSUPPORTED="OpenWrt 25 or newer is required"
    MISSING_APK="apk is missing (OpenWrt 25+ uses apk, not apt or opkg)"
    MISSING_PACKAGE="package is not installed"
    BAD_CONFIG="sing-box configuration is invalid"
    BAD_LOOP_GUARD="sing-box TUN loop protection is missing (set a global interface or bind every outbound)"
    BAD_ROUTE="vpn table has no default route through tun0"
    BAD_TUN_INTERFACE="netifd interface singbox_tun is missing"
    BAD_DOWNLOAD_RULE="locally bound tun0 traffic does not use the vpn table"
    BAD_MARK_RULE="marked IPv4 traffic does not use the vpn table at priority 100"
    BAD_KILL_SWITCH="IPv4 kill switch configuration is incomplete or inactive"
    KILL_SWITCH_ON="IPv4 kill switch enabled"
    KILL_SWITCH_OFF="direct IPv4 fallback enabled"
    BAD_LOCAL_DOMAIN_RULE="router-local vpn_domains traffic is not marked"
    BAD_DOMAIN_SET="vpn_domains timeout configuration is incomplete or inactive"
    DOMAIN_SET_OK="vpn_domains uses a bounded two-day timeout"
    BAD_TIMEOUT_REFRESH="domain-set timeout refresh rules are incomplete or inactive"
    TIMEOUT_REFRESH_ON="domain-set timeouts refresh on new matching connections"
    BAD_IPV6_DENY="IPv6 deny configuration is incomplete or inactive"
    IPV6_DENY_ON="direct IPv6 access to selected domains rejected"
    IPV6_DENY_OFF="direct IPv6 fallback enabled"
    BAD_DOMAIN_LIST="runtime domain list is missing or does not match the configured IP families"
    BAD_TUN_INPUT="firewall accepts unsolicited input from tun0"
    BAD_TUN_REPLY_RULE="narrow firewall rule for sing-box TUN client flows is missing"
else
    UNSUPPORTED="Требуется OpenWrt 25 или новее"
    MISSING_APK="apk не найден (OpenWrt 25+ использует apk, не apt и не opkg)"
    MISSING_PACKAGE="пакет не установлен"
    BAD_CONFIG="конфигурация sing-box некорректна"
    BAD_LOOP_GUARD="не настроена защита от петли TUN в sing-box (задайте глобальный интерфейс или привяжите каждый outbound)"
    BAD_ROUTE="в таблице vpn нет маршрута по умолчанию через tun0"
    BAD_TUN_INTERFACE="интерфейс netifd singbox_tun отсутствует"
    BAD_DOWNLOAD_RULE="локальный трафик, привязанный к tun0, не направляется в таблицу vpn"
    BAD_MARK_RULE="маркированный IPv4-трафик не направляется в таблицу vpn с приоритетом 100"
    BAD_KILL_SWITCH="IPv4 kill switch настроен не полностью или не активен"
    KILL_SWITCH_ON="IPv4 kill switch включён"
    KILL_SWITCH_OFF="прямой резервный маршрут IPv4 разрешён"
    BAD_LOCAL_DOMAIN_RULE="локальный трафик роутера к vpn_domains не маркируется"
    BAD_DOMAIN_SET="настройка timeout для vpn_domains неполна или неактивна"
    DOMAIN_SET_OK="vpn_domains использует ограниченный двухдневный timeout"
    BAD_TIMEOUT_REFRESH="правила обновления timeout доменных наборов неполны или неактивны"
    TIMEOUT_REFRESH_ON="timeout доменных наборов обновляется при новых совпадающих соединениях"
    BAD_IPV6_DENY="блокировка прямого IPv6 настроена не полностью или не активна"
    IPV6_DENY_ON="прямой IPv6 к выбранным доменам отклоняется"
    IPV6_DENY_OFF="прямой резервный маршрут IPv6 разрешён"
    BAD_DOMAIN_LIST="рабочий доменный список отсутствует или не соответствует настроенным семействам IP"
    BAD_TUN_INPUT="firewall принимает незапрошенный входящий трафик из tun0"
    BAD_TUN_REPLY_RULE="отсутствует узкое правило firewall для клиентских соединений sing-box TUN"
fi

all_outbounds_bound() {
    outbound_types=$(jsonfilter -i /etc/sing-box/config.json -e '@.outbounds[*].type' 2>/dev/null)
    bound_interfaces=$(jsonfilter -i /etc/sing-box/config.json -e '@.outbounds[*].bind_interface' 2>/dev/null)
    [ -n "$outbound_types" ] && [ -n "$bound_interfaces" ] || return 1

    outbound_count=$(printf '%s\n' "$outbound_types" | wc -l)
    bound_count=$(printf '%s\n' "$bound_interfaces" | wc -l)
    [ "$outbound_count" -eq "$bound_count" ]
}

ipv4_domain_set_config_valid() {
    [ "$(uci -q get firewall.vpn_domains)" = ipset ] &&
        [ "$(uci -q get firewall.vpn_domains.name)" = vpn_domains ] &&
        [ "$(uci -q get firewall.vpn_domains.match)" = dst_ip ] &&
        [ "$(uci -q get firewall.vpn_domains.family)" = ipv4 ] &&
        [ "$(uci -q get firewall.vpn_domains.timeout)" = 172800 ] &&
        [ "$(uci -q get firewall.vpn_domains.maxelem)" = 65536 ]
}

ipv6_deny_config_valid() {
    [ "$(uci -q get firewall.vpn_domains6)" = ipset ] &&
        [ "$(uci -q get firewall.vpn_domains6.name)" = vpn_domains6 ] &&
        [ "$(uci -q get firewall.vpn_domains6.match)" = dst_ip ] &&
        [ "$(uci -q get firewall.vpn_domains6.family)" = ipv6 ] &&
        [ "$(uci -q get firewall.vpn_domains6.timeout)" = 172800 ] &&
        [ "$(uci -q get firewall.vpn_domains6.maxelem)" = 65536 ] &&
        [ "$(uci -q get firewall.block_domains6.src)" = lan ] &&
        [ "$(uci -q get firewall.block_domains6.ipset)" = vpn_domains6 ] &&
        [ "$(uci -q get firewall.block_domains6.target)" = REJECT ] &&
        [ "$(uci -q get firewall.block_domains6.family)" = ipv6 ] &&
        [ -z "$(uci -q get firewall.block_local_domains6.src)" ] &&
        [ "$(uci -q get firewall.block_local_domains6.ipset)" = vpn_domains6 ] &&
        [ "$(uci -q get firewall.block_local_domains6.target)" = REJECT ] &&
        [ "$(uci -q get firewall.block_local_domains6.family)" = ipv6 ]
}

timeout_refresh_config_valid() {
    [ "$(uci -q get firewall.refresh_domains_prerouting)" = include ] &&
        [ "$(uci -q get firewall.refresh_domains_prerouting.type)" = nftables ] &&
        [ "$(uci -q get firewall.refresh_domains_prerouting.path)" = /etc/getdomains/refresh-prerouting.nft ] &&
        [ "$(uci -q get firewall.refresh_domains_prerouting.position)" = chain-prepend ] &&
        [ "$(uci -q get firewall.refresh_domains_prerouting.chain)" = mangle_prerouting ] &&
        [ "$(uci -q get firewall.refresh_domains_output)" = include ] &&
        [ "$(uci -q get firewall.refresh_domains_output.type)" = nftables ] &&
        [ "$(uci -q get firewall.refresh_domains_output.path)" = /etc/getdomains/refresh-output.nft ] &&
        [ "$(uci -q get firewall.refresh_domains_output.position)" = chain-prepend ] &&
        [ "$(uci -q get firewall.refresh_domains_output.chain)" = mangle_output ] &&
        [ -s /etc/getdomains/refresh-prerouting.nft ] &&
        [ -s /etc/getdomains/refresh-output.nft ]
}

timeout_refresh_runtime_valid() {
    nft list chain inet fw4 mangle_prerouting 2>/dev/null |
        grep -q 'ct state new.*ip daddr @vpn_domains.*update @vpn_domains.*ip daddr timeout 2d.*getdomains: refresh LAN IPv4 domain timeout' || return 1
    nft list chain inet fw4 mangle_output 2>/dev/null |
        grep -q 'ct state new.*ip daddr @vpn_domains.*update @vpn_domains.*ip daddr timeout 2d.*getdomains: refresh router IPv4 domain timeout' || return 1
    if [ "$IPV6_DENY_ENABLED" -eq 1 ]; then
        nft list chain inet fw4 mangle_prerouting 2>/dev/null |
            grep -q 'ct state new.*ip6 daddr @vpn_domains6.*update @vpn_domains6.*ip6 daddr timeout 2d.*getdomains: refresh LAN IPv6 domain timeout' || return 1
        nft list chain inet fw4 mangle_output 2>/dev/null |
            grep -q 'ct state new.*ip6 daddr @vpn_domains6.*update @vpn_domains6.*ip6 daddr timeout 2d.*getdomains: refresh router IPv6 domain timeout' || return 1
    fi
    return 0
}

ipv6_deny_runtime_valid() {
    nft list set inet fw4 vpn_domains6 >/dev/null 2>&1 &&
        nft list ruleset 2>/dev/null | grep -q 'Reject selected domains over IPv6' &&
        nft list ruleset 2>/dev/null | grep -q 'Reject router-local selected domains over IPv6'
}

domain_list_matches_mode() {
    domain_file=/tmp/dnsmasq.d/domains.lst
    [ -s "$domain_file" ] || return 1
    if [ "$IPV6_DENY_ENABLED" -eq 1 ]; then
        pattern='^nftset=/[A-Za-z0-9_.-]+/4#inet#fw4#vpn_domains,6#inet#fw4#vpn_domains6$'
    else
        pattern='^nftset=/[A-Za-z0-9_.-]+/4#inet#fw4#vpn_domains$'
    fi
    ! grep -Ev "$pattern" "$domain_file" >/dev/null 2>&1
}

. /etc/os-release
MAJOR=${VERSION_ID%%.*}
[ "$MAJOR" -ge 25 ] && ok "OpenWrt $VERSION_ID" || fail "$UNSUPPORTED: $VERSION_ID"
command -v apk >/dev/null 2>&1 && ok "apk" || fail "$MISSING_APK"

for package in curl dnsmasq-full ip-full sing-box; do
    if apk info -e "$package" >/dev/null 2>&1; then
        ok "$package"
    else
        fail "$package: $MISSING_PACKAGE"
    fi
done

if sing-box check -c /etc/sing-box/config.json >/dev/null 2>&1; then
    ok "sing-box config"
else
    fail "$BAD_CONFIG"
fi

if [ "$(jsonfilter -i /etc/sing-box/config.json -e '@.route.auto_detect_interface' 2>/dev/null)" = true ] ||
    [ -n "$(jsonfilter -i /etc/sing-box/config.json -e '@.route.default_interface' 2>/dev/null)" ] ||
    all_outbounds_bound; then
    ok "sing-box TUN loop protection"
else
    fail "$BAD_LOOP_GUARD"
fi

if service sing-box status 2>/dev/null | grep -q running; then ok "sing-box service"; else fail "sing-box service"; fi
if ip route show table vpn 2>/dev/null | grep -q '^default dev tun0'; then ok "vpn route"; else fail "$BAD_ROUTE"; fi
if ubus list network.interface.singbox_tun 2>/dev/null |
    grep -qx 'network.interface.singbox_tun'; then
    ok "singbox_tun netifd interface"
else
    fail "$BAD_TUN_INTERFACE"
fi
if ip rule show 2>/dev/null | grep -q 'oif tun0.*lookup vpn'; then ok "tun0 download rule"; else fail "$BAD_DOWNLOAD_RULE"; fi
if [ "$(uci -q get network.mark0x1.mark)" = 0x1 ] &&
    [ "$(uci -q get network.mark0x1.priority)" = 100 ] &&
    [ "$(uci -q get network.mark0x1.lookup)" = vpn ] &&
    ip rule show 2>/dev/null | grep -q '100:.*fwmark 0x1.*lookup vpn'; then
    ok "marked IPv4 policy rule"
else
    fail "$BAD_MARK_RULE"
fi
if uci -q get network.domain_kill_switch >/dev/null; then
    if [ "$(uci -q get network.domain_kill_switch)" = rule ] &&
        [ "$(uci -q get network.domain_kill_switch.mark)" = 0x1 ] &&
        [ "$(uci -q get network.domain_kill_switch.priority)" = 110 ] &&
        [ "$(uci -q get network.domain_kill_switch.action)" = unreachable ] &&
        [ -z "$(uci -q get network.domain_kill_switch.lookup)" ] &&
        ip rule show 2>/dev/null | grep -q '110:.*fwmark 0x1.*unreachable'; then
        ok "$KILL_SWITCH_ON"
    else
        fail "$BAD_KILL_SWITCH"
    fi
elif ip rule show 2>/dev/null | grep -q 'fwmark 0x1.*unreachable'; then
    fail "$BAD_KILL_SWITCH"
else
    ok "$KILL_SWITCH_OFF"
fi
if [ "$(uci -q get firewall.mark_local_domains.dest)" = '*' ] &&
    [ "$(uci -q get firewall.mark_local_domains.ipset)" = vpn_domains ] &&
    [ "$(uci -q get firewall.mark_local_domains.set_mark)" = 0x1 ] &&
    [ -z "$(uci -q get firewall.mark_local_domains.src)" ] &&
    nft list chain inet fw4 mangle_output 2>/dev/null |
    grep -q 'ip daddr @vpn_domains.*meta mark set 0x0*1.*mark_local_domains'; then
    ok "router-local vpn_domains marking"
else
    fail "$BAD_LOCAL_DOMAIN_RULE"
fi
if ipv4_domain_set_config_valid; then
    ok "$DOMAIN_SET_OK"
else
    fail "$BAD_DOMAIN_SET"
fi
IPV6_DENY_ENABLED=0
for section in vpn_domains6 block_domains6 block_local_domains6; do
    if uci -q get "firewall.$section" >/dev/null; then
        IPV6_DENY_ENABLED=1
    fi
done
if [ "$IPV6_DENY_ENABLED" -eq 1 ]; then
    if ipv6_deny_config_valid && ipv6_deny_runtime_valid; then
        ok "$IPV6_DENY_ON"
    else
        fail "$BAD_IPV6_DENY"
    fi
elif nft list set inet fw4 vpn_domains6 >/dev/null 2>&1 ||
    nft list ruleset 2>/dev/null | grep -q 'selected domains over IPv6'; then
    fail "$BAD_IPV6_DENY"
else
    ok "$IPV6_DENY_OFF"
fi
if timeout_refresh_config_valid && timeout_refresh_runtime_valid; then
    ok "$TIMEOUT_REFRESH_ON"
else
    fail "$BAD_TIMEOUT_REFRESH"
fi
if domain_list_matches_mode; then
    ok "runtime domain list"
else
    fail "$BAD_DOMAIN_LIST"
fi
if nft list chain inet fw4 input_tun 2>/dev/null |
    grep -q 'jump reject_from_tun'; then
    ok "tun0 unsolicited input rejected"
else
    fail "$BAD_TUN_INPUT"
fi
if [ "$(uci -q get firewall.singbox.input)" = REJECT ] &&
    [ "$(uci -q get firewall.tun_client_flows.src)" = tun ] &&
    [ "$(uci -q get firewall.tun_client_flows.src_ip)" = 172.16.250.2 ] &&
    [ "$(uci -q get firewall.tun_client_flows.dest_ip)" = 172.16.250.1 ] &&
    [ "$(uci -q get firewall.tun_client_flows.proto)" = tcp ] &&
    [ "$(uci -q get firewall.tun_client_flows.dest_port)" = 32768-60999 ] &&
    [ "$(uci -q get firewall.tun_client_flows.target)" = ACCEPT ] &&
    [ "$(uci -q get firewall.tun_client_flows.family)" = ipv4 ] &&
    nft list chain inet fw4 input_tun 2>/dev/null |
    grep -q 'Allow TUN TCP client flows'; then
    ok "narrow tun0 TCP client flows"
else
    fail "$BAD_TUN_REPLY_RULE"
fi
if nft list set inet fw4 vpn_domains >/dev/null 2>&1; then ok "vpn_domains nft set"; else fail "vpn_domains nft set"; fi
if service dnsmasq status 2>/dev/null | grep -q running; then ok "dnsmasq service"; else fail "dnsmasq service"; fi

exit "$ERRORS"
