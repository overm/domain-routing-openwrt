# Split DNS and connection routing: OpenWrt 25.12.5

Date: 2026-10-09. Branch: `codex/split-dns-sticky-routing`.

The tested production files match commit `3e3f25d` byte for byte, verified by
SHA-256 on the router. The full matrix ran at `603123d`; its production files
are identical to `3e3f25d`. Later commits improved the test fixtures, added
targeted reruns and documented repeat-install ordering.

## Environment and scope

| Component | Version |
| --- | --- |
| Router | Xiaomi Mi Router AX3000T, MediaTek Filogic |
| OpenWrt | 25.12.5, r33051-f5dae5ece4 |
| Kernel | 6.12.94 |
| nftables | 1.1.6 |
| dnsmasq-full | 2.93 |
| sing-box | 1.13.21 |

The supplied router initially had no configured sing-box proxy. Testing used a
controlled `tun0` inbound with direct WAN transport and a DNS interception rule
inside sing-box for the test WDNS destination. This exercised actual kernel
routing through TUN, conditional DNS and no-fallback policy rules. It does not
prove a remote proxy transport, availability of an external WDNS through that
proxy, or proxy failure detection.

The lifecycle suite used distinct local DNS answers and real TCP connections
between namespaces. Both main and VPN test routes reached the same controlled
peer; assertions checked conntrack and actual packet marks to distinguish the
routing decisions. Public IPv6 Internet access and throughput were not tested.
IPv6 set population, rejection rules and timeout refreshes were tested locally.
Software and hardware flow offloading were disabled throughout the project tests.

## Recorded results

| Run | Assertions | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: | ---: |
| Full installer matrix, 33 cases | 635 | 614 | 1 | 20 |
| Targeted repeat of mode 4 | 40 | 39 | 0 | 1 |
| Full feature mode 14 before lifecycle/reboot | 47 | 46 | 0 | 1 |
| DNS and live TCP/LAN lifecycle | 31 | 31 | 0 | 0 |
| Actual reboot verification | 11 | 11 | 0 | 0 |
| Default mode restored after reboot | 42 | 41 | 0 | 1 |
| Host-safe Python suite | 46 | 46 | 0 | 0 |

The full matrix's single failure occurred during `apk update`, before the
installer changed persistent configuration. A package-index fetch stopped with
`Operation not permitted`. A separate complete rerun of that mode passed
without production changes. The same intermittent package-download error
occurred once during preparation of mode 14; its repeat passed as well. The
cause of those download failures was not established. No functional failure
remains among the 33 matrix scenarios after the targeted rerun.

All skips are unused domain-list download recovery branches: successful
installations obtained a valid list on their first attempt. Rejected downloads,
validation failures and transactional retries are covered by host-safe tests.

All 16 option combinations passed, including modes without WDNS, missing VPN
route behavior, IPv6 denial, two-day timeout renewal for router/LAN packets,
all list selections, invalid CLI/country inputs, repeat installation and mode
transitions. Omitting `--wdns` retains an existing tag and repairs its route.
Uninstall removes the tag definition and WDNS routing rules, preserves complete
named/anonymous static leases and their tag references, and tolerates repetition.

The 31 lifecycle checks verified:

- selected and manual routing domains use WDNS; unrelated domains use provider DNS;
- equal-name native IP Sets rows preserve the generated union;
- a full nft set does not prevent the DNS answer, cannot learn another address,
  and produces a dnsmasq insertion error;
- learning an address mid-connection keeps an existing direct flow direct;
- new connections to the learned address receive the VPN decision;
- expiry removes the address while existing VPN flows retain their packet mark;
- DNS add/delete and source replacement preserve established flows and learned IPs;
- router and LAN packets keep their respective decisions;
- unrelated packet/conntrack mark bits survive, and replies receive no VPN bit.

Three additional workflows were performed through the actual LuCI forms:
add a domain in **DNS → IP Sets** and a corresponding local hostname, change
the hostname's IP, then delete both rows using **Save & Apply**. Both configured
IPs resolved correctly and populated `vpn_domains`; deletion removed the generated
DNS rule and UCI entries. The original DHCP snapshot was restored afterward.

An actual reboot in mode 14 restored identical cached source, compiled DNS and
sing-box configuration. A local static IP was seeded before the first query.
The manual hostname and CNAME resolved, synchronization resumed, temporary WDNS
guards cleared, and full diagnostics passed. Cleanup restored DHCP and removed
the boot fixtures.

## Defects found and fixed

1. The original mark expressions combined two runtime registers, which the
   Linux 6.12 nft bitwise implementation rejected with `Not supported`.
   Commit `9f668fa` replaces them with conditional rules using constant masks.
   Real firewall application, connection marks, packet marks, reply direction
   and preservation of other bits passed on Linux 6.12.94.
2. Repeat installation deleted and recreated retained sections, changing their
   configuration order. Commit `603123d` updates retained sections in place and
   deletes optional sections only when their option is disabled. Identical
   option sets now yield identical configuration fingerprints.

Test-only issues were also corrected: anonymous UCI IDs change when preceding
sections disappear; minimal BusyBox `nc` cannot listen; numeric netcat endpoints
must disable DNS lookups inside isolated namespaces; dnsmasq errors need an
explicit log destination; DNS application and busy transaction locks require
bounded readiness/retry waits. Final lifecycle and reboot runs used those fixes.

## Final state and evidence

The router remains installed in default mode: IPv4 domain routing, the default
`icanhazip.com` mapping, no WDNS tag, no kill-switch and no IPv6 deny. Both
offloading settings remain zero. `fw4 check`, runtime configuration comparison
and the complete matrix diagnostic passed. Temporary namespaces and test DNS
rows were removed. The controlled sing-box fixture remains; it is not an
external proxy configuration.

Original device configuration backups remain on the router under
`/root/getdomains-test-backup-20261009`. Raw device logs were retained outside
the repository. The [case summary](openwrt-25.12.5-2026-10-09-cases.tsv) preserves
the initial package-fetch failure and its successful rerun instead of rewriting
the original result. No router addresses, credentials or private configuration
are committed.
