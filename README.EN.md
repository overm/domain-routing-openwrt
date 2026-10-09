# Domain routing for OpenWrt 25+

This project routes selected domains through a **sing-box** TUN interface.
OpenWrt 25 or newer is required. Older OpenWrt releases and
WireGuard, AmneziaWG, OpenVPN, and tun2socks are no longer supported.

## OpenWrt 25 changes

OpenWrt 25 migrated its package manager from `opkg` to **`apk`**. The installer
therefore uses `apk update` and `apk add`. The project targets firewall4/nftables
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

To install from another branch or a specific commit, use one source for the
installer and all support files. Replace `BRANCH_OR_COMMIT` with the branch
name or the full commit SHA:

```sh
getdomains_ref='BRANCH_OR_COMMIT'
getdomains_source="https://raw.githubusercontent.com/overm/domain-routing-openwrt/$getdomains_ref"
wget -O /tmp/getdomains-install.sh "$getdomains_source/getdomains-install.sh" && \
GETDOMAINS_SCRIPT_BASE_URL="$getdomains_source" sh /tmp/getdomains-install.sh
```

Append additional options, such as `--wdns`, after the script name. Without
`GETDOMAINS_SCRIPT_BASE_URL`, support files are downloaded from `master`, even
when the installer itself came from another branch. Pass this variable again
when rerunning the script from `/tmp`. A full SHA pins all files to one version;
a branch can change between downloads.

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
or `--ipv6-deny` removes the rules previously created for that option. Retained
sections are updated in place, so repeating the same options preserves their
configuration order.

#### `--wdns`

The `--wdns DNS_IPV4` option creates the `wdns` DHCP tag, assigns its DNS
server, and adds a higher-priority policy rule that routes the specified IPv4
address through the `vpn` table (the tunnel). For example:

```sh
sh /tmp/getdomains-install.sh --wdns 172.16.250.2
```

On upgrades, rerunning the installer without `--wdns` retains an existing
`wdns` DHCP tag and creates or repairs its corresponding policy-routing rule.

The `wdns` tag remains an optional per-client feature. It is best used when
all of the client's traffic already uses the tunnel. Tagged clients query WDNS
directly, bypassing local dnsmasq: LuCI local records do not apply and these
queries do not populate domain sets. The tag only advertises DNS; it does not
route all client traffic. Use the router's DNS for local records and domain routing.

To send this DNS server together with a fixed IPv4 address, add the tag to the
static lease's `host` section in `/etc/config/dhcp` (or select the `wdns` tag
for the static lease in LuCI):

```text
list tag 'wdns'
```

Uninstalling removes the DNS server's policy-routing rule together with the
`wdns` DHCP tag.

## Split DNS and LuCI

With `--wdns DNS_IPV4` or a retained `wdns` tag, clients using the router's DNS
resolve listed domains through WDNS. The service generates conditional
`server=/domain/DNS_IPV4` rules for the downloaded list and manual **DNS → IP
Sets** rows containing `inet/fw4/vpn_domains` or `vpn_domains6`. Other queries
use WAN DNS in `/tmp/resolv.conf.d/resolv.conf.auto`; without WDNS all queries
use WAN DNS. Enable provider DNS on WAN if that is the desired default: manually
configured WAN DNS replaces the provider's addresses in this file.

The installer enables this resolv file and refuses existing global DNS forwards,
which defeat the provider default. Domain-specific forwards, local zones,
addresses and local host records remain under LuCI control and take priority
over generated upstream rules. A WDNS timeout does not retry listed names through
provider DNS. The WDNS address has a VPN lookup at priority 80 and a destination
`unreachable` rule at 81, preventing direct fallback even without `--kill-switch`.
Temporary priority-79 guards protect the old/new WDNS addresses during changes
and boot until the network rules and DNS configuration are ready.

Manual IP Sets rows own their domain and subtree; a more specific manual row
overrides a parent. Rows for exactly the same domain are merged into one
effective nftset rule with all their sets. UCI rows remain intact. A row with
only unrelated sets uses default DNS instead of inheriting WDNS from an automatic
parent. The compiler relies on OpenWrt 25 loading confdir before UCI nftset rules;
router tests verify this order. Sets must exist. Use ordinary DNS names (IDNs in
punycode) and the correct dnsmasq instance. The installer manages the first
instance; rows explicitly bound to another instance remain with that instance.

Local `domain`/`hostrecord` records, `address` mappings and local CNAME chains
still resolve locally. Selected addresses are seeded into the project's
nft sets because dnsmasq's upstream-answer hook does not run for local answers.
Third-party sets remain with their owning service. Dynamic DHCP names and
arbitrary additional hosts files are not enumerated for seeding; their DNS
answers still work. For guaranteed routing of those addresses, add explicit
local host records or static firewall IP entries.

Save & Apply triggers regeneration; a two-second monitor also catches changes
and deletions. LuCI and the generator are separate processes: overlapping Apply
can briefly expose the old generation. A changed snapshot is discarded and
retried; dnsmasq restarts after the complete new file is published. Run
`getdomains-check` after Apply settles to compare active rules with UCI and the
cached source. Do not edit `domains.lst` directly. Other confdir files and manual
LuCI rows survive removal. Extension-filtered confdirs are unsupported.
Restarting dnsmasq clears its DNS cache and can interrupt in-flight DNS queries
or TCP DNS sessions; clients normally retry. Existing application connections
keep their saved routing decision.

IPv4 route decisions are saved in conntrack for VPN and direct connections.
Learning/removing an IP, expiring its timeout and changing DNS rules do not
change an existing tracked connection's decision. New connections use current
set membership. Only the original direction restores the route bit; replies
are not sent into the tunnel. Marks reserve `0x1` for routing and `0x40000000`
for classification, preserving other bits. Avoid assigning these bits to another
policy service. The installer disables software/hardware flow offloading,
which bypasses these hooks. Removal restores prior DNS/offloading options if
they still have the values set by the installer. Installation, tunnel outages,
conntrack flushes and manual routing changes can still interrupt connections.

## Common LuCI scenarios

Every action below is performed in the LuCI web interface. First assign a fixed
IPv4 address to the client: open **Network → DHCP and DNS → Static Leases**, add
or edit a lease for the client's MAC address, and click **Save & Apply**. The
examples use `192.168.25.139`; replace it with the address of your client.

### Send all IPv4 traffic from one client through the tunnel

1. Open **Network → Routing → IPv4 Rules** and click **Add**.
2. Enter source network (Source) `192.168.25.139/32`. Leave the remaining
   conditions empty.
3. Select table `vpn` under **Advanced Settings**, save the rule, and click
   **Save & Apply**.

Do not edit the existing priority `100` **Routing** rule. It handles domain
routing for traffic marked `0x1`. Priority `70` makes the new client rule run
before the project's service rules at priorities `80`, `90`, and `100`.

The project's tunnel carries IPv4 only. The client's IPv6 traffic remains
direct unless IPv6 is disabled separately in the network configuration. If the
route in table `vpn` disappears, rule processing continues and the client's
IPv4 traffic may fall back to the direct route. To prevent that fallback, add
another **IPv4 Rules** entry with priority `71`, rule type **unreachable**, and
the same `192.168.25.139/32` source; leave its table empty. The project's global
kill switch matches mark `0x1` and does not protect this source-based rule by
itself.

Before running `getdomains-uninstall`, delete the manually created rule under
**Network → Routing → IPv4 Rules** and click **Save & Apply**. The uninstaller
removes only the project's own named rules; leaving manual rules in place would
block all IPv4 traffic from this client after the `vpn` table is removed.

### Use a DNS server from the tunnel for one client

This scenario works when installation is configured with
`--wdns DNS_IPV4`. That option creates the `wdns` DHCP tag and a separate rule
that routes the specified DNS server through table `vpn`, so the full-tunnel
rule from the first scenario is not required.

1. Open **Network → DHCP and DNS → Static Leases**, edit the client's lease,
   and add `wdns` under
   **Set Tag**.
2. Click **Save & Apply**, then reconnect the client or renew its DHCP lease.

DHCP option 6 advertises the DNS server to the client, but it cannot prevent a
manually configured DNS server or DNS over HTTPS.

### Keep all IPv4 traffic from one client strictly direct

This scenario conflicts with the first one: choose only one of them for a given
IP address.

1. Open **Network → Firewall → Traffic Rules** and edit the existing
   `mark_domains` rule.
2. Add the negated address `!192.168.25.139`, without a `/32` suffix, to
   **Source address**.
3. Click **Save & Apply**.

The client no longer receives mark `0x1`, even for destinations in
`vpn_domains`, so its IPv4 traffic uses the normal routing table and WAN. Do
not add the negated address to **Network → Routing**: its **Source** field only
accepts a regular CIDR subnet and does not support `!`.

IPv6 is direct by default. When `--ipv6-deny` is enabled, `block_domains6`
continues to reject selected domains for this client. To allow direct IPv6 for
it, edit `block_domains6` under **Traffic Rules** and add the client's MAC
address prefixed with `!` to **Source MAC address**, for example
`!AA:BB:CC:DD:EE:FF`.

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

The `wdns` DHCP tag definition and its policy-routing rules are removed. Static
DHCP leases and all their tags, including references to `wdns`, are preserved.
After removal, those references no longer advertise a DNS server; reinstalling
with `--wdns DNS_IPV4` restores the tag definition for the retained leases.

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
failure, and dnsmasq restarts only when effective DNS rules change. Firewall and
conntrack are not cleared. Refresh runs daily at 04:00 through `tun0`.

`vpn_domains` and, when `--ipv6-deny` is enabled, `vpn_domains6` store
individual IP addresses with a two-day timeout and a 65536-element limit.
When a new connection from LAN or the router itself uses an address already in
a set, nftables refreshes its timeout to two days. A membership test precedes
the `update`, so traffic to an unknown address cannot insert it into the set.
The `ct state new` condition avoids writing to the set for every packet; unused
addresses expire automatically. One uninterrupted connection does not extend
the timeout after its first packet: another connection to the same address must
start to refresh it.

The last validated source is stored in `/etc/getdomains/domains.source` and
compiled before dnsmasq starts at boot. Only a changed source writes flash;
temporary downloads stay outside confdir. Learned IPs remain RAM-only. After
reboot they return after queries through local dnsmasq. A client-cached IP may
not be covered by `--kill-switch` or `--ipv6-deny`. A shared CDN creates the
opposite risk: one address can serve several names, so adding it because of a
listed domain also affects an unlisted domain. When the `vpn` route is absent,
the kill switch blocks such a shared IPv4 address; `--ipv6-deny` similarly
rejects a shared IPv6 address. Timeout refresh operates on IP addresses rather
than names: new connections to a shared CDN address can extend its lifetime
even when they belong to another domain. A popular shared address can therefore
remain in a set for longer than two days; with `--ipv6-deny`, repeated rejected
connection attempts also refresh it.

Removing a domain stops future DNS selection but leaves learned IPs until timeout;
they can be shared with other names and new traffic can extend their lifetime.
DNS TTL and nft timeout are independent; adding an existing IP through dnsmasq
does not necessarily renew its expiry. A new connection using an old cached IP
after expiry can bypass the domain policy. Pinning protects existing tracked
connections; it does not turn domain routing into strict name-based access control.
Static local records are reseeded hourly with alternating 172799/172800-second
timeouts to renew their expiry.

Rules cover addresses learned through local dnsmasq and seeded local records.
External DNS, DNS over HTTPS, and direct IP connections do not populate new set
elements and can bypass the domain policy. Connecting to an address already in
a set refreshes its timeout.

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
download, run `/etc/init.d/getdomains refresh` manually after the tunnel starts.

## License

GNU General Public License v3.0.
