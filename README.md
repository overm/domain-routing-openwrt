# Доменная маршрутизация для OpenWrt 24.10+

Проект направляет выбранные домены и IPv4-подсети через TUN-интерфейс
**sing-box**. Это единственный поддерживаемый VPN/прокси-сервис. OpenWrt 23.05 и
более старые версии отклоняются установщиком и ролью Ansible.

## Что важно в OpenWrt 24.10

OpenWrt 24.10 использует firewall4/nftables и списки dnsmasq `nfset`, поэтому из
проекта удалены ветки совместимости с legacy ipset. В стабильной OpenWrt 24.10
используется **opkg**, а не apt. В более новых ветках OpenWrt появился **apk**;
скрипт и задачи установки автоматически выбирают доступный `opkg` или `apk`.
Подробности приведены в
[официальных примечаниях к выпуску 24.10.0](https://github.com/openwrt/openwrt/releases/tag/v24.10.0).

Перед установкой обновите маршрутизатор по инструкции именно для своей модели.
Не запускайте установщик на обычном Linux-компьютере: он изменяет UCI, firewall,
dnsmasq и таблицы маршрутизации.

## Установка скриптом

```sh
wget -O /tmp/getdomains-install.sh https://raw.githubusercontent.com/itdoginfo/domain-routing-openwrt/master/getdomains-install.sh
sh /tmp/getdomains-install.sh
```

Установщик поставит sing-box и, если конфигурации ещё нет, создаст шаблон
`/etc/sing-box/config.json`. Замените значения `CHANGE_ME`, проверьте файл и
перезапустите сервис:

```sh
sing-box -c /etc/sing-box/config.json check
service sing-box restart
```

Проверка и удаление:

```sh
wget -O - https://raw.githubusercontent.com/itdoginfo/domain-routing-openwrt/master/getdomains-check.sh | sh
sh <(wget -O - https://raw.githubusercontent.com/itdoginfo/domain-routing-openwrt/master/getdomains-uninstall.sh)
```

## Роль Ansible

Установите роль `itdoginfo.domain_routing_openwrt`. В inventory маршрутизатор
должен входить в группу `[openwrt]`; требуется роль `gekmihesg.openwrt`.

```yaml
- hosts: openwrt
  remote_user: root
  roles:
    - itdoginfo.domain_routing_openwrt
  vars:
    tunnel: singbox
    country: russia-inside
    list_domains: true
    list_subnet: false
    list_ip: false
    list_community: false
    dns_encrypt: false       # false, dnscrypt или stubby
    nano: true
```

Переменные:

- `tunnel`: допускается только `singbox`;
- `country`: `russia-inside`, `russia-outside` или `ukraine`;
- `list_domains`, `list_subnet`, `list_ip`, `list_community`: включают отдельные
  списки назначений, реализованные nftables;
- `dns_encrypt`: `false`, `dnscrypt` или `stubby`;
- `nano`: установка редактора.

При включённом `list_domains` пакет `dnsmasq-full` устанавливается автоматически.
Шаблон sing-box не содержит реальных реквизитов подключения — их необходимо
заполнить самостоятельно.

## Лицензия

GNU General Public License v3.0.
