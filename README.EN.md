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

The launch command installs `curl`, which is required to download the script.
The standalone installer checks the OpenWrt major version and the presence of
`apk` and `curl` before changing the device. It installs `sing-box`,
`dnsmasq-full`, `ip-full`, and `nano`, saves the diagnostics and removal
commands in `/usr/bin`, creates the `tun0` firewall/routing configuration, and
preserves an existing `/etc/sing-box/config.json`. At the end of installation,
the script offers to open that configuration in `nano` immediately.

```sh
apk update && apk add curl
curl -fsSL https://raw.githubusercontent.com/overm/domain-routing-openwrt/master/getdomains-install.sh -o /tmp/getdomains-install.sh
sh /tmp/getdomains-install.sh
```

The generated sing-box file contains `CHANGE_ME` placeholders. Edit it and
validate it before starting the service:

```sh
sing-box check -c /etc/sing-box/config.json
service sing-box restart
```

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
getdomains_connect_timeout: 10 # seconds per connection attempt
getdomains_max_time: 120       # seconds per download attempt
getdomains_retries: 5
getdomains_ready_timeout: 30     # wait for the interface and DNS, seconds
getdomains_download_interface: tun0 # interface used to download lists
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
overwrite credentials. The inventory must contain an `[openwrt]` group.

List refreshes are transactional: data is downloaded to a temporary file,
domain syntax is checked by dnsmasq, and the active file is replaced only after
successful validation. A lock prevents overlapping cron/manual refreshes, the
previous list remains active after a network or validation failure, and
services restart only when a list actually changes. The list source URLs can
also be overridden with `domain_list_urls`, `subnet_list_url`, `ip_list_url`,
and `community_list_url`.
Downloads use `getdomains_download_interface` (`tun0` by default). Before each
download, a separate policy rule sends the router-local `curl` socket bound to
`tun0` through the `vpn` table; a default route that exists only in that table
does not select the table on its own. The script waits up to
`getdomains_ready_timeout` seconds for the
interface and source-hostname resolution, so a brief DNS interruption while
network settings are applied does not cause an immediate failure. The list
source does not need to be reachable directly over WAN. Configure and start
sing-box before the first refresh. If the installer cannot complete the initial
download, run `/etc/init.d/getdomains start` manually after the tunnel starts.
If the lists are reachable only over WAN, explicitly select another suitable
interface.

## Diagnostics and removal

```sh
getdomains-check --lang=en
getdomains-uninstall
```

The uninstaller removes policy-routing artifacts but deliberately keeps the
sing-box package and configuration. The installer downloads both commands so
they remain available locally after `/tmp` is cleared; uninstalling removes the
commands as well.

## License

GNU General Public License v3.0.
