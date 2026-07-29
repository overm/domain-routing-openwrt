#!/bin/sh

#set -x

check_repo() {
    printf "\033[32;1mChecking OpenWrt package repository availability...\033[0m\n"
    if command -v apk >/dev/null 2>&1; then
        PACKAGE_MANAGER=apk
        apk update || exit 1
    elif command -v opkg >/dev/null 2>&1; then
        PACKAGE_MANAGER=opkg
        opkg update | grep -q "Failed to download" && exit 1
    else
        echo "Neither apk nor opkg is available"
        exit 1
    fi
}

package_installed() {
    if [ "$PACKAGE_MANAGER" = apk ]; then apk info -e "$1" >/dev/null 2>&1
    else opkg list-installed "$1" 2>/dev/null | grep -q "^$1 "; fi
}

package_install() {
    if [ "$PACKAGE_MANAGER" = apk ]; then apk add "$@"; else opkg install "$@"; fi
}

route_vpn() {
    mkdir -p /etc/hotplug.d/iface /etc/hotplug.d/net
    cat << 'EOF' > /etc/hotplug.d/iface/30-vpnroute
#!/bin/sh
sleep 10
ip route replace table vpn default dev tun0
EOF
    chmod 0755 /etc/hotplug.d/iface/30-vpnroute
    cp /etc/hotplug.d/iface/30-vpnroute /etc/hotplug.d/net/30-vpnroute
}

add_mark() {
    grep -q "99 vpn" /etc/iproute2/rt_tables || echo '99 vpn' >> /etc/iproute2/rt_tables
    
    if ! uci show network | grep -q mark0x1; then
        printf "\033[32;1mConfigure mark rule\033[0m\n"
        uci add network rule
        uci set network.@rule[-1].name='mark0x1'
        uci set network.@rule[-1].mark='0x1'
        uci set network.@rule[-1].priority='100'
        uci set network.@rule[-1].lookup='vpn'
        uci commit
    fi
}

add_tunnel() {
    TUNNEL=singbox
    printf "\033[32;1mConfiguring sing-box as the only supported tunnel\033[0m\n"
    if package_installed sing-box; then
        echo "sing-box already installed"
    else
        AVAILABLE_SPACE=$(df -k / | awk 'NR == 2 { print $4 }')
        [ "${AVAILABLE_SPACE:-0}" -gt 2000 ] || { echo "Not enough free space for sing-box"; exit 1; }
        package_install sing-box
    fi
    if [ -f /etc/config/sing-box ]; then
        sed -i "s/option enabled '0'/option enabled '1'/" /etc/config/sing-box
        sed -i "s/option user 'sing-box'/option user 'root'/" /etc/config/sing-box
    fi
    mkdir -p /etc/sing-box
    if ! grep -q '"interface_name": "tun0"' /etc/sing-box/config.json 2>/dev/null; then
        cat << 'EOF' > /etc/sing-box/config.json
{
  "log": { "level": "info" },
  "inbounds": [{
    "type": "tun", "tag": "tun-in", "interface_name": "tun0",
    "address": ["172.16.250.1/30"], "auto_route": false, "strict_route": false
  }],
  "outbounds": [{
    "type": "shadowsocks", "tag": "proxy", "server": "CHANGE_ME",
    "server_port": 443, "method": "2022-blake3-aes-128-gcm", "password": "CHANGE_ME"
  }],
  "route": { "auto_detect_interface": true }
}
EOF
        echo "Created /etc/sing-box/config.json; configure its outbound before starting sing-box"
    fi
    route_vpn
}

dnsmasqfull() {
    if package_installed dnsmasq-full; then
        echo "dnsmasq-full already installed"
    elif [ "$PACKAGE_MANAGER" = apk ]; then
        apk add --force-overwrite dnsmasq-full
    else
        cd /tmp/ || exit 1
        opkg download dnsmasq-full && opkg remove dnsmasq && opkg install dnsmasq-full --cache /tmp/
        if [ -f /etc/config/dhcp-opkg ]; then
            cp /etc/config/dhcp /etc/config/dhcp-old
            mv /etc/config/dhcp-opkg /etc/config/dhcp
        fi
    fi
}

dnsmasqconfdir() {
    if [ $VERSION_ID -ge 24 ]; then
        if uci get dhcp.@dnsmasq[0].confdir | grep -q /tmp/dnsmasq.d; then
            printf "\033[32;1mconfdir already set\033[0m\n"
        else
            printf "\033[32;1mSetting confdir\033[0m\n"
            uci set dhcp.@dnsmasq[0].confdir='/tmp/dnsmasq.d'
            uci commit dhcp
        fi
    fi
}

remove_forwarding() {
    if [ ! -z "$forward_id" ]; then
        while uci -q delete firewall.@forwarding[$forward_id]; do :; done
    fi
}

add_zone() {
    if ! uci show firewall | grep -q "@zone.*name='singbox'"; then
        uci add firewall zone
        uci set firewall.@zone[-1].name='singbox'
        uci set firewall.@zone[-1].device='tun0'
        uci set firewall.@zone[-1].forward='ACCEPT'
        uci set firewall.@zone[-1].output='ACCEPT'
        uci set firewall.@zone[-1].input='ACCEPT'
        uci set firewall.@zone[-1].masq='1'
        uci set firewall.@zone[-1].mtu_fix='1'
        uci set firewall.@zone[-1].family='ipv4'
    fi
    if ! uci show firewall | grep -q "@forwarding.*name='singbox-lan'"; then
        uci add firewall forwarding
        uci set firewall.@forwarding[-1].name='singbox-lan'
        uci set firewall.@forwarding[-1].dest='singbox'
        uci set firewall.@forwarding[-1].src='lan'
        uci set firewall.@forwarding[-1].family='ipv4'
    fi
    uci commit firewall
}

show_manual() {
    echo "Configure /etc/sing-box/config.json, run sing-box check, then restart sing-box"
}

add_set() {
    if uci show firewall | grep -q "@ipset.*name='vpn_domains'"; then
        printf "\033[32;1mSet already exist\033[0m\n"
    else
        printf "\033[32;1mCreate set\033[0m\n"
        uci add firewall ipset
        uci set firewall.@ipset[-1].name='vpn_domains'
        uci set firewall.@ipset[-1].match='dst_net'
        uci commit
    fi
    if uci show firewall | grep -q "@rule.*name='mark_domains'"; then
        printf "\033[32;1mRule for set already exist\033[0m\n"
    else
        printf "\033[32;1mCreate rule set\033[0m\n"
        uci add firewall rule
        uci set firewall.@rule[-1]=rule
        uci set firewall.@rule[-1].name='mark_domains'
        uci set firewall.@rule[-1].src='lan'
        uci set firewall.@rule[-1].dest='*'
        uci set firewall.@rule[-1].proto='all'
        uci set firewall.@rule[-1].ipset='vpn_domains'
        uci set firewall.@rule[-1].set_mark='0x1'
        uci set firewall.@rule[-1].target='MARK'
        uci set firewall.@rule[-1].family='ipv4'
        uci commit
    fi
}

add_dns_resolver() {
    echo "Configure DNSCrypt2 or Stubby? It does matter if your ISP is spoofing DNS requests"
    DISK=$(df -m / | awk 'NR==2{ print $2 }')
    if [ "$DISK" -lt 32 ]; then
        printf "\033[31;1mYour router a disk have less than 32MB. It is not recommended to install DNSCrypt, it takes 10MB\033[0m\n"
    fi
    echo "Select:"
    echo "1) No [Default]"
    echo "2) DNSCrypt2 (10.7M)"
    echo "3) Stubby (36K)"

    while true; do
    read -r -p '' DNS_RESOLVER
        case $DNS_RESOLVER in 

        1) 
            echo "Skiped"
            break
            ;;

        2)
            DNS_RESOLVER=DNSCRYPT
            break
            ;;

        3) 
            DNS_RESOLVER=STUBBY
            break
            ;;

        *)
            echo "Choose from the following options"
            ;;
        esac
    done

    if [ "$DNS_RESOLVER" = 'DNSCRYPT' ]; then
        if package_installed dnscrypt-proxy2; then
            printf "\033[32;1mDNSCrypt2 already installed\033[0m\n"
        else
            printf "\033[32;1mInstalled dnscrypt-proxy2\033[0m\n"
            package_install dnscrypt-proxy2
            if grep -q "# server_names" /etc/dnscrypt-proxy2/dnscrypt-proxy.toml; then
                sed -i "s/^# server_names =.*/server_names = [\'google\', \'cloudflare\', \'scaleway-fr\', \'yandex\']/g" /etc/dnscrypt-proxy2/dnscrypt-proxy.toml
            fi

            printf "\033[32;1mDNSCrypt restart\033[0m\n"
            service dnscrypt-proxy restart
            printf "\033[32;1mDNSCrypt needs to load the relays list. Please wait\033[0m\n"
            sleep 30

            if [ -f /etc/dnscrypt-proxy2/relays.md ]; then
                uci set dhcp.@dnsmasq[0].noresolv="1"
                uci -q delete dhcp.@dnsmasq[0].server
                uci add_list dhcp.@dnsmasq[0].server="127.0.0.53#53"
                uci add_list dhcp.@dnsmasq[0].server='/use-application-dns.net/'
                uci commit dhcp
                
                printf "\033[32;1mDnsmasq restart\033[0m\n"

                /etc/init.d/dnsmasq restart
            else
                printf "\033[31;1mDNSCrypt not download list on /etc/dnscrypt-proxy2. Repeat install DNSCrypt by script.\033[0m\n"
            fi
    fi

    fi

    if [ "$DNS_RESOLVER" = 'STUBBY' ]; then
        printf "\033[32;1mConfigure Stubby\033[0m\n"

        if package_installed stubby; then
            printf "\033[32;1mStubby already installed\033[0m\n"
        else
            printf "\033[32;1mInstalled stubby\033[0m\n"
            package_install stubby

            printf "\033[32;1mConfigure Dnsmasq for Stubby\033[0m\n"
            uci set dhcp.@dnsmasq[0].noresolv="1"
            uci -q delete dhcp.@dnsmasq[0].server
            uci add_list dhcp.@dnsmasq[0].server="127.0.0.1#5453"
            uci add_list dhcp.@dnsmasq[0].server='/use-application-dns.net/'
            uci commit dhcp

            printf "\033[32;1mDnsmasq restart\033[0m\n"

            /etc/init.d/dnsmasq restart
        fi
    fi
}

add_packages() {
    for package in curl nano; do
        if package_installed "$package"; then
            printf "\033[32;1m$package already installed\033[0m\n"
        else
            printf "\033[32;1mInstalling $package...\033[0m\n"
            package_install "$package"
            
            if "$package" --version >/dev/null 2>&1; then
                printf "\033[32;1m$package was successfully installed and available\033[0m\n"
            else
                printf "\033[31;1mError: failed to install $package\033[0m\n"
                exit 1
            fi
        fi
    done
}

add_getdomains() {
    echo "Choose you country"
    echo "Select:"
    echo "1) Russia inside. You are inside Russia"
    echo "2) Russia outside. You are outside of Russia, but you need access to Russian resources"
    echo "3) Ukraine. uablacklist.net list"
    echo "4) Skip script creation"

    while true; do
    read -r -p '' COUNTRY
        case $COUNTRY in 

        1) 
            COUNTRY=russia_inside
            break
            ;;

        2)
            COUNTRY=russia_outside
            break
            ;;

        3) 
            COUNTRY=ukraine
            break
            ;;

        4) 
            echo "Skiped"
            COUNTRY=0
            break
            ;;

        *)
            echo "Choose from the following options"
            ;;
        esac
    done

    if [ "$COUNTRY" = 'russia_inside' ]; then
        EOF_DOMAINS=DOMAINS=https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-dnsmasq-nfset.lst
    elif [ "$COUNTRY" = 'russia_outside' ]; then
        EOF_DOMAINS=DOMAINS=https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/outside-dnsmasq-nfset.lst
    elif [ "$COUNTRY" = 'ukraine' ]; then
        EOF_DOMAINS=DOMAINS=https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Ukraine/inside-dnsmasq-nfset.lst
    fi

    if [ "$COUNTRY" != '0' ]; then
        printf "\033[32;1mCreate script /etc/init.d/getdomains\033[0m\n"

cat << EOF > /etc/init.d/getdomains
#!/bin/sh /etc/rc.common

START=99

start () {
    $EOF_DOMAINS
EOF
cat << 'EOF' >> /etc/init.d/getdomains
    count=0
    while true; do
        if curl -m 3 github.com; then
            curl -f $DOMAINS --output /tmp/dnsmasq.d/domains.lst
            break
        else
            echo "GitHub is not available. Check the internet availability [$count]"
            count=$((count+1))
        fi
    done

    if dnsmasq --conf-file=/tmp/dnsmasq.d/domains.lst --test 2>&1 | grep -q "syntax check OK"; then
        /etc/init.d/dnsmasq restart
    fi
}
EOF

        chmod +x /etc/init.d/getdomains
        /etc/init.d/getdomains enable

        if crontab -l | grep -q /etc/init.d/getdomains; then
            printf "\033[32;1mCrontab already configured\033[0m\n"

        else
            crontab -l | { cat; echo "0 */8 * * * /etc/init.d/getdomains start"; } | crontab -
            printf "\033[32;1mIgnore this error. This is normal for a new installation\033[0m\n"
            /etc/init.d/cron restart
        fi

        printf "\033[32;1mStart script\033[0m\n"

        /etc/init.d/getdomains start
    fi
}





# System Details
MODEL=$(cat /tmp/sysinfo/model)
. /etc/os-release
printf "\033[34;1mModel: $MODEL\033[0m\n"
printf "\033[34;1mVersion: $OPENWRT_RELEASE\033[0m\n"

VERSION_ID=$(echo $VERSION | awk -F. '{print $1}')

if [ "$VERSION_ID" -lt 24 ]; then
    printf "\033[31;1mOpenWrt 24.10 or newer is required\033[0m\n"
    exit 1
fi

printf "\033[31;1mAll actions performed here cannot be rolled back automatically.\033[0m\n"

check_repo

add_packages

add_tunnel

add_mark

add_zone

show_manual

add_set

dnsmasqfull

dnsmasqconfdir

add_dns_resolver

add_getdomains

printf "\033[32;1mRestart network\033[0m\n"
/etc/init.d/network restart

printf "\033[32;1mDone\033[0m\n"
