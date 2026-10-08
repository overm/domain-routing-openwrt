#!/bin/sh

set -eu

/etc/init.d/getdomains stop 2>/dev/null || true
/etc/init.d/getdomains disable 2>/dev/null || true
if [ -f /tmp/getdomains-wdns-guards ]; then
    while read -r address; do ip -4 rule del priority 79 to "$address" unreachable || true; done < /tmp/getdomains-wdns-guards
    rm -f /tmp/getdomains-wdns-guards
fi
confdir=$(uci -q get dhcp.@dnsmasq[0].confdir || true)
confdir=${confdir%%,*}
if [ -n "$confdir" ]; then rm -f "$confdir/domains.lst"; fi
if [ -f /etc/getdomains/owns-confdir ] && [ "$confdir" = /tmp/dnsmasq.d ]; then
    uci -q delete dhcp.@dnsmasq[0].confdir || true
fi
for option in flow_offloading flow_offloading_hw noresolv resolvfile; do
    file=/etc/getdomains/$option.previous
    [ -f "$file" ] || continue
    case $option in
        flow_*) key="firewall.@defaults[0].$option"; expected=0;;
        noresolv) key='dhcp.@dnsmasq[0].noresolv'; expected=0;;
        resolvfile) key='dhcp.@dnsmasq[0].resolvfile'; expected=/tmp/resolv.conf.d/resolv.conf.auto;;
    esac
    if [ "$(uci -q get "$key" || true)" = "$expected" ]; then
        previous=$(cat "$file")
        if [ "$previous" = __unset__ ]; then uci -q delete "$key" || true
        else uci set "$key=$previous"; fi
    fi
    rm -f "$file"
done
rm -f /etc/init.d/getdomains /etc/rc.d/S99getdomains /etc/rc.d/S18getdomains /etc/hotplug.d/iface/30-vpnroute \
    /etc/getdomains/refresh-prerouting.nft /etc/getdomains/refresh-output.nft \
    /etc/getdomains/save-prerouting.nft /etc/getdomains/save-output.nft \
    /etc/getdomains/source-url /etc/getdomains/domains.source /etc/getdomains/owns-confdir \
    /etc/getdomains/firewall-reload.sh /tmp/getdomains-restart-pending \
    /usr/libexec/getdomains-runtime /usr/libexec/getdomains-compile.awk \
    /tmp/getdomains-static.nft \
    /usr/bin/getdomains-check /usr/bin/getdomains-uninstall
rmdir /etc/getdomains 2>/dev/null || true
[ ! -f /etc/crontabs/root ] || sed -i '\|/etc/init.d/getdomains start|d;\|/etc/init.d/getdomains refresh|d' /etc/crontabs/root
sed -i '/^[[:space:]]*99[[:space:]]\+vpn$/d' /etc/iproute2/rt_tables

for section in mark0x1 domain_kill_switch tun0_download wdns_tunnel wdns_no_fallback singbox_tun; do uci -q delete "network.$section" || true; done
for section in singbox tun_client_flows lan_singbox vpn_domains vpn_domains6 block_domains6 block_local_domains6 refresh_domains_prerouting refresh_domains_output save_domains_prerouting save_domains_output getdomains_dns_reload vpn_subnets vpn_ip vpn_community mark_domains mark_local_domains mark_subnet mark_ip mark_community; do
    uci -q delete "firewall.$section" || true
done
uci commit network
uci commit firewall
uci -q delete dhcp.vpn_icanhazip || true
# Remove the tag definition only; keep all static-lease tag references for reuse.
uci -q delete dhcp.wdns || true
uci commit dhcp

# Keep unrelated files in a shared dnsmasq confdir and all manual LuCI records.
/etc/init.d/cron restart
/etc/init.d/dnsmasq restart
/etc/init.d/firewall restart
/etc/init.d/network restart

echo "Domain routing was removed. sing-box and its configuration were kept."
