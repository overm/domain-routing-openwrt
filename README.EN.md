# Domain routing for OpenWrt 25+

This project routes selected domains through a **sing-box** TUN interface.
OpenWrt 25 or newer is required. Older OpenWrt releases and
WireGuard, AmneziaWG, OpenVPN, and tun2socks are no longer supported.

## OpenWrt 25 changes

OpenWrt 25 migrated its package manager from `opkg` to **`apk`**. It did not
migrate to Debian/Ubuntu's `apt`. The installer therefore uses `apk update` and
`apk add`. The project targets firewall4/nftables
only and uses dnsmasq `nfset` lists; all legacy ipset compatibility code has
been removed.

The launch command downloads the script with BusyBox's bundled `wget`. The
standalone installer checks the OpenWrt major version and the presence of `apk`
before changing the device. It installs `curl`, `sing-box`, `dnsmasq-full`,
`ip-full`, and `nano`, creates the `tun0` firewall/routing configuration, saves
the diagnostics and removal commands in `/usr/bin`, and preserves an existing
`/etc/sing-box/config.json`. At the end of installation, the script offers to
open that configuration in `nano`, validates it, and, if it is valid, restarts
sing-box after applying the network configuration.

Only the standalone installer is supported; the Ansible role has been removed.

## Installation

```sh
wget -O /tmp/getdomains-install.sh https://raw.githubusercontent.com/overm/domain-routing-openwrt/master/getdomains-install.sh && sh /tmp/getdomains-install.sh
```

During installation, select one domain list: **Russia inside** (the default),
**Russia outside**, or **Ukraine**.

Without additional flags, IPv4 traffic for selected domains uses the tunnel
but may continue through the direct route if the route through `tun0`
disappears. IPv6 is not routed into the tunnel and is also allowed directly.
This is the fail-open mode.

### Additional options

#### `--no-icanhazip`

By default, the installer adds `icanhazip.com` to the `vpn_domains` set so an
external IPv4 check uses the tunnel. The `mark_local_domains` rule marks
matching router-local traffic in `mangle_output`; use `curl -4 icanhazip.com`
for an unambiguous check. Without `-4`, curl may select IPv6, which is allowed
directly by default. With `--ipv6-deny`, the domain is also added to
`vpn_domains6`. This mapping is stored as the dedicated
`vpn_icanhazip` section in `/etc/config/dhcp` and appears under **DNS → IP Sets**
in LuCI; the installer does not append it to the downloaded
`/tmp/dnsmasq.d/domains.lst` file. To deploy without that domain, pass
`--no-icanhazip`:

```sh
sh /tmp/getdomains-install.sh --no-icanhazip
```

#### `--ipv6-deny`

By default, AAAA answers for selected domains are allowed directly over IPv6.
The `--ipv6-deny` option creates a `vpn_domains6` set; dnsmasq puts AAAA answers
in it and the firewall rejects new matching connections from LAN clients and
the router itself. `REJECT` returns an error immediately, so an IPv4-capable
client can normally try an A address quickly. A domain without working IPv4
will remain unreachable:

```sh
sh /tmp/getdomains-install.sh --ipv6-deny
```

#### `--kill-switch`

By default, if the `vpn` table has no route, policy-rule processing continues
and marked IPv4 traffic can use the main route. The `--kill-switch` option adds
a following `unreachable` rule for mark `0x1`: priority 100 first looks up the
`vpn` table, then priority 110 denies direct IPv4 if no route was found.

```sh
sh /tmp/getdomains-install.sh --kill-switch
```

This is not a health check. If `tun0` and its route still exist while the remote
proxy is unresponsive, traffic may stall inside the tunnel; there is no
automatic switch or block based on proxy health. `--kill-switch` alone does not
deny IPv6. To deny both direct paths, combine the options:

```sh
sh /tmp/getdomains-install.sh --kill-switch --ipv6-deny
```

| Options | IPv4 when the `vpn` route is absent | Selected-domain IPv6 |
| --- | --- | --- |
| no flags | direct | direct |
| `--kill-switch` | denied | direct |
| `--ipv6-deny` | direct | denied |
| both flags | denied | denied |

Rerunning the installer applies the requested mode; omitting `--kill-switch`
or `--ipv6-deny` removes the rules previously created for that option.

#### `--wdns`

The `--wdns DNS_IPV4` option creates the `wdns` DHCP tag and assigns a DNS
server reachable through the tunnel to that tag. For example:

```sh
sh /tmp/getdomains-install.sh --wdns 172.16.250.2
```

To send this DNS server together with a fixed IPv4 address, add the tag to the
static lease's `host` section in `/etc/config/dhcp` (or select the `wdns` tag
for the static lease in LuCI):

```text
list tag 'wdns'
```

## Diagnostics

```sh
getdomains-check --lang=en
```

## Removal

```sh
getdomains-uninstall
```

The uninstaller removes policy-routing artifacts but deliberately keeps the
sing-box package and configuration. The installer downloads both commands so
they remain available locally after `/tmp` is cleared; uninstalling removes the
commands as well.

## sing-box configuration

If `/etc/sing-box/config.json` does not exist, the installer creates a
Shadowsocks template containing `CHANGE_ME` parameters. Fill them in during
installation: if the configuration is invalid, sing-box will not be restarted
and the initial list download will be skipped. An existing configuration is not
overwritten.

You can edit and validate the configuration later with these commands:

```sh
nano /etc/sing-box/config.json
sing-box check -c /etc/sing-box/config.json
service sing-box restart
```

The following is a separate basic example that uses the router's primary
connection as its outbound. It is not the template created by the installer.
You can use it as a starting point and adapt the `outbounds` block.

```json
{
  "log": {
    "level": "warning"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "tun0",
      "address": [
        "172.16.250.1/30"
      ],
      "auto_route": false,
      "stack": "system"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct-out"
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "final": "direct-out"
  }
}
```

Keep `route.auto_detect_interface: true` in a TUN configuration, or configure
the equivalent global `route.default_interface`. Using
`outbound.bind_interface` is safe only when every outbound that can carry TUN
traffic is bound; the diagnostic conservatively requires it on every outbound.
Without one of these mechanisms, traffic can loop back into `tun0`. Verify this
setting in custom configurations as well.

## List refreshes

List refreshes are transactional: data is downloaded to a temporary file, its
size, expected format, and dnsmasq syntax are validated, and the active file is
replaced only after successful validation. With `--ipv6-deny`, processing adds
the `vpn_domains6` set to every entry. A lock prevents overlapping cron/manual
refreshes, the previous list remains active after a network or validation
failure, and services restart only when a list actually changes. The refresh
runs daily at 04:00 and downloads the list through `tun0`.

Domain addresses deliberately live only in memory: the active file is
`/tmp/dnsmasq.d/domains.lst`, while IPv4/IPv6 addresses are nft set elements.
After a reboot, they return only after the list is downloaded and names are
queried through the local dnsmasq. Until then, an address cached by a client may
not be covered by `--kill-switch` or `--ipv6-deny`. A shared CDN creates the
opposite risk: one address can serve several names, so adding it because of a
listed domain also affects an unlisted domain. When the `vpn` route is absent,
the kill switch blocks such a shared IPv4 address; `--ipv6-deny` similarly
rejects a shared IPv6 address.

Rules cover only addresses learned when the local dnsmasq resolves a name.
External DNS, DNS over HTTPS, and direct IP connections do not populate the
sets and can bypass the domain policy.

The device is registered with netifd as the unmanaged logical interface
`singbox_tun`. A separate policy rule sends the router-local `curl` socket bound
to `tun0` through the `vpn` table via `singbox_tun`: UCI's `out` field refers to
an OpenWrt logical interface, not directly to a Linux device name. The TUN zone
rejects unsolicited router input and new forwarding from the
zone. The sing-box system TUN stack creates a new TCP flow for a client
connection, which conntrack does not yet classify as `ESTABLISHED`. A narrow
rule accepts it only from the TUN peer `172.16.250.2` to `172.16.250.1` and the
standard local ephemeral-port range `32768-60999`. It does not expose the SSH,
LuCI, or DNS ports. The script waits up to 30 seconds for the
interface and source-hostname resolution, so a brief DNS interruption while
network settings are applied does not cause an immediate failure. The list
source must be reachable through the configured tunnel. Configure and start
sing-box before the first refresh. If the installer cannot complete the initial
download, run `/etc/init.d/getdomains start` manually after the tunnel starts.

## License

GNU General Public License v3.0.
