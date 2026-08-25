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
    BAD_LOOP_GUARD="sing-box TUN loop protection is missing (set route.auto_detect_interface)"
    BAD_ROUTE="vpn table has no default route through tun0"
    BAD_TUN_INTERFACE="netifd interface singbox_tun is missing"
    BAD_DOWNLOAD_RULE="locally bound tun0 traffic does not use the vpn table"
    BAD_TUN_INPUT="firewall rejects replies from tun0 to the router"
else
    UNSUPPORTED="Требуется OpenWrt 25 или новее"
    MISSING_APK="apk не найден (OpenWrt 25+ использует apk, не apt и не opkg)"
    MISSING_PACKAGE="пакет не установлен"
    BAD_CONFIG="конфигурация sing-box некорректна"
    BAD_LOOP_GUARD="не настроена защита от петли TUN в sing-box (задайте route.auto_detect_interface)"
    BAD_ROUTE="в таблице vpn нет маршрута по умолчанию через tun0"
    BAD_TUN_INTERFACE="интерфейс netifd singbox_tun отсутствует"
    BAD_DOWNLOAD_RULE="локальный трафик, привязанный к tun0, не направляется в таблицу vpn"
    BAD_TUN_INPUT="firewall отклоняет ответы из tun0 к роутеру"
fi

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
    [ -n "$(jsonfilter -i /etc/sing-box/config.json -e '@.outbounds[*].bind_interface' 2>/dev/null)" ]; then
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
if nft list chain inet fw4 input_tun 2>/dev/null |
    grep -q 'jump accept_from_tun'; then
    ok "tun0 local input"
else
    fail "$BAD_TUN_INPUT"
fi
if nft list set inet fw4 vpn_domains >/dev/null 2>&1; then ok "vpn_domains nft set"; else fail "vpn_domains nft set"; fi
if service dnsmasq status 2>/dev/null | grep -q running; then ok "dnsmasq service"; else fail "dnsmasq service"; fi

exit "$ERRORS"
