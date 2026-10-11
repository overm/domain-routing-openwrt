# Offload lifecycle prototype: 2026-10-10

Base: master `18dba24ebfef8f166de84dda96a00fe182908fa2`.
Research branch: `codex/offload-lifecycle-prototype`.

Target: Xiaomi AX3000T, MediaTek MT7981/Filogic, OpenWrt 25.12.5,
Linux 6.12.94, nftables 1.1.6, firewall4 2025.03.17~b6e51575,
conntrack-tools 1.4.8, dnsmasq 2.93, sing-box 1.13.21.
The existing real tunnel/DNS configuration was preserved. No packages,
drivers or firmware were installed or rebuilt on the target. Temporary test
rules, userspace binaries and LuCI/fw4 integration fixtures were used.

## Findings

**WAN-only revocation is not qualified.** On a fresh boot, eight bidirectional
UDP connections produced 16 physical PPE BND records. After exact conntrack
deletion, private veth device-down events and WAN down, 12 remained through
13 seconds and six still remained at 45 seconds. The controller refused to
unregister the flowtable or proceed to a policy change. The saved configuration
was recovered by reboot. Older two-flow successes cannot justify a universal
13-second revocation deadline.

**The common Ethernet stop passed the recorded live tests.** The flowtable was
kept registered through cleanup, both PPE engines had to be empty in two
consecutive polls, then the owner deleted the flowtable before Ethernet was
restored. Independent senders on LAN and WAN continued trying to send. Half
the flows were forbidden after policy change; the other half were controls.
The harness also reopened the same tuples to detect latent hardware revival.

| Experiment | Warm physical BND records | Observation after guard | Outcome |
| --- | ---: | ---: | --- |
| UDP, 8 flows | 16 | 60 seconds | 0 forbidden frames in either direction; allowed UDP resumed; same tuples stayed blocked |
| TCP, 8 flows, worker crash and native firewall reload | 16 | 30 seconds | Table ownership preserved; 0 forbidden frames; old TCP controls disconnected; fresh allowed TCP worked; old tuple blocked by actual drop counter |
| UDP, 128 flows, two cycles | 256 each | 45 seconds each | 0 forbidden frames; controls worked; PPE remained empty; same tuples stayed blocked |
| UDP, 512 flows | 1021 (of 1024 possible directional records) | 300 seconds | All 512 flows received in both directions before revocation; 0 forbidden frames afterward; over 2.4 million allowed control frames in each direction; same tuples stayed blocked |
| UDP, 8 flows, links held through policy commit | 16 | 30 seconds | Guard applied before restoration; 0 forbidden frames; every allowed direction received at least 960 frames; same tuples stayed blocked |
| TCP, 8 flows, links held through policy commit, worker crash | 16 | 30 seconds | Guard applied before restoration; 0 forbidden frames; fresh allowed TCP worked; old tuple blocked with drop counter increment |

These runs observed preparation from the host in approximately 8.4 seconds,
including management reconnection. The on-device empty-PPE polls occurred at
0/1 seconds for the eight-flow tests and 2/3 seconds for the 128-flow tests,
measured from preparation start. These times include fixture work and are not
a driver deletion acknowledgement or a guaranteed deadline.
The 512-flow test observed 16.844 seconds from the host, with empty-PPE polls
at 11/12 seconds. Exact per-port conntrack deletion adds measurable preparation
cost as the test population grows. Three potential directional hardware records
were not bound at the warm snapshot; the test does not claim every direction
of all 512 flows was simultaneously accelerated.

The price of this method is significant: all wired LAN ports and WAN pause,
management disconnects, and current TCP sessions can be lost. It is a possible
fallback for infrequent administrative transitions, subject to the user's
acceptance of disruption. It is not suitable for routine domain-list refreshes.

**Single-process ownership retention passed five fault cycles.** A standby
inherited the same libnftables/netlink socket. Killing the standby closed
admission in the worker; replacing it preserved ownership. Killing the worker
closed admission in the standby; all 500 attempted foreign table deletions
were rejected. Five queued old-generation re-enable requests were rejected
using epoch fencing. Recovery used the same inherited socket through local IPC.
The namespace fault test contained no hardware flowtable.

The deliberate both-process-dead negative control succeeded in deleting the
now-unowned persistent table. This remains an unresolved failure class;
`persist` alone does not provide a crash-proof ownership guarantee.

**LuCI/fw4 ordering passed 14 cases using actual authenticated HTTP handlers.**
The callback was instrumented, with global hardware offloading disabled and
empty PPE. It did not perform the physical Ethernet stop during HTTP tests.

- Both unchecked and checked apply returned HTTP 503 before committing when
  preparation failed. The firewall configuration hash remained unchanged.
- Successful unchecked apply invoked the LuCI hook before commit, then the
  fw4 hook after commit and before kernel application.
- Native checked apply returned its rollback token, confirmation succeeded,
  and an unconfirmed second apply automatically restored the previous marker
  after the native 90-second window.
- Pending network and `wdns` changes were blocked before commit. A harmless
  ordinary dnsmasq marker used the native path without calling preparation.
- Native fw4 reload/restart/stop/flush/reload-sets all refused mutation when
  preparation failed; the kernel forward chain remained identical.
- Direct UCI RPC committed the marker despite the failing LuCI callback. This
  negative control proves a remaining integration boundary, not a passing
  safety property for that entry point.

The stock LuCI controller remained unchanged; a separate temporary module and
menu-action override were removed afterward. These tests exercised backend
HTTP endpoints, not visual browser form automation. The first login pilot was
rejected because plain rpcd login lacks the token LuCI requires; the corrected
fixture initializes the token as the native dispatcher does.

The [reviewed JSON](offload-lifecycle-2026-10-10.json) contains all nine selected
experiments, including the WAN-only counterexample. The unchanged production
host suite passed all 50 tests. Shell syntax and whitespace checks passed;
the C owner compiled with `-Wall -Wextra -Werror` and ran against the target's
existing musl/libnftables libraries.

## Final restoration

The target was restored and rebooted; its boot ID changed. All eight final
checks passed: the nine saved file hashes matched exactly, the package
inventory was unchanged, both global offloading options remained zero, lab
tables/namespaces/interfaces/modules were absent, both PPE tables were empty,
firewall/runtime/full diagnostics passed, fresh captured selected DNS queries
went to WDNS through the tunnel while control queries went to the provider
over WAN, and both selected/direct HTTPS requests succeeded with certificate
validation and distinct egress responses. The persistent private recovery
backup and evidence remain on the target; no raw logs or credentials were
added to this repository.

## Measurement limits

- Physical tests cover scoped direct IPv4 NAT traffic on one board and topology.
  They do not qualify full production eligibility, IPv6, other SoCs, Wi-Fi,
  accelerated tunnels, hardware saturation or throughput.
- The first physical tests restore links before the harness applies the new
  guard. They prove revocation and post-change enforcement, not an atomic
  production commit protocol. The held-link UDP test verifies the local order
  `HELD -> POLICY_APPLIED -> RESTORED` before acknowledging completion to the
  host. It qualifies a lab drop guard, not all production policy transitions
  or preservation/removal of sticky software conntrack decisions.
- Physical BND presence plus bidirectional reception established active
  hardware before revocation. Conntrack flags alone were not accepted as proof.
- UDP senders did not depend on replies. TCP used simultaneous open and new
  allowed controls after reset; dead sockets were not accepted as proof of a
  firewall block.
- The 512-flow pilot was invalidated by a test-host SSH reconnection race.
  Its autonomous operation completed, but the watchdog later rebooted the
  device; no live post-change result is claimed for that pilot.
- Private command logs contain addresses/session identifiers and are excluded.
  Initial incorrect range-filter and interrupted SSH pilots are not passing
  results. Reviewed JSON records retain the counterexample and valid runs.

Production offloading remains disabled. The [research design](../../docs/OFFLOAD_LIFECYCLE_RESEARCH.md)
records the remaining integration and failure requirements.
