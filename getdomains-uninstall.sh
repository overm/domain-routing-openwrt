#!/bin/ash

echo "Выпиливаем скрипты"
/etc/init.d/getdomains disable
rm -rf /etc/init.d/getdomains

rm -f /etc/hotplug.d/iface/30-vpnroute /etc/hotplug.d/net/30-vpnroute

echo "Выпиливаем из crontab"
sed -i '/getdomains start/d' /etc/crontabs/root

echo "Выпиливаем домены"
rm -f /tmp/dnsmasq.d/domains.lst

echo "Чистим firewall, раз раз 🍴"

ipset_id=$(uci show firewall | grep -E '@ipset.*name=.vpn_domains.' | awk -F '[][{}]' '{print $2}' | head -n 1)
if [ ! -z "$ipset_id" ]; then
    while uci -q delete firewall.@ipset[$ipset_id]; do :; done
fi

rule_id=$(uci show firewall | grep -E '@rule.*name=.mark_domains.' | awk -F '[][{}]' '{print $2}' | head -n 1)
if [ ! -z "$rule_id" ]; then
    while uci -q delete firewall.@rule[$rule_id]; do :; done
fi


ipset_id=$(uci show firewall | grep -E '@ipset.*name=.vpn_subnet.' | awk -F '[][{}]' '{print $2}' | head -n 1)
if [ ! -z "$ipset_id" ]; then
    while uci -q delete firewall.@ipset[$ipset_id]; do :; done
fi

rule_id=$(uci show firewall | grep -E '@rule.*name=.mark_subnet.' | awk -F '[][{}]' '{print $2}' | head -n 1)
if [ ! -z "$rule_id" ]; then
    while uci -q delete firewall.@rule[$rule_id]; do :; done
fi

uci commit firewall
/etc/init.d/firewall restart

echo "Чистим сеть"
sed -i '/99 vpn/d' /etc/iproute2/rt_tables

rule_id=$(uci show network | grep -E '@rule.*name=.mark0x1.' | awk -F '[][{}]' '{print $2}' | head -n 1)
if [ ! -z "$rule_id" ]; then
    while uci -q delete network.@rule[$rule_id]; do :; done
fi


uci commit network
/etc/init.d/network restart

echo "Проверяем Dnsmasq"
if uci show dhcp | grep -q ipset; then
    echo "В dnsmasq (/etc/config/dhcp) заданы домены. Нужные из них сохраните, остальные удалите вместе с ipset"
fi

echo "Конфигурацию sing-box, его зону и forwarding оставляем на месте"
echo "Dnscrypt, stubby тоже не трогаем"

echo "  ______  _____        _____   _____  ______  _     _  _____   _____"
echo " |  ____ |     |      |_____] |     | |     \ |____/  |     | |_____]"
echo " |_____| |_____|      |       |_____| |_____/ |    \_ |_____| |     "
