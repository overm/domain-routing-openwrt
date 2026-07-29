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
    BAD_ROUTE="vpn table has no default route through tun0"
else
    UNSUPPORTED="Требуется OpenWrt 25 или новее"
    MISSING_APK="apk не найден (OpenWrt 25+ использует apk, не apt и не opkg)"
    MISSING_PACKAGE="пакет не установлен"
    BAD_CONFIG="конфигурация sing-box некорректна"
    BAD_ROUTE="в таблице vpn нет маршрута по умолчанию через tun0"
fi

. /etc/os-release
MAJOR=${VERSION_ID%%.*}
[ "$MAJOR" -ge 25 ] && ok "OpenWrt $VERSION_ID" || fail "$UNSUPPORTED: $VERSION_ID"
command -v apk >/dev/null 2>&1 && ok "apk" || fail "$MISSING_APK"

for package in curl dnsmasq-full sing-box; do
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

if service sing-box status 2>/dev/null | grep -q running; then ok "sing-box service"; else fail "sing-box service"; fi
if ip route show table vpn 2>/dev/null | grep -q '^default dev tun0'; then ok "vpn route"; else fail "$BAD_ROUTE"; fi
if nft list set inet fw4 vpn_domains >/dev/null 2>&1; then ok "vpn_domains nft set"; else fail "vpn_domains nft set"; fi
if service dnsmasq status 2>/dev/null | grep -q running; then ok "dnsmasq service"; else fail "dnsmasq service"; fi

exit "$ERRORS"
