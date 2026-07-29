# Domain routing for OpenWrt 24.10+

This project routes selected domains and IPv4 networks through a **sing-box**
TUN interface. sing-box is the only supported tunnel implementation. OpenWrt
23.05 and older are rejected.

## OpenWrt 24.10 notes

OpenWrt 24.10 uses firewall4/nftables sets and dnsmasq `nfset` lists. The project
therefore has no legacy ipset path. The 24.10 release uses **opkg**, not apt.
OpenWrt development releases introduced **apk** later; the standalone installer
and package tasks detect either `opkg` or `apk`. See the
[official 24.10.0 release notes](https://github.com/openwrt/openwrt/releases/tag/v24.10.0).

Do not run the installer on a non-OpenWrt host. Upgrade the router using the
official device-specific instructions before installing this project.

## Standalone installation

```sh
wget -O /tmp/getdomains-install.sh https://raw.githubusercontent.com/itdoginfo/domain-routing-openwrt/master/getdomains-install.sh
sh /tmp/getdomains-install.sh
```

The installer installs sing-box and creates a starter
`/etc/sing-box/config.json`. Replace its outbound placeholders, validate it with
`sing-box -c /etc/sing-box/config.json check`, then restart sing-box.

Diagnostics and removal:

```sh
wget -O - https://raw.githubusercontent.com/itdoginfo/domain-routing-openwrt/master/getdomains-check.sh | sh
sh <(wget -O - https://raw.githubusercontent.com/itdoginfo/domain-routing-openwrt/master/getdomains-uninstall.sh)
```

## Ansible role

Install `itdoginfo.domain_routing_openwrt`; the inventory must contain an
`[openwrt]` group. The role depends on `gekmihesg.openwrt`.

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
    dns_encrypt: false       # false, dnscrypt, or stubby
    nano: true
```

Public variables:

- `tunnel`: only `singbox` is accepted.
- `country`: `russia-inside`, `russia-outside`, or `ukraine`.
- `list_domains`, `list_subnet`, `list_ip`, `list_community`: enable individual
  nftables-backed destination lists.
- `dns_encrypt`: `false`, `dnscrypt`, or `stubby`.
- `nano`: install the editor when true.

`dnsmasq-full` is installed automatically when domain lists are enabled. The
included sing-box JSON is a template and must be configured with real outbound
connection data.

## License

GNU General Public License v3.0.
