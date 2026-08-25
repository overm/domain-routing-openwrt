#!/bin/sh

set -eu

rm -f /etc/init.d/getdomains /etc/rc.d/S99getdomains /etc/hotplug.d/iface/30-vpnroute \
    /usr/bin/getdomains-check /usr/bin/getdomains-uninstall
sed -i '\|/etc/init.d/getdomains start|d' /etc/crontabs/root
sed -i '/^[[:space:]]*99[[:space:]]\+vpn$/d' /etc/iproute2/rt_tables

for section in mark0x1 tun0_download singbox_tun; do uci -q delete "network.$section" || true; done
for section in singbox tun_client_flows lan_singbox vpn_domains vpn_subnets vpn_ip vpn_community mark_domains mark_subnet mark_ip mark_community; do
    uci -q delete "firewall.$section" || true
done
uci commit network
uci commit firewall

rm -rf /tmp/dnsmasq.d /tmp/lst
/etc/init.d/cron restart
/etc/init.d/firewall restart
/etc/init.d/network restart

echo "Domain routing was removed. sing-box and its configuration were kept."
