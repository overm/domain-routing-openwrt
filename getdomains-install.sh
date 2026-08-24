#!/bin/sh

set -eu

green() { printf '\033[32;1m%s\033[0m\n' "$*"; }
red() { printf '\033[31;1m%s\033[0m\n' "$*" >&2; }

. /etc/os-release
VERSION_MAJOR=${VERSION_ID%%.*}
if [ "$VERSION_MAJOR" -lt 25 ]; then
    red "This installer supports OpenWrt 25 and newer only."
    exit 1
fi
if ! command -v apk >/dev/null 2>&1; then
    red "apk was not found. OpenWrt 25+ firmware with apk is required (not apt or opkg)."
    exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
    red "curl was not found. Install it before launching this script: apk update && apk add curl"
    exit 1
fi

green "Refreshing apk indexes"
apk update
apk add sing-box dnsmasq-full nano

AVAILABLE_SPACE=$(df -k / | awk 'NR == 2 { print $4 }')
if [ "${AVAILABLE_SPACE:-0}" -lt 4096 ]; then
    red "Less than 4 MiB is available after package installation."
    exit 1
fi

SCRIPT_BASE_URL=${GETDOMAINS_SCRIPT_BASE_URL:-https://raw.githubusercontent.com/overm/domain-routing-openwrt/master}
for script in getdomains-check getdomains-uninstall; do
    temporary="/tmp/${script}.sh.$$"
    rm -f "$temporary"
    if ! curl -fL --connect-timeout 10 --max-time 120 --retry 5 \
        --retry-delay 2 "$SCRIPT_BASE_URL/${script}.sh" -o "$temporary" || \
        ! sh -n "$temporary"; then
        rm -f /tmp/getdomains-check.sh.$$ /tmp/getdomains-uninstall.sh.$$
        red "Could not download ${script}.sh. No router configuration was changed."
        exit 1
    fi
done
for script in getdomains-check getdomains-uninstall; do
    temporary="/tmp/${script}.sh.$$"
    chmod 0755 "$temporary"
    mv -f "$temporary" "/usr/bin/$script"
done

mkdir -p /tmp/dnsmasq.d /tmp/lst /etc/sing-box /etc/hotplug.d/iface /etc/iproute2

if [ ! -s /etc/sing-box/config.json ]; then
    cat > /etc/sing-box/config.json <<'EOF'
{
  "log": { "level": "info" },
  "inbounds": [{
    "type": "tun",
    "tag": "tun-in",
    "interface_name": "tun0",
    "address": ["172.16.250.1/30"],
    "auto_route": false,
    "strict_route": false
  }],
  "outbounds": [{
    "type": "shadowsocks",
    "tag": "proxy",
    "server": "CHANGE_ME",
    "server_port": 443,
    "method": "2022-blake3-aes-128-gcm",
    "password": "CHANGE_ME"
  }],
  "route": { "auto_detect_interface": true }
}
EOF
    green "Created /etc/sing-box/config.json; edit the CHANGE_ME values before starting sing-box."
fi

uci -q batch <<'EOF'
set sing-box.main=sing-box
set sing-box.main.enabled='1'
set sing-box.main.user='root'
set sing-box.main.conffile='/etc/sing-box/config.json'
set sing-box.main.workdir='/usr/share/sing-box'
set network.mark0x1=rule
set network.mark0x1.name='mark0x1'
set network.mark0x1.mark='0x1'
set network.mark0x1.priority='100'
set network.mark0x1.lookup='vpn'
set firewall.singbox=zone
set firewall.singbox.name='tun'
set firewall.singbox.device='tun0'
set firewall.singbox.input='REJECT'
set firewall.singbox.output='ACCEPT'
set firewall.singbox.forward='REJECT'
set firewall.singbox.masq='1'
set firewall.singbox.mtu_fix='1'
set firewall.singbox.family='ipv4'
set firewall.lan_singbox=forwarding
set firewall.lan_singbox.name='lan-tun'
set firewall.lan_singbox.src='lan'
set firewall.lan_singbox.dest='tun'
set firewall.lan_singbox.family='ipv4'
set firewall.vpn_domains=ipset
set firewall.vpn_domains.name='vpn_domains'
set firewall.vpn_domains.match='dst_net'
set firewall.mark_domains=rule
set firewall.mark_domains.name='mark_domains'
set firewall.mark_domains.src='lan'
set firewall.mark_domains.dest='*'
set firewall.mark_domains.proto='all'
set firewall.mark_domains.ipset='vpn_domains'
set firewall.mark_domains.set_mark='0x1'
set firewall.mark_domains.target='MARK'
set firewall.mark_domains.family='ipv4'
set dhcp.@dnsmasq[0].confdir='/tmp/dnsmasq.d'
commit sing-box
commit network
commit firewall
commit dhcp
EOF

grep -q '^99[[:space:]]\+vpn$' /etc/iproute2/rt_tables 2>/dev/null || echo '99 vpn' >> /etc/iproute2/rt_tables
cat > /etc/hotplug.d/iface/30-vpnroute <<'EOF'
#!/bin/sh
attempt=0
while [ "$attempt" -lt 10 ]; do
    if ip link show dev tun0 >/dev/null 2>&1; then
        exec ip route replace table vpn default dev tun0
    fi
    attempt=$((attempt + 1))
    sleep 1
done
logger -t vpnroute "tun0 did not appear; vpn route was not changed"
exit 1
EOF
chmod 0755 /etc/hotplug.d/iface/30-vpnroute

printf '%s\n' \
    'Select the domain list:' \
    '1) Russia inside' \
    '2) Russia outside' \
    '3) Ukraine'
printf 'Selection [1]: '
read -r COUNTRY
case ${COUNTRY:-1} in
    1) DOMAINS_URL='https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst' ;;
    2) DOMAINS_URL='https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/outside-dnsmasq-nfset.lst' ;;
    3) DOMAINS_URL='https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Ukraine/inside-dnsmasq-nfset.lst' ;;
    *) red "Unknown selection"; exit 1 ;;
esac

cat > /etc/init.d/getdomains <<EOF
#!/bin/sh /etc/rc.common
START=99

download_domains() {
    destination=/tmp/dnsmasq.d/domains.lst
    temporary="\${destination}.tmp.\$\$"

    rm -f "\$temporary"
    if ! curl -fL --interface tun0 --connect-timeout 10 --max-time 120 --retry 5 \\
        --retry-delay 2 '$DOMAINS_URL' -o "\$temporary"; then
        rm -f "\$temporary"
        logger -t getdomains "domain list download through tun0 failed"
        return 1
    fi
    if [ ! -s "\$temporary" ] || ! dnsmasq --conf-file="\$temporary" --test >/dev/null 2>&1; then
        rm -f "\$temporary"
        logger -t getdomains "downloaded domain list failed validation"
        return 1
    fi
    if [ -f "\$destination" ] && cmp -s "\$temporary" "\$destination"; then
        rm -f "\$temporary"
        return 2
    fi
    mv -f "\$temporary" "\$destination"
}

start() {
    lock=/var/lock/getdomains.lock
    if ! mkdir "\$lock" 2>/dev/null; then
        logger -t getdomains "refresh is already running"
        return 0
    fi
    cleanup() {
        rm -rf "\$lock"
        rm -f /tmp/dnsmasq.d/domains.lst.tmp.\$\$
    }
    trap cleanup 0
    trap 'exit 1' HUP INT TERM
    mkdir -p /tmp/dnsmasq.d
    download_domains
    result=\$?
    [ "\$result" -eq 2 ] && return 0
    [ "\$result" -eq 0 ] || return "\$result"
    /etc/init.d/dnsmasq restart
}
EOF
chmod 0755 /etc/init.d/getdomains
/etc/init.d/getdomains enable
grep -q '/etc/init.d/getdomains start' /etc/crontabs/root 2>/dev/null || echo '0 4 * * * /etc/init.d/getdomains start' >> /etc/crontabs/root
/etc/init.d/cron enable
/etc/init.d/cron restart

printf 'Edit /etc/sing-box/config.json in nano now? [y/N]: '
read -r EDIT_SINGBOX || EDIT_SINGBOX=n
case ${EDIT_SINGBOX:-n} in
    y|Y|yes|YES|Yes) nano /etc/sing-box/config.json ;;
esac

SINGBOX_STARTED=0
if sing-box check -c /etc/sing-box/config.json; then
    if /etc/init.d/sing-box restart; then
        SINGBOX_STARTED=1
    else
        red "sing-box failed to start; skipping the initial domain-list download."
    fi
else
    red "sing-box configuration is not valid; skipping the initial domain-list download."
fi
/etc/init.d/firewall restart
/etc/init.d/network restart

SINGBOX_READY=0
if [ "$SINGBOX_STARTED" -eq 1 ]; then
    attempt=0
    while [ "$attempt" -lt 10 ]; do
        if ip link show dev tun0 >/dev/null 2>&1; then
            SINGBOX_READY=1
            break
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    if [ "$SINGBOX_READY" -eq 0 ]; then
        red "sing-box started but tun0 did not appear; skipping the initial domain-list download."
    fi
fi
if [ "$SINGBOX_READY" -eq 1 ] && ! /etc/init.d/getdomains start; then
    red "The initial domain-list download through tun0 failed; run /etc/init.d/getdomains start after the tunnel is available."
fi

green "Done. Validate /etc/sing-box/config.json, then run: service sing-box restart"
