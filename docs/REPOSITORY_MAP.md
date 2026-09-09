# Repository map

## Supported design

The project supports OpenWrt 25 and newer and one tunnel implementation:
sing-box with a `tun0` inbound. Matching IPv4 destinations receive firewall
mark `0x1`; an OpenWrt policy rule sends that mark to routing table `vpn` (99),
whose default route uses `tun0`.

The default behavior is fail-open: if the `vpn` table has no matching route,
IPv4 policy processing continues to the main table, and IPv6 remains direct.
The optional `--kill-switch` adds a later `unreachable` rule for marked IPv4;
the independent `--ipv6-deny` mode rejects IPv6 addresses learned for selected
domains. Neither option performs tunnel or proxy health checks.

Installation and maintenance use the standalone BusyBox-shell scripts in the
repository root. The installer uses OpenWrt 25's `apk` package manager. `apt` is
not an OpenWrt package manager. The project uses firewall4/nftables sets and
dnsmasq nfset files only; there is no pre-firewall4 ipset branch.

## File ownership

| Path | Responsibility |
| --- | --- |
| `getdomains-install.sh` | OpenWrt 25+ interactive sing-box-only installer using apk; installs the diagnostic and uninstall commands into `/usr/bin`. |
| `getdomains-check.sh` | OpenWrt 25/apk, sing-box TUN loop protection, netifd, routing, firewall, nft set, and dnsmasq diagnostics. |
| `getdomains-uninstall.sh` | Removes domain-routing artifacts while retaining sing-box. |
| `README.md`, `README.EN.md` | Russian and English public documentation. |
| `tests/router-install-matrix.sh` | Destructive OpenWrt integration matrix for installer modes, transitions, routing, dnsmasq, and nftables behavior. |
| `tests/results/` | Reviewed reports and per-case summaries from named OpenWrt testbeds; raw device logs and credentials are never committed. |

## Data flow

1. The launch command downloads the installer with BusyBox `wget`; the installer
   uses `apk` to install curl, sing-box, dnsmasq-full, and ip-full. The full `ip`
   implementation is required for the `oif tun0` policy rule used by router-local
   downloads.
2. `getdomains` serializes refreshes with a lock, downloads the domain list to a
   temporary file, enforces its size and expected format, validates it, and
   atomically replaces only valid data. In `--ipv6-deny` mode it converts each
   entry to populate both the IPv4 and IPv6 sets.
3. dnsmasq resolves selected domains into the `vpn_domains` nft set and, with
   `--ipv6-deny`, AAAA answers into the `vpn_domains6` nft set. The optional
   `icanhazip.com` mapping is stored as the named `dhcp.vpn_icanhazip` UCI
   section instead of being appended to the downloaded runtime list, so LuCI
   can display it. Both sets contain individual addresses, have a two-day
   timeout and an explicit 65536-element limit.
4. The raw `tun0` device is registered as the unmanaged netifd interface
   `singbox_tun`. The firewall keeps unsolicited TUN input and new forwarding
   rejected. The sing-box system TUN stack creates new TCP client flows that are
   not yet tracked as established, so a narrow input rule accepts only traffic
   from the TUN peer `172.16.250.2` to the local TUN address and the standard
   ephemeral-port range `32768-60999`.
5. nftables include fragments in `mangle_prerouting` and `mangle_output`
   refresh the two-day timeout when a new LAN or router-local connection uses
   an address already present in a domain set. The membership test before each
   `update` prevents unrelated destinations from being inserted. Firewall MARK
   rules then apply mark `0x1` to matching LAN traffic. A separate
   `mangle_output` rule applies the same mark to router-local IPv4 traffic whose
   destination is in `vpn_domains`.
6. The network policy rules send marked LAN and router-local packets, as well as
   router-local downloads bound to `tun0`, to table `vpn`. The output-interface
   rule refers to the logical `singbox_tun` interface so netifd can resolve it
   to the `tun0` device,
   and the hotplug script keeps the table's default route pointed at `tun0`.
   With `--kill-switch`, a second marked rule returns `unreachable` only if the
   preceding `vpn` lookup found no route. The hotplug script waits for
   the interface for at most ten seconds and fails without changing the route
   when the interface never appears.
7. With `--ipv6-deny`, firewall rules reject matching IPv6 traffic from LAN and
   from the router itself. Without it, IPv6 remains direct.
8. When configured, the optional `wdns` dnsmasq tag advertises its
   tunnel-reachable IPv4 DNS server (DHCP option 6) to static leases carrying
   that tag.

Runtime paths such as `/etc/init.d/getdomains`, `/etc/getdomains`,
`/tmp/dnsmasq.d`, `/tmp/lst`, `/etc/sing-box/config.json`, and UCI files are
target-router files and must not be added to this repository.

The runtime domain file and nft set elements are RAM-only. Client-cached
addresses can bypass the policy after reboot until dnsmasq sees the query;
shared CDN addresses can apply policy to unrelated domain names. The mode's UCI
rules are persistent, but learned domain addresses are not. Since timeout
refresh operates on IP traffic rather than DNS names, traffic to an unrelated
name on a shared CDN address can keep that address in the set indefinitely.

## Safe changes

Never execute the installer or uninstaller on a development machine. When
behavior changes, update both READMEs and run the static checks from `AGENTS.md`.
