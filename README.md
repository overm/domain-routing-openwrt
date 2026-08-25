# Доменная маршрутизация для OpenWrt 25+

Проект направляет выбранные домены и IPv4-сети через TUN-интерфейс
**sing-box**. Требуется OpenWrt 25 или новее. Старые выпуски OpenWrt, а также
WireGuard, AmneziaWG, OpenVPN и tun2socks больше не поддерживаются.

## Что изменилось в OpenWrt 25

В OpenWrt 25 пакетный менеджер `opkg` заменён на **`apk`**, а не на `apt` из
Debian/Ubuntu. Поэтому обе реализации проекта используют `apk update`,
`apk add` и `apk info -e`. Проект теперь рассчитан только на firewall4/nftables
и списки dnsmasq `nfset`; код совместимости со старым ipset удалён.

Команда запуска устанавливает `curl`, необходимый для загрузки скрипта.
Автономный установщик до внесения изменений проверяет версию OpenWrt и наличие
`apk` и `curl`. Он устанавливает `sing-box`, `dnsmasq-full` и `nano`, создаёт
правила для `tun0`, сохраняет команды диагностики и удаления в `/usr/bin` и не
перезаписывает существующий `/etc/sing-box/config.json`. В конце установки
скрипт предлагает сразу открыть этот конфиг в `nano`.

```sh
apk update && apk add curl
curl -fsSL https://raw.githubusercontent.com/overm/domain-routing-openwrt/master/getdomains-install.sh -o /tmp/getdomains-install.sh
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
getdomains_connect_timeout: 10 # тайм-аут подключения, секунды
getdomains_max_time: 120       # тайм-аут одной загрузки, секунды
getdomains_retries: 5
getdomains_ready_timeout: 30     # ожидание интерфейса и DNS, секунды
getdomains_download_interface: tun0 # интерфейс для загрузки списков
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

Обновление списков выполняется транзакционно: данные сначала загружаются во
временный файл, доменный список проверяется через dnsmasq, и только после
успешной проверки активный файл атомарно заменяется. Блокировка исключает
одновременный запуск из cron и вручную, при ошибке сети или проверки продолжает
работать предыдущий список, а службы перезапускаются только при реальном
изменении данных. Адреса источников можно переопределить переменными
`domain_list_urls`, `subnet_list_url`, `ip_list_url` и `community_list_url`.
Загрузка выполняется через `getdomains_download_interface` (по умолчанию
`tun0`). Для локального процесса `curl`, привязанного к `tun0`, создаётся
отдельное policy rule: без него наличие default route только в таблице `vpn` не
заставляет локальный сокет использовать эту таблицу. Перед каждой загрузкой
скрипт до `getdomains_ready_timeout` секунд ждёт
появления интерфейса и успешного разрешения имени источника, поэтому короткий
перерыв DNS при применении сетевых настроек не приводит к немедленной ошибке.
Источник списка не должен быть доступен напрямую через WAN.
Перед первым обновлением настройте и запустите sing-box. Если установщик не смог
выполнить начальную загрузку, после запуска туннеля выполните
`/etc/init.d/getdomains start` вручную. Если списки доступны только через WAN,
явно задайте другой подходящий интерфейс.

## Проверка и удаление

```sh
getdomains-check --lang=ru
getdomains-uninstall
```

Скрипт удаления убирает правила доменной маршрутизации, но намеренно сохраняет
пакет и конфигурацию sing-box. Обе команды загружаются установщиком и остаются
доступны локально после очистки каталога `/tmp`; при удалении они также удаляются.

## Лицензия

GNU General Public License v3.0.
