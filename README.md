# Доменная маршрутизация для OpenWrt 25+

Проект направляет выбранные домены и IPv4-сети через TUN-интерфейс
**sing-box**. Требуется OpenWrt 25 или новее. Старые выпуски OpenWrt, а также
WireGuard, AmneziaWG, OpenVPN и tun2socks больше не поддерживаются.

## Что изменилось в OpenWrt 25

В OpenWrt 25 пакетный менеджер `opkg` заменён на **`apk`**, а не на `apt` из
Debian/Ubuntu. Поэтому обе реализации проекта используют `apk update`,
`apk add` и `apk info -e`. Проект теперь рассчитан только на firewall4/nftables
и списки dnsmasq `nfset`; код совместимости со старым ipset удалён.

Автономный установщик до внесения изменений проверяет версию OpenWrt и наличие
`apk`. Он устанавливает `curl`, `sing-box` и `dnsmasq-full`, создаёт правила для
`tun0` и не перезаписывает существующий `/etc/sing-box/config.json`.

```sh
curl -fsSL https://raw.githubusercontent.com/itdoginfo/domain-routing-openwrt/main/getdomains-install.sh -o /tmp/getdomains-install.sh
sh /tmp/getdomains-install.sh
```

В начальном конфиге sing-box есть значения `CHANGE_ME`. Замените их и проверьте
конфигурацию до запуска сервиса:

```sh
sing-box check -c /etc/sing-box/config.json
service sing-box restart
```

## Ansible-роль

Публичные переменные:

```yaml
tunnel: singbox                 # единственное допустимое значение
country: russia-inside          # russia-inside, russia-outside, ukraine
list_domains: true
list_subnet: false
list_ip: false
list_community: false
dns_encrypt: false              # false, dnscrypt-proxy2, stubby
nano: true
```

Пример playbook:

```yaml
- hosts: openwrt
  remote_user: root
  roles:
    - itdoginfo.domain_routing_openwrt
  vars:
    tunnel: singbox
    country: russia-inside
```

Роль создаёт начальный `/etc/sing-box/config.json`, только если файла ещё нет,
поэтому следующий запуск Ansible не перезапишет параметры подключения. В
inventory должна быть группа `[openwrt]`.

## Проверка и удаление

```sh
sh getdomains-check.sh --lang=ru
sh getdomains-uninstall.sh
```

Скрипт удаления убирает правила доменной маршрутизации, но намеренно сохраняет
пакет и конфигурацию sing-box.

## Лицензия

GNU General Public License v3.0.
