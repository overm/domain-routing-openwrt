# [Domain routing for OpenWrt 25+](README.EN.detailed.md#domain-routing-for-openwrt-25)

This project routes selected domains through a **sing-box** TUN interface and supports OpenWrt 25 or newer.

[More details](README.EN.detailed.md#domain-routing-for-openwrt-25)

## [OpenWrt 25 changes](README.EN.detailed.md#openwrt-25-changes)

Installation uses `apk`, firewall4/nftables and dnsmasq `nfset` lists. The standalone sing-box installer is supported; older OpenWrt releases and other tunnel types are unsupported.

[More details](README.EN.detailed.md#openwrt-25-changes)

## [Installation](README.EN.detailed.md#installation)

Run the command below **on the router**, select **Russia inside** (the default), **Russia outside** or **Ukraine**, and configure sing-box. **Reboot after installation or reinstallation.** By default, IPv4 can fall back to the direct route if the tunnel route disappears, and IPv6 is always allowed directly.

```sh
wget -O /tmp/getdomains-install.sh https://raw.githubusercontent.com/overm/domain-routing-openwrt/master/getdomains-install.sh && sh /tmp/getdomains-install.sh
```

[More details](README.EN.detailed.md#installation)

### [Additional options](README.EN.detailed.md#additional-options)

Append options after the script name; when installing from another branch or commit, set a shared file source with `GETDOMAINS_SCRIPT_BASE_URL` as shown in the detailed instructions.

[More details](README.EN.detailed.md#additional-options)

#### [`--offload medium|strict|disable`](README.EN.detailed.md#--offload-mediumstrictdisable)

The default `medium` mode accelerates eligible direct IPv4 NAT connections; network policy changes require Save & Apply followed by reboot. The `strict` mode applies supported changes with a brief wired LAN/WAN interruption and breaks IPv4 connections, while `disable` turns acceleration off. Hardware acceleration is experimental and limited to the Xiaomi AX3000T / MT7981, OpenWrt 25.12.5 profile; `--kill-switch` disables it entirely, and installation or mode changes require reboot.

[More details](README.EN.detailed.md#--offload-mediumstrictdisable)

#### [`--no-icanhazip`](README.EN.detailed.md#--no-icanhazip)

Disables automatic addition of `icanhazip.com` to the domain sets. Without this flag, `curl -4 icanhazip.com` checks the external IPv4 through the tunnel.

[More details](README.EN.detailed.md#--no-icanhazip)

#### [`--ipv6-deny`](README.EN.detailed.md#--ipv6-deny)

Rejects IPv6 connections to selected domains from LAN clients and the router so clients can try IPv4. Domains without working IPv4 become unreachable.

[More details](README.EN.detailed.md#--ipv6-deny)

#### [`--kill-switch`](README.EN.detailed.md#--kill-switch)

Denies direct IPv4 for marked traffic when the `vpn` table has no route; it does not check remote proxy health. Combine it with `--ipv6-deny` to deny both direct paths. Rerunning without these flags removes their previously created rules.

[More details](README.EN.detailed.md#--kill-switch)

#### [`--wdns`](README.EN.detailed.md#--wdns)

The `--wdns DNS_IPV4` option sets a tunnel DNS server for selected domains and creates a `wdns` DHCP tag for individual clients. A tagged client queries DNS directly, bypassing local records and domain-set learning; use the router DNS for domain routing. Reinstallation without the flag retains an existing tag.

[More details](README.EN.detailed.md#--wdns)

## [Split DNS and LuCI](README.EN.detailed.md#split-dns-and-luci)

With WDNS, selected domains use the tunnel DNS server and other queries use WAN DNS; without WDNS, all external queries use WAN DNS. Manage local records and manual **DNS → IP Sets** in LuCI, where Save & Apply triggers rule updates. Existing tracked IPv4 connections keep their routing decision across DNS and list changes.

[More details](README.EN.detailed.md#split-dns-and-luci)

## [Common LuCI scenarios](README.EN.detailed.md#common-luci-scenarios)

First assign the client a fixed IPv4 address under **Network → DHCP and DNS → Static Leases**. Then choose a scenario below and apply it with **Save & Apply**.

[More details](README.EN.detailed.md#common-luci-scenarios)

### [Send all IPv4 traffic from one client through the tunnel](README.EN.detailed.md#send-all-ipv4-traffic-from-one-client-through-the-tunnel)

Under **Network → Routing → IPv4 Rules**, add a rule for the client IPv4 address with a `/32` mask, table `vpn` and priority `70`. To deny direct IPv4 fallback when the route disappears, add an `unreachable` rule for the same source at priority `71`; configure IPv6 separately. Remove these manual rules before uninstalling the project.

[More details](README.EN.detailed.md#send-all-ipv4-traffic-from-one-client-through-the-tunnel)

### [Use a DNS server from the tunnel for one client](README.EN.detailed.md#use-a-dns-server-from-the-tunnel-for-one-client)

After installing with `--wdns DNS_IPV4`, add `wdns` under **Set Tag** in the client static lease and renew its DHCP lease. The tag advertises DNS but does not route all client traffic through the tunnel or prevent external DNS or DoH.

[More details](README.EN.detailed.md#use-a-dns-server-from-the-tunnel-for-one-client)

### [Keep all IPv4 traffic from one client strictly direct](README.EN.detailed.md#keep-all-ipv4-traffic-from-one-client-strictly-direct)

Under **Network → Firewall → Traffic Rules**, add the client IPv4 address prefixed with `!` and without `/32` to **Source address** in `mark_domains`. This scenario conflicts with sending the same client entirely through the tunnel. With `--ipv6-deny`, also exclude the client MAC address prefixed with `!` under **Source MAC address** in `block_domains6` to allow direct IPv6.

[More details](README.EN.detailed.md#keep-all-ipv4-traffic-from-one-client-strictly-direct)

## [Diagnostics](README.EN.detailed.md#diagnostics)

Run `getdomains-check --lang=en` on the router to check the tunnel, DNS, firewall and routing, including after applying LuCI settings.

[More details](README.EN.detailed.md#diagnostics)

## [Removal](README.EN.detailed.md#removal)

Run `getdomains-uninstall` to remove project rules and services while keeping the sing-box package and configuration, manual LuCI rows and static DHCP leases. If a hardware-table owner is running, removal ends with an automatic reboot, so save other pending changes first.

[More details](README.EN.detailed.md#removal)

## [sing-box configuration](README.EN.detailed.md#sing-box-configuration)

Fill in the `CHANGE_ME` values in `/etc/sing-box/config.json` and validate it with `sing-box check -c /etc/sing-box/config.json`; an existing configuration is preserved. Keep `route.auto_detect_interface: true` or an equivalent interface binding to prevent a TUN loop. If the configuration is invalid, the installer skips restarting sing-box and the initial list download.

[More details](README.EN.detailed.md#sing-box-configuration)

## [List refreshes](README.EN.detailed.md#list-refreshes)

The list refreshes daily at 04:00 through `tun0`; failures retain the last validated version, and the last source is saved for router boot. Once the tunnel is configured, refresh manually with `/etc/init.d/getdomains refresh`. Policy depends on IPs learned through router DNS: external DNS, DoH and client caches can bypass it, while shared CDN IPs can affect other domains.

[More details](README.EN.detailed.md#list-refreshes)

## [License](README.EN.detailed.md#license)

This project is distributed under the GNU General Public License v3.0.

[More details](README.EN.detailed.md#license)
