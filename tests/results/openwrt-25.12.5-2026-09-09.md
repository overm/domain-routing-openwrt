# Installer matrix result: OpenWrt 25.12.5

Date: 2026-09-09

Source revision: `origin/master` at `3b0abd8`, including the `update @set`
timeout refresh implementation merged by pull request 26.

## Testbed

| Component | Version |
| --- | --- |
| OpenWrt | 25.12.5 |
| Kernel | 6.12.94 |
| nftables | 1.1.6 |
| dnsmasq | 2.93 |
| sing-box | 1.13.21 |

The router started with a working default domain-routing installation and a
working sing-box tunnel. `kmod-veth` was installed only to generate real LAN
packets from an isolated network namespace. The testbed had no public IPv6
default route, so public Internet reachability over IPv6 was not claimed or
tested. IPv6 nft set population, local and LAN timeout refreshes, reject rules,
and mode transitions were exercised locally.

## Result

- Assertions: 600
- Passed: 578
- Failed: 1
- Skipped: 21
- Cases: 31 total, 30 passed and 1 failed

The 21 skips are the recovery branch for an initial domain-list download. Every
installation downloaded a valid list on its first attempt, so no retry was
needed.

All 16 combinations of `--no-icanhazip`, `--ipv6-deny`, `--kill-switch`, and
`--wdns` passed. The suite also passed:

- default fail-open routing after temporarily removing the VPN route;
- kill-switch `unreachable` routing after removing the VPN route;
- dnsmasq population of IPv4 and IPv6 nft sets;
- router-local and simulated-LAN `update @set` timeout refreshes from five
  seconds to two days;
- all three domain-list choices;
- repeated installation with identical options;
- reordered and duplicated options, including last-value-wins for `--wdns`;
- transition from all optional modes back to defaults;
- installer help and representative invalid `--wdns` arguments;
- the complete `getdomains-check --lang=en` diagnostic in every matrix mode.

## Reproduced defect

`invalid-country-selection` is the only failed case. Selection `9` exits with
status 1 as expected, but the installer asks for the domain-list selection only
after it has committed network, firewall, DHCP, and sing-box UCI sections.
Therefore the rejected selection leaves a partial persistent installation. The
test compares a normalized UCI fingerprint immediately before and after the
invalid invocation and observes a change.

This is not a test-fixture failure: the final cleanup and default reinstallation
succeeded afterward. A future installer fix should validate the interactive
selection before its first persistent write; the existing assertion will then
turn green.

## Final state

The suite restored the default mode. `getdomains-check --lang=en` reported all
checks as OK, including the VPN route, direct IPv4/IPv6 fallback, dnsmasq,
firewall, and timeout refresh rules. The SHA-256 of
`/etc/sing-box/config.json` matched its value before the suite.

See `openwrt-25.12.5-2026-09-09-cases.tsv` for every case result. Raw installer
and device logs were reviewed but are not committed because they can contain
network-specific information.
