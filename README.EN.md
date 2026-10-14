# [Domain routing for OpenWrt 25+](README.EN.detailed.md#domain-routing-for-openwrt-25)

This project routes selected domains through a **sing-box** TUN interface and supports OpenWrt 25 or newer.

## [OpenWrt 25 changes](README.EN.detailed.md#openwrt-25-changes)

Installation uses `apk`, firewall4/nftables and dnsmasq `nfset` lists. The standalone sing-box installer is supported; older OpenWrt releases and other tunnel types are unsupported.

[More details](README.EN.detailed.md#openwrt-25-changes)

## [Installation](README.EN.detailed.md#installation)

Connect to the router over SSH and run the command below **on the router**, select **Russia inside** (the default), **Russia outside** or **Ukraine**, and configure sing-box. **Reboot after installation or reinstallation.** By default, IPv4 can fall back to the direct route if the tunnel route disappears, and IPv6 is always allowed directly.

```sh
wget -O /tmp/getdomains-install.sh https://raw.githubusercontent.com/overm/domain-routing-openwrt/master/getdomains-install.sh && sh /tmp/getdomains-install.sh
```

[More details](README.EN.detailed.md#installation)

### [Additional options](README.EN.detailed.md#additional-options)

Append options after the script name.

[More details](README.EN.detailed.md#additional-options)

#### [`--offload medium|strict|disable`](README.EN.detailed.md#--offload-mediumstrictdisable)

The default `medium` mode accelerates eligible direct IPv4 NAT connections; network policy changes require Save & Apply followed by reboot. The `strict` mode applies supported changes with a brief wired LAN/WAN interruption and breaks IPv4 connections, while `disable` turns acceleration off. Hardware acceleration is experimental and is not guaranteed on all routers; `--kill-switch` disables it entirely, and mode changes require reinstallation and reboot.

[More details](README.EN.detailed.md#--offload-mediumstrictdisable)

#### [`--no-icanhazip`](README.EN.detailed.md#--no-icanhazip)

By default, `icanhazip.com` is also added so you can check the tunnel with `curl -4 icanhazip.com`. This option disables its automatic addition to the domain sets.

[More details](README.EN.detailed.md#--no-icanhazip)

#### [`--ipv6-deny`](README.EN.detailed.md#--ipv6-deny)

Rejects IPv6 connections to selected domains from LAN clients and the router so clients can try IPv4. Domains without working IPv4 become unreachable.

[More details](README.EN.detailed.md#--ipv6-deny)

#### [`--kill-switch`](README.EN.detailed.md#--kill-switch)

Denies direct connections for listed domains when tunnel problems occur. Combine it with `--ipv6-deny` to also deny IPv6. Reinstallation without these flags removes their previously created rules.

[More details](README.EN.detailed.md#--kill-switch)

#### [`--wdns`](README.EN.detailed.md#--wdns)

The `--wdns DNS_IPV4` option sets a tunnel DNS server and creates a `wdns` DHCP tag that can be assigned to individual clients. A tagged client queries DNS directly, so its queries bypass domain-routing logic and do not populate the domain sets. These clients are intended to use full IPv4 routing through the tunnel: [Send all IPv4 traffic from one client through the tunnel](README.EN.md#send-all-ipv4-traffic-from-one-client-through-the-tunnel).

[More details](README.EN.detailed.md#--wdns)

## [Split DNS and LuCI](README.EN.detailed.md#split-dns-and-luci)

For clients using the router DNS, WDNS sends queries for listed domains to the specified tunnel DNS server and other queries to WAN DNS; without WDNS, all external queries use WAN DNS. Manage local records and manual **DNS → IP Sets** in LuCI.

[More details](README.EN.detailed.md#split-dns-and-luci)

## [Custom domain sets](README.EN.detailed.md#custom-domain-sets)

Add your own domains under **DNS → IP Sets**, selecting `vpn_domains` and, with `--ipv6-deny`, also `vpn_domains6`. By default, `icanhazip.com` is already listed unless installation used `--no-icanhazip`.

## [Common LuCI scenarios](README.EN.detailed.md#common-luci-scenarios)

First assign the client a fixed IPv4 address under **Network → DHCP and DNS → Static Leases**. Then choose a scenario below or a compatible combination of scenarios.

### [Send all IPv4 traffic from one client through the tunnel](README.EN.detailed.md#send-all-ipv4-traffic-from-one-client-through-the-tunnel)

Under **Network → Routing → IPv4 Rules**, add a rule for the client IPv4 address with a `/32` mask, table `vpn` and priority `70`. To deny direct IPv4 fallback (kill switch) when the route disappears, add an `unreachable` rule for the same source at priority `71`; configure IPv6 separately. Remove these manual rules before uninstalling the project.

[More details](README.EN.detailed.md#send-all-ipv4-traffic-from-one-client-through-the-tunnel)

### [Use a DNS server from the tunnel for one client](README.EN.detailed.md#use-a-dns-server-from-the-tunnel-for-one-client)

After installing with `--wdns DNS_IPV4`, add `wdns` under **Set Tag** in the client static lease and renew its DHCP lease. The tag advertises DNS but does not route all client traffic through the tunnel or prevent external DNS or DoH.

[More details](README.EN.detailed.md#use-a-dns-server-from-the-tunnel-for-one-client)

### [Keep all IPv4 traffic from one client strictly direct](README.EN.detailed.md#keep-all-ipv4-traffic-from-one-client-strictly-direct)

Under **Network → Firewall → Traffic Rules**, add the client IPv4 address prefixed with `!` and without `/32` to **Source address** in `mark_domains`. This scenario conflicts with sending the same client entirely through the tunnel. With `--ipv6-deny`, also exclude the client MAC address prefixed with `!` under **Source MAC address** in `block_domains6` to allow direct IPv6.

[More details](README.EN.detailed.md#keep-all-ipv4-traffic-from-one-client-strictly-direct)

## [Diagnostics](README.EN.detailed.md#diagnostics)

Run the command below on the router to check the tunnel, DNS, firewall and routing, including after applying LuCI settings.

[More details](README.EN.detailed.md#diagnostics)

```sh
getdomains-check --lang=en
```

## [Removal](README.EN.detailed.md#removal)

The command removes project rules and services while keeping the sing-box package and configuration, manual LuCI rows and static DHCP leases. If a hardware-table owner is running, removal ends with an automatic reboot, so save other pending changes first.

[More details](README.EN.detailed.md#removal)

```sh
getdomains-uninstall
```

## [sing-box configuration](README.EN.detailed.md#sing-box-configuration)

Fill in the `CHANGE_ME` values in `/etc/sing-box/config.json` and validate it with `sing-box check -c /etc/sing-box/config.json`; an existing configuration is preserved. Keep `route.auto_detect_interface: true` or an equivalent interface binding to prevent a TUN loop. If the configuration is invalid, the installer skips restarting sing-box and the initial list download.

[More details](README.EN.detailed.md#sing-box-configuration)

## [List refreshes](README.EN.detailed.md#list-refreshes)

The list refreshes daily at 04:00 through `tun0`; failures retain the last validated version, and the last source is saved for router boot. Once the tunnel is configured, refresh manually with the command below. Policy relies on IP addresses learned through the router DNS: external DNS, DoH and client caches can bypass it, while shared CDN IP addresses can affect domains outside the list.

[More details](README.EN.detailed.md#list-refreshes)

```sh
/etc/init.d/getdomains refresh
```

## [License](README.EN.detailed.md#license)

This project is distributed under the GNU General Public License v3.0.
