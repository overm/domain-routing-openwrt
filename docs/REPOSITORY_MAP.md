# Repository map

## Supported design

The project supports OpenWrt 24.10 and newer and routes selected IPv4
destinations through a sing-box `tun0` interface. sing-box is the only tunnel.
Both entry points implement the same model:

- the Ansible role is configured in `defaults/main.yml` and `tasks/main.yml`;
- `getdomains-install.sh` is the standalone, destructive OpenWrt installer.

OpenWrt 24.10 uses firewall4/nftables and OPKG. Newer OpenWrt builds may provide
APK, so package operations detect the installed manager. There is no APT path
and no pre-nftables/ipset compatibility path.

## File ownership

| Path | Responsibility |
| --- | --- |
| `defaults/main.yml` | Public list, DNS, country, editor, and sing-box defaults. |
| `tasks/main.yml` | Version validation, package installation, sing-box routing, nft sets, and DNS setup. |
| `handlers/main.yml` | Deferred OpenWrt service restarts. |
| `templates/openwrt-getdomains.j2` | Downloads nfset/domain and IP lists. |
| `templates/openwrt-30-vpnroute.j2` | Maintains the table `vpn` default route over `tun0`. |
| `templates/sing-box-json.j2` | Starter sing-box TUN configuration. |
| `templates/config-sing-box.j2` | sing-box UCI service configuration. |
| `getdomains-install.sh` | Standalone OpenWrt 24.10+ sing-box installer. |
| `getdomains-check.sh` | OpenWrt 24.10+ sing-box and routing diagnostics. |
| `getdomains-uninstall.sh` | Removes routing/list artifacts, retaining sing-box. |

## Data flow

The getdomains service downloads enabled lists into `/tmp`, dnsmasq resolves
domains into nftables-backed firewall sets, firewall rules mark matching LAN
packets with `0x1`, and the UCI network rule selects routing table `99 vpn`.
The hotplug script keeps that table's default route on `tun0`.

Runtime paths such as `/etc/init.d/getdomains`, `/tmp/dnsmasq.d`,
`/etc/hotplug.d/iface/30-vpnroute`, and `/etc/config/*` belong to the router and
must not be added to this repository.
