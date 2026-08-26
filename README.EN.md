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
`ip-full`, and `nano`, saves the diagnostics and removal
commands in `/usr/bin`, creates the `tun0` firewall/routing configuration, and
preserves an existing `/etc/sing-box/config.json`. At the end of installation,
the script offers to open that configuration in `nano` immediately, validates
it, and restarts sing-box after applying the network configuration.

```sh
wget -O /tmp/getdomains-install.sh https://raw.githubusercontent.com/overm/domain-routing-openwrt/master/getdomains-install.sh && sh /tmp/getdomains-install.sh
```

By default, the installer adds `icanhazip.com` to the `vpn_domains` set so an
external-IP check uses the tunnel. The `mark_local_domains` rule marks matching
router-local traffic in `mangle_output`, so `curl icanhazip.com` and
`curl --interface tun0 icanhazip.com` use the same tunnel route. This mapping is
stored as the dedicated
`vpn_icanhazip` section in `/etc/config/dhcp` and appears under **DNS → IP Sets**
in LuCI; the installer does not append it to the downloaded
`/tmp/dnsmasq.d/domains.lst` file. To deploy without that domain, pass
`--no-icanhazip`:

```sh
sh /tmp/getdomains-install.sh --no-icanhazip
```

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

The generated sing-box file contains `CHANGE_ME` placeholders. Edit it and
validate it before starting the service:

```sh
sing-box check -c /etc/sing-box/config.json
service sing-box restart
```

Keep `route.auto_detect_interface: true` in a TUN configuration, or configure
the equivalent global `route.default_interface`. Using
`outbound.bind_interface` is safe only when every outbound that can carry TUN
traffic is bound; the diagnostic conservatively requires it on every outbound.
Without that binding, traffic can loop back into `tun0`. The installer preserves
an existing JSON file, so verify this setting in custom configurations as well.

## List refreshes

List refreshes are transactional: data is downloaded to a temporary file,
domain syntax is checked by dnsmasq, and the active file is replaced only after
successful validation. A lock prevents overlapping cron/manual refreshes, the
previous list remains active after a network or validation failure, and
services restart only when a list actually changes. The refresh runs daily at
04:00 and downloads the list through `tun0`.

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
