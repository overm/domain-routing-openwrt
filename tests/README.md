# OpenWrt router integration tests

## Host-safe checks

Run `python -B -m unittest discover -s tests -p 'test_*.py' -v` with Python 3,
POSIX sh and awk (Git for Windows is supported; override the shell with
`GETDOMAINS_TEST_SH`). These tests execute only the pure compiler and runtime
function definitions with mocked UCI, nft, DNS, download and service boundaries.
They never execute the installer, uninstaller or runtime device dispatcher.
Coverage includes DNS selection, exact/subdomain precedence, equal-domain set
union, local records, IPv6, injection/size limits, stale-rule deletion, concurrent
LuCI snapshots, failed downloads/validation/seeding/restarts, retry and boot restore.
They do not validate nft syntax or kernel behavior; that requires the target.

`router-install-matrix.sh` is a destructive integration suite for an expendable
OpenWrt 25+ router. It repeatedly removes and installs domain routing while
preserving `/etc/sing-box/config.json` and verifying that its SHA-256 never
changes.

The suite covers:

- all 16 combinations of `--no-icanhazip`, `--ipv6-deny`, `--kill-switch`, and
  the presence or absence of `--wdns`;
- all three interactive domain-list selections;
- help, unknown arguments, a missing `--wdns` value, and representative invalid
  IPv4 values;
- idempotent installation, reordered/repeated arguments, and a transition from
  all optional modes back to defaults, including migration of a retained
  `wdns` DHCP tag that predates its policy-routing rule, preservation of other
  DHCP options and explicitly tagged leases;
- uninstalling removes the `wdns` tag definition and its routing rules while
  preserving named/anonymous static leases, their `wdns` references and other
  tags, including after a repeated uninstall;
- UCI state, generated files, active nftables sets/rules, domain and WDNS policy routing,
  service state, dnsmasq-to-nft set population, and `getdomains-check`;
- fail-open versus kill-switch routing after temporarily removing the VPN
  default route;
- real two-day timeout refreshes for router-local and simulated LAN IPv4/IPv6
  traffic. The LAN client runs in a temporary network namespace connected to
  `br-lan` through a veth pair.

## Safety and prerequisites

Run this only on a router whose configuration may be replaced. The suite
installs `kmod-veth`, restarts network/firewall/dnsmasq/sing-box many times, and
finishes by restoring the default domain-routing mode. A factory reset is still
recommended after testing.

The router must already have:

- OpenWrt 25 or newer with working package repositories;
- a valid, working sing-box configuration and tunnel;
- all three original scripts plus `getdomains-runtime.sh` and
  `getdomains-compile.awk` copied to `/tmp/domain-routing-source`.

No router address, credentials, or sing-box configuration should be stored in
the repository. The installer obtains the test copies of the diagnostic and
uninstaller through a local `file://` URL, so every scenario tests one coherent
source revision.

After the matrix, install `conntrack` and `kmod-veth`, copy
`tests/router-dns-lifecycle.sh` to the router, and run:

```sh
GETDOMAINS_ALLOW_DESTRUCTIVE_TESTS=1 sh /tmp/router-dns-lifecycle.sh
```

This additional destructive suite uses isolated DNS servers and namespaces to
test distinct WDNS/provider answers, equal-domain native nftset collisions,
real direct/VPN TCP connections from the router and LAN, packet-mark restoration
after IP expiry, learning an IP mid-connection, LuCI add/delete/local overrides,
and source replacement while flows remain established. Test-specific VPN routes
lead to a controlled namespace rather than the remote proxy. The matrix still
tests the real tunnel's routing and missing-route behavior. Cleanup restores
dhcp/network/source snapshots; use an expendable router with no concurrent edits.
The fixture uses TEST-NET addresses and ports 1053–1055/18081–18084; ensure they
are unused. It does not prove remote WDNS availability, proxy health, or behavior
across a reboot. Reboot/client-cache limitations are documented in both READMEs.

No results for this new lifecycle suite have been recorded yet. Existing reports
under `tests/results` describe their recorded revisions, not these changes.

Run on the router:

```sh
GETDOMAINS_ALLOW_DESTRUCTIVE_TESTS=1 \
GETDOMAINS_TEST_SOURCE_DIR=/tmp/domain-routing-source \
GETDOMAINS_TEST_RESULT_DIR=/tmp/domain-routing-results \
sh /tmp/domain-routing-source/tests/router-install-matrix.sh
```

The result directory contains a TAP stream, a per-case TSV summary, environment
metadata, and detailed logs. Installer logs can contain network-specific data;
review them before publishing. The committed result report is a manually
reviewed summary rather than a raw log archive.
