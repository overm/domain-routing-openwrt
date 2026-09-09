# OpenWrt router integration tests

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
  all optional modes back to defaults;
- UCI state, generated files, active nftables sets/rules, policy routing,
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
- the three repository scripts copied to `/tmp/domain-routing-source`.

No router address, credentials, or sing-box configuration should be stored in
the repository. The installer obtains the test copies of the diagnostic and
uninstaller through a local `file://` URL, so every scenario tests one coherent
source revision.

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
