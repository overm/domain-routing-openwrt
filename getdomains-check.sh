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
    BAD_LOCAL_DOMAIN_RULE="router-local vpn_domains traffic is not marked"
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
    BAD_LOCAL_DOMAIN_RULE="локальный трафик роутера к vpn_domains не маркируется"
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
