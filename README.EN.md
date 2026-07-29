# Domain routing for OpenWrt 25+

This project routes selected domains and IPv4 networks through a **sing-box**
TUN interface. OpenWrt 25 or newer is required. Older OpenWrt releases and
WireGuard, AmneziaWG, OpenVPN, and tun2socks are no longer supported.

## OpenWrt 25 changes

OpenWrt 25 migrated its package manager from `opkg` to **`apk`**. It did not
migrate to Debian/Ubuntu's `apt`. Both installation paths therefore use
`apk update`, `apk add`, and `apk info -e`. The project targets firewall4/nftables
only and uses dnsmasq `nfset` lists; all legacy ipset compatibility code has
been removed.

The standalone installer checks both the OpenWrt major version and the presence
of `apk` before changing the device. It installs `curl`, `sing-box`, and
`dnsmasq-full`, creates the `tun0` firewall/routing configuration, and preserves
an existing `/etc/sing-box/config.json`.

```sh
curl -fsSL https://raw.githubusercontent.com/itdoginfo/domain-routing-openwrt/main/getdomains-install.sh -o /tmp/getdomains-install.sh
sh /tmp/getdomains-install.sh
```

The generated sing-box file contains `CHANGE_ME` placeholders. Edit it and
validate it before starting the service:

```sh
sing-box check -c /etc/sing-box/config.json
service sing-box restart
```

When `tun0` appears, the installed net-device hotplug hook adds its default
route to the `vpn` table automatically.

## Ansible role

Public defaults:

```yaml
tunnel: singbox                 # the only accepted value
country: russia-inside          # russia-inside, russia-outside, ukraine
list_domains: true
list_subnet: false
list_ip: false
list_community: false
dns_encrypt: false              # false, dnscrypt-proxy2, stubby
nano: true
```

Example:

```yaml
- hosts: openwrt
  remote_user: root
  roles:
    - itdoginfo.domain_routing_openwrt
  vars:
    tunnel: singbox
    country: russia-inside
```

The role installs a starter configuration only when
`/etc/sing-box/config.json` does not exist, so a subsequent Ansible run does not
overwrite credentials. It restarts sing-box only when the configuration passes
`sing-box check`; the placeholder configuration is left stopped for manual
editing. The inventory must contain an `[openwrt]` group.

## Diagnostics and removal

```sh
sh getdomains-check.sh --lang=en
sh getdomains-uninstall.sh
```

The uninstaller removes policy-routing artifacts and its own downloaded domain
list, but preserves other dnsmasq include files as well as the sing-box package
and configuration.

## License

GNU General Public License v3.0.
