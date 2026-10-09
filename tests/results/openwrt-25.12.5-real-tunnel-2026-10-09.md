# Real tunnel and DNS: OpenWrt 25.12.5

Date: 2026-10-09. Branch: `codex-split-dns-sticky-routing`.
Tested production revision: `0cd59fe9c9e66f473d431445654d7bf44484a71b`.

The user supplied a working sing-box configuration with real VLESS transports
and a real WDNS resolver. Installed helpers were verified byte for byte against
the source revision, before and after tests. The real sing-box configuration
was never replaced; its SHA-256 remained unchanged throughout the installer
matrix and the public-source installation. Private addresses, credentials,
transport endpoints and packet captures are excluded from this report.

## Environment

| Component | Version |
| --- | --- |
| Router | Xiaomi Mi Router AX3000T, MediaTek Filogic |
| OpenWrt | 25.12.5, r33051-f5dae5ece4 |
| Kernel | 6.12.94 |
| nftables | 1.1.6 |
| dnsmasq-full | 2.93 |
| sing-box | 1.13.21 |

## Completed runs

| Run | Checks | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: | ---: |
| Full installer matrix, 33 cases | 661 | 640 | 0 | 21 |
| DNS and live TCP/LAN lifecycle | 31 | 31 | 0 | 0 |
| Real WDNS/provider and external HTTPS, corrected fixture | 36 | 36 | 0 | 0 |
| Actual LuCI add/edit/delete, three workflows | 10 | 10 | 0 | 0 |
| Actual reboot verification | 11 | 11 | 0 | 0 |
| Post-reboot Internet and final restoration checks | 13 | 13 | 0 | 0 |
| Host-safe Python suite | 50 | 50 | 0 | 0 |

All 16 option combinations, three list choices, invalid CLI/country arguments,
repeat installation, mode transitions, tag preservation and uninstall behavior
passed. WDNS tests used the user's real resolver. The 21 skips are unused
domain-download recovery branches following successful initial downloads.
No package-download failure occurred during this matrix.

The lifecycle suite passed expiry renewal, real TCP conntrack and packet-mark
persistence for router/LAN flows, source replacement during established flows,
manual DNS updates/deletions, equal-name native set union, full-set DNS answers,
other mark-bit preservation and reply-direction handling. Its controlled
namespace peers distinguish routing decisions; these checks are separate from
the external HTTPS verification.

## Real traffic verification

A temporary LAN client connected to `br-lan` through a veth pair. HTTPS requests
used normal certificate validation. Captures on `tun0` and WAN verified:

- uncached subdomain queries for a selected domain went to the configured WDNS
  resolver inside `tun0`, with no matching query on WAN;
- uncached queries for an unlisted domain went to the provider's resolver on
  WAN, with no matching query inside `tun0`;
- selected HTTPS destination packets appeared inside `tun0`, while an unlisted
  control destination appeared on WAN; the opposite captures lacked those
  destination packets;
- both router-local and simulated LAN HTTPS requests succeeded, and LAN
  conntrack saved the expected direct/VPN mark;
- adding a real external domain through the same UCI IP Sets configuration used
  by LuCI created conditional WDNS forwarding, learned its addresses in the
  VPN set, and moved new HTTPS connections to `tun0`;
- local hostname and CNAME overrides kept their configured address and seeded
  the routing set when the local name was included in IP Sets;
- deleting the manual row removed generated forwarding and restored DHCP.

The selected and direct IP-check endpoints returned the same public IPv4 on
this setup. This comparison was therefore not used as evidence of different
routes. Interface captures and conntrack marks provided that evidence instead;
the reason for the shared public address was not established.

A complete installation fetched the installer and all four helpers from the
public raw GitHub URL pinned to the tested commit, using
`GETDOMAINS_SCRIPT_BASE_URL`. It completed successfully without a 404 or mixed
helper versions and preserved the real sing-box configuration.

## Fixture and UI observations

The first external-traffic fixture passed 35 of 36 checks. It incorrectly
expected a local hostname outside every routing list to seed the VPN set.
Adding that hostname to the fixture's manual IP Sets row corrected the test;
the full 36-check rerun passed without production changes. The initial failure
and corrected rerun are retained in the private evidence.

Actual LuCI forms were used to add a manual IP Sets domain and matching local
hostname, change its configured IP, then delete both with Save & Apply. DNS
answers and set membership matched both configured IPs. The previously learned
IP remained after editing, consistent with timeout-based retention. Deletion
removed the UCI entries and generated rule.

One rapid Delete/Save & Apply sequence returned the LuCI RPC error
`Resource not found`. Refreshing the form and applying its two pending deletions
succeeded. The timing suggests overlapping form operations; the root cause was
not established. The table records the successful final verification; this
initial UI error remains documented here.

## Reboot and final restoration

The changed kernel boot ID confirmed an actual reboot. The persistent source,
compiled DNS and real sing-box configuration retained their hashes. A selected
static local address was already seeded before its first DNS query. The local
hostname and CNAME resolved correctly, the synchronization service resumed,
temporary WDNS guards were absent, and full diagnostics passed.

After reboot and restoration, fresh captured queries again reached WDNS over
`tun0` and the provider over WAN. Both selected and direct HTTPS requests
succeeded with certificate validation. All 13 final checks passed, including
`fw4 check`, runtime comparison, full diagnostics, unchanged sing-box config,
exact original network/firewall/DHCP/source hashes, and the original list choice.

The router retains the user's initial mode: WDNS configured, IPv4 domain
routing, the `icanhazip.com` mapping, no kill-switch and no IPv6 denial.
Both flow-offloading options remain zero. Temporary namespaces, veth interfaces
and test DNS rows were removed. Private backups and evidence remain on the
router under `/root/getdomains-real-test-backup-20261009`.

There was no IPv6 Internet default route on this testbed. Public IPv6 Internet
connectivity and throughput/offloading were not tested; IPv6 set population,
denial rules and timeout renewal were covered by the matrix.

The [case summary](openwrt-25.12.5-real-tunnel-2026-10-09-cases.tsv) records the
33 matrix cases and the separate runs, including the initial fixture failure
and recovered LuCI save error. Matrix case output survived in the persistent
log; its detailed per-assertion `/tmp` logs did not survive reboot. Lifecycle,
external-traffic, public-installation, reboot and final-check logs and captures
were retained privately. No production change was needed for this test run.
