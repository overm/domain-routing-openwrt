# Repository map

## Supported design

The project supports OpenWrt 25 and newer and one tunnel implementation:
sing-box with a `tun0` inbound. Matching IPv4 destinations receive firewall
mark `0x1`; an OpenWrt policy rule sends that mark to routing table `vpn` (99),
whose default route uses `tun0`.

There are two independent installation paths:

- the Ansible role in `defaults/`, `tasks/`, `handlers/`, and `templates/`;
- the standalone BusyBox-shell scripts in the repository root.

Both paths use OpenWrt 25's `apk` package manager. `apt` is not an OpenWrt
package manager. The project uses firewall4/nftables sets and dnsmasq nfset
files only; there is no pre-firewall4 ipset branch.

## File ownership

| Path | Responsibility |
| --- | --- |
| `defaults/main.yml` | Public list, country, DNS, editor, and `tunnel: singbox` defaults. |
| `tasks/main.yml` | Version guard, apk packages, sing-box TUN routing, nft sets, dnsmasq, and optional encrypted DNS. |
| `handlers/main.yml` | Deferred OpenWrt service restarts. |
| `templates/openwrt-getdomains.j2` | Downloads nfset/domain and optional IP lists. |
| `templates/openwrt-30-vpnroute.j2` | Replaces the table `vpn` default route with `tun0`. |
| `templates/sing-box-json.j2` | Non-destructive starter sing-box configuration. |
| `templates/config-sing-box.j2` | UCI sing-box service configuration. |
| `getdomains-install.sh` | OpenWrt 25+ interactive sing-box-only installer using apk. |
| `getdomains-check.sh` | OpenWrt 25/apk, sing-box, routing, nft set, and dnsmasq diagnostics. |
| `getdomains-uninstall.sh` | Removes domain-routing artifacts while retaining sing-box. |
| `README.md`, `README.EN.md` | Russian and English public documentation. |

## Data flow

1. `apk` installs curl, sing-box, and (when domains are enabled) dnsmasq-full.
2. `getdomains` serializes refreshes with a lock, downloads lists to temporary
   files, validates the domain list, and atomically replaces only valid data.
3. dnsmasq resolves selected domains into the `vpn_domains` nft set; firewall4
   loads the file-backed network sets.
4. firewall MARK rules apply mark `0x1` to matching LAN traffic.
5. the network policy rule looks up table `vpn`, and the hotplug script keeps
   its default route pointed at sing-box's `tun0`. The hotplug script waits for
   the interface for at most ten seconds and fails without changing the route
   when the interface never appears.

Runtime paths such as `/etc/init.d/getdomains`, `/tmp/dnsmasq.d`, `/tmp/lst`,
`/etc/sing-box/config.json`, and UCI files are target-router files and must not
be added to this repository.

## Safe changes

Never execute an installer, uninstaller, or integration playbook on a
development machine. When shared behavior changes, update the separate Ansible
and shell implementations together, update both READMEs, and run the static
checks from `AGENTS.md`.
