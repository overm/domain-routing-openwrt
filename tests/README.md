# OpenWrt router integration tests

## Host-safe checks

Run `python -B -m unittest discover -s tests -p 'test_*.py' -v` with Python 3,
POSIX sh and awk (Git for Windows is supported; override the shell with
`GETDOMAINS_TEST_SH`). These tests execute only the pure compiler, runtime
function definitions and the installer's isolated support-download stage with
mocked UCI, nft, DNS, download and service boundaries. Download staging paths
are redirected into a temporary directory. They never execute the full installer,
uninstaller or runtime device dispatcher. Bootstrap tests cover the default source,
branch/commit/local overrides, partial downloads and invalid helper syntax,
including cleanup before any support file is installed.
The firewall compatibility test reads the generated-rule templates and rejects
mark assignments that combine runtime registers unsupported by Linux 6.12.
Coverage includes DNS selection, exact/subdomain precedence, equal-domain set
union, local records, IPv6, injection/size limits, stale-rule deletion, concurrent
LuCI snapshots, failed downloads/validation/seeding/restarts, retry and boot restore.
They do not validate nft syntax or kernel behavior; that requires the target.

## Installed offload modes

Read [the supported contract](../docs/OFFLOAD_MODES.md). The initial hardware
profile is experimental and specific to AX3000T / kernel 6.12.94 / nft 1.1.6.
Host tests also cover mode parsing, physical-barrier ordering, generation
fencing, failed commands even inside shell conditionals, closed admission during
confirmation, queue deadlines, and the real JavaScript apply/command transport.
The JavaScript suite runs 16 assertions with Node.js; missing Node is a skip.

Build the production and isolated owner with the matching musl SDK as documented
in [BUILD.md](../offload/BUILD.md). Never install the isolated test binary.
The following host harnesses require Python/Paramiko, an independently verified
SSH host key, explicit `GETDOMAINS_ALLOW_DESTRUCTIVE_TESTS=1`, and target/password
in `GETDOMAINS_TEST_HOST` / `GETDOMAINS_TEST_PASSWORD`. Keep raw logs private.

```sh
python3 -B tests/router-offload-modes.py stage --known-hosts "$LAB_KNOWN_HOSTS" --private-evidence-dir "$LAB_PRIVATE/deploy"
python3 -B tests/router-offload-modes.py install --mode strict --known-hosts "$LAB_KNOWN_HOSTS" --private-evidence-dir "$LAB_PRIVATE/deploy"
python3 -B tests/router-offload-modes.py reboot --known-hosts "$LAB_KNOWN_HOSTS" --private-evidence-dir "$LAB_PRIVATE/deploy"
python3 -B tests/router-offload-unit.py --known-hosts "$LAB_KNOWN_HOSTS" --output "$LAB_RESULTS/ucode.json" --private-evidence-dir "$LAB_PRIVATE/ucode"
python3 -B tests/router-offload-owner.py --binary offload/owner-test --known-hosts "$LAB_KNOWN_HOSTS" --output "$LAB_RESULTS/owner.json" --private-evidence-dir "$LAB_PRIVATE/owner"
python3 -B tests/router-offload-luci.py --known-hosts "$LAB_KNOWN_HOSTS" --output "$LAB_RESULTS/luci.json" --private-evidence-dir "$LAB_PRIVATE/luci"
python3 -B tests/router-offload-commands.py --known-hosts "$LAB_KNOWN_HOSTS" --output "$LAB_RESULTS/commands.json" --private-evidence-dir "$LAB_PRIVATE/commands"
python3 -B tests/router-offload-matrix.py --known-hosts "$LAB_KNOWN_HOSTS" --output "$LAB_RESULTS/modes.json" --private-evidence-dir "$LAB_PRIVATE/modes"
python3 -B tests/router-offload-revoke.py --client-ip "$LAB_LAN_IP" --known-hosts "$LAB_KNOWN_HOSTS" --output "$LAB_RESULTS/revoke.json" --private-evidence-dir "$LAB_PRIVATE/revoke"
python3 -B tests/offload-nat-load.py --client-ip "$LAB_LAN_IP" --protocol udp --flows 8 --learn-target --known-hosts "$LAB_KNOWN_HOSTS" --output "$LAB_RESULTS/nat.json" --private-evidence-dir "$LAB_PRIVATE/nat"
```

`stage` takes a persistent backup and arms recovery; never replace an existing
backup. Use `upload` for later revisions. Install/reboot tests interrupt the
router. The installed strict apply tests disconnect Ethernet and may clear all
IPv4 connections or reboot on failure. The ucode fixture mocks all mutations;
only private fixture copies are written. Owner faults run in a network namespace
and use a marker callback instead of reboot. Neither proves physical PPE use.
The NAT fixture must originate on a physical LAN client whose gateway is the
target, and asserts real HW_OFFLOAD/PPE entries. `--protocol tcp` uses framed DNS
over TCP. Public DNS load is capped at 500 queries/second; large-flow hardware
qualification requires a controlled WAN peer instead. A low-rate NTP probe
(`--service ntp --expect connectivity`) verifies forwarding without claiming
PPE binding. Small flows can retain HW_OFFLOAD while remaining physically unbound.
The revoke fixture pipelines a real TCP stream, applies/removes a scoped reject
rule through the root controller, and requires old PPE entries gone, both old/new
TCP rejected, connectivity recovered and no reboot. These do not measure throughput.
Use `--fault worker`, `--fault standby` or `--fault keeper` to kill an installed
holder with a physically accelerated TCP flow, require its old entries drained,
and verify replenishment without reboot before the policy test. `--mode medium`
records whether the old stream survives a rule change before reboot, then
requires the new rejection and subsequent rule removal to work after reboot.
`--fault supervisor` kills the installed observer, requires an actual emergency
reboot and fresh hardware, then repeats the policy test. It verifies recovery,
not uninterrupted forwarding or zero packets during the failure window.
`router-offload-resources.py` samples the supervisor and three holders for ten
seconds under quiet load, including CPU time of reaped children, RSS, optional
PSS and file descriptors. SSH measurement itself adds activity; this is not a
bulk-load benchmark. RSS shares pages across forks and must not be summed as
unique memory; use PSS when available.
The command suite exercises real authenticated firewall reload, WAN down/up,
network reload and sing-box restart; WAN recovery is checked through netifd.
Close other LuCI browser tabs while running the raw HTTP rollback suite: native
`ui.changes` can resume and confirm an outstanding apply when a page loads.
Such an external confirmation invalidates an intentionally unconfirmed test.
`router-offload-fallback.py` runs in strict with kill-switch or another verified
software-only profile. It checks native apply/rollback without an owner, absence
of a stale asynchronous lock, subsequent apply, service transport and diagnostics.

Repeat installation with medium/disable and with kill-switch, reboot after each
transition, check diagnostics, native views and table absence when disabled.
`router-offload-uninstall.py` tests removal with a live owner, the automatic
reboot, restoration of native LuCI/fw4 files, and removal of the `wdns` definition
while retaining static lease tags. It requires the native-file backups created
by installation. Finish with the saved restoration and reboot:

```sh
python3 -B tests/router-offload-modes.py restore --known-hosts "$LAB_KNOWN_HOSTS" --private-evidence-dir "$LAB_PRIVATE/deploy"
```

Verify saved file hashes/package inventory, DNS/tunnel and original native LuCI
files after reconnect. Production qualification still needs mixed bidirectional
traffic, table saturation, external address/MAC churn and a 24–72 hour soak.

## Offload lifecycle research fixtures

These are opt-in prototypes, not an offload installation option. Read
[the design and limitations](../docs/OFFLOAD_LIFECYCLE_RESEARCH.md) and
[the measured target report](results/offload-lifecycle-2026-10-10.md) first.
The physical experiment is specific to the tested Filogic Ethernet topology.
It stops WAN and, with `--stop-parent`, all Ethernet ports, disconnects management,
can abort existing TCP connections, and may reboot the device on failure.
Do not run it on a development host or a router with concurrent configuration
changes. No driver/firmware changes or package installation are automated.

Prerequisites on the expendable target: libnftables, full `ip`, conntrack,
veth/network namespace support, `setsid`, PPE debugfs for both engines, an
already configured production project with global offloading disabled, and
access to local recovery. Build `tests/prototypes/offload-owner.c` using the
matching OpenWrt SDK (`make -C tests/prototypes CC="$TARGET_CC"`); copy only the
resulting owner binary and the shell fixtures to the device. Do not substitute
host libraries on the router. Python 3 and Paramiko are needed on the test host.
SSH host keys must already be independently verified in `--known-hosts`.

On the router, create a fresh persistent backup and arm the one-hour watchdog:

```sh
GETDOMAINS_ALLOW_DESTRUCTIVE_TESTS=1 sh /tmp/router-lifecycle-setup.sh \
  setup /root/getdomains-lifecycle-lab
```

The setup verifies disabled global offloading and empty PPE, saves the nine
configuration/program files it may restore plus the package inventory, and
creates a private veth pair. Use `rearm` only after reboot with the saved file
hashes unchanged; it refuses an existing `/tmp/gd-life-lab` directory. Upload
the binary to `/tmp/gd-life-lab/owner` and `offload-prepare.sh` to
`/tmp/gd-life-lab/prepare.sh`, then make them executable. Re-upload after reboot.
All paths and target credentials are supplied privately. For example, from a
POSIX test host with its actual environment variables already set:

```sh
export GETDOMAINS_ALLOW_DESTRUCTIVE_TESTS=1
python3 -B tests/offload-owner-faults.py \
  --backup /root/getdomains-lifecycle-lab --known-hosts "$LAB_KNOWN_HOSTS" \
  --output "$LAB_RESULTS/owner.json" --private-evidence-dir "$LAB_PRIVATE/owner"
python3 -B tests/offload-revoke-load.py \
  --backup /root/getdomains-lifecycle-lab --known-hosts "$LAB_KNOWN_HOSTS" \
  --lan-ip "$LAB_LAN_IP" --wan-ip "$LAB_WAN_PEER_IP" \
  --flows 128 --cycles 2 --protocol udp --stop-parent --post-seconds 45 \
  --output "$LAB_RESULTS/udp.json" --private-evidence-dir "$LAB_PRIVATE/udp"
python3 -B tests/offload-luci-preapply.py \
  --backup /root/getdomains-lifecycle-lab --known-hosts "$LAB_KNOWN_HOSTS" \
  --output "$LAB_RESULTS/luci.json" --private-evidence-dir "$LAB_PRIVATE/luci"
```

Provide `GETDOMAINS_TEST_HOST` and `GETDOMAINS_TEST_PASSWORD` in the environment.
The physical test host needs two independently addressed physical links: LAN
to the router's tested `lan3` port, and WAN-side to its upstream network. The
harness creates only narrowly scoped test NAT/filter/admission rules and sends
independent frames from both sides. It shuffles large-load tuple ports to avoid
an artificial PPE hash concentration. TCP uses simultaneous open; Windows
receiver sets are sharded. Confirm port availability and topology yourself.
Use `--guardian-crash` for active-worker death plus native firewall reload;
use `--hold-through-policy` with `--stop-parent` to apply the new lab guard
locally before link restoration (also upload `offload-resume.sh` to
`/tmp/gd-life-lab/resume.sh`).
`--timeout-probe` forces the unsafe-fallback rejection path. A failed physical
test deliberately retains the registered flowtable and may leave WAN stopped.
Use recovery instead of manually deleting that flowtable.

The LuCI suite temporarily adds a separate controller/menu and wraps fw4,
tests actual authenticated HTTP apply endpoints and rollback, then restores
the files. Its preparation callback is instrumented with hardware disabled;
this test alone does not prove physical revocation or complete RPC coverage.
Raw private evidence contains device addresses and session identifiers. Review
the address-free summaries before publication; never commit private evidence.

Finish on the router using the saved recovery script:

```sh
GETDOMAINS_ALLOW_DESTRUCTIVE_TESTS=1 sh /tmp/router-lifecycle-setup.sh \
  restore /root/getdomains-lifecycle-lab
```

After reboot, verify saved hashes/package inventory, disabled global offload,
empty PPE, absence of lab tables/processes/interfaces, and the real DNS/tunnel
configuration. A watchdog reboot is recovery, not a successful live barrier.

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
This DNS matrix explicitly installs `--offload disable`; start it after a reboot
with no running hardware owner. Hardware modes are tested by the separate suite.

The router must already have:

- OpenWrt 25 or newer with working package repositories;
- a valid, working sing-box configuration and tunnel;
- a DNS resolver reachable through that tunnel, supplied as
  `GETDOMAINS_TEST_WDNS`; the default TEST-NET address `192.0.2.53` requires an
  explicitly configured DNS fixture. Split DNS now sends actual queries there;
- all root `getdomains-*` source files copied to `/tmp/domain-routing-source`.

No router address, credentials, or sing-box configuration should be stored in
the repository. The installer obtains the test copies of the diagnostic and
uninstaller through a local `file://` URL, so every scenario tests one coherent
source revision.

After the matrix, install `netcat`, `conntrack` and `kmod-veth` (the minimal
BusyBox `nc` in some images cannot listen), copy
`tests/router-dns-lifecycle.sh` to the router, and run:

```sh
GETDOMAINS_ALLOW_DESTRUCTIVE_TESTS=1 sh /tmp/router-dns-lifecycle.sh
```

This additional destructive suite uses isolated DNS servers and namespaces to
test distinct WDNS/provider answers, equal-domain native nftset collisions,
real direct/VPN TCP connections from the router and LAN, packet-mark restoration
after IP expiry, learning an IP mid-connection, LuCI add/delete/local overrides,
and source replacement while flows remain established. It also checks unrelated
packet/conntrack mark bits and reply direction. Test-specific VPN routes lead to
a controlled namespace rather than the remote proxy. The matrix still
tests the real tunnel's routing and missing-route behavior. Cleanup restores
dhcp/network/source snapshots; use an expendable router with no concurrent edits.
The fixture uses TEST-NET addresses and ports 1053–1055/18081–18084; ensure they
are unused. It does not prove remote WDNS availability, proxy health, or behavior
across a reboot. Reboot/client-cache limitations are documented in both READMEs.

To test actual reboot restoration, copy `router-boot-restore.sh` to
`/root/router-boot-restore.sh` (not `/tmp`). On the expendable router run
`GETDOMAINS_ALLOW_DESTRUCTIVE_TESTS=1 sh /root/router-boot-restore.sh prepare`,
reboot, wait for services, then run the same command with `verify`.
This checks the persistent source and restored compiled DNS file, local-IP
seeding before queries, a manual hostname/CNAME, monitor, WDNS guards and full
diagnostics. Verification restores the DHCP configuration saved by preparation.

The [2026-10-09 report](results/openwrt-25.12.5-2026-10-09.md) records the split-DNS
matrix, live TCP/LAN lifecycle, actual LuCI add/edit/delete and reboot checks.
The [real-tunnel follow-up](results/openwrt-25.12.5-real-tunnel-2026-10-09.md)
records the complete matrix with a user-provided proxy and WDNS, plus captured
DNS/HTTPS traffic from the router and LAN. Private configurations and captures
are retained outside the repository.
Earlier reports under `tests/results` describe their own recorded revisions.

Run on the router:

```sh
GETDOMAINS_ALLOW_DESTRUCTIVE_TESTS=1 \
GETDOMAINS_TEST_WDNS=1.1.1.1 \
GETDOMAINS_TEST_SOURCE_DIR=/tmp/domain-routing-source \
GETDOMAINS_TEST_RESULT_DIR=/tmp/domain-routing-results \
sh /tmp/domain-routing-source/tests/router-install-matrix.sh
```

The result directory contains a TAP stream, a per-case TSV summary, environment
metadata, and detailed logs. Installer logs can contain network-specific data;
review them before publishing. The committed result report is a manually
reviewed summary rather than a raw log archive.

For a targeted rerun, set `GETDOMAINS_TEST_ONLY_MASK` to one integer from 0 to
15 and use a separate result directory. Bits 1/2/4/8 select `--no-icanhazip`,
`--ipv6-deny`, `--kill-switch` and `--wdns`, respectively. Only preflight and
that mode run; the selected mode remains installed afterward. Leave the
variable unset for the full matrix and final default restoration.
