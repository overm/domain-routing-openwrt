# Installed offload modes: 2026-10-11

Production implementation on branch `codex/offload-modes`, based on master
`18dba24`, with the earlier lifecycle research retained as context. The tested
target is Xiaomi AX3000T / MT7981, OpenWrt 25.12.5, Linux 6.12.94, nftables 1.1.6.
Credentials, addresses, tunnel configuration, session tokens and raw device logs
are retained privately and are not part of this report.

The production aarch64/musl owner was built twice with the matching official SDK,
`-Wall -Wextra -Werror`, without warnings. Both builds produced SHA-256
`b12b5618503bbe2b942fe145d940436f2683d73d38c68cdf623f43a2d4b628ba`.
See [build provenance](../../offload/BUILD.md) and the
[installed contract](../../docs/OFFLOAD_MODES.md).

## Recorded checks

| Check | Evidence and scope |
| --- | --- |
| Host-safe regression | 80 Python tests passed, including the JavaScript test's 16 assertions; compiler/runtime/bootstrap/controller coverage and failed PPE/policy/cache reads; no installer or device dispatcher executed on the development computer. Shell syntax and whitespace checks also run. |
| Strict installation and reboot | [Matrix](offload-modes-matrix-strict-2026-10-11.json): live rules preserved before reboot, reboot marker cleared, private admission ready, full diagnostics successful, real tunnel configuration retained. |
| Disable and kill-switch | [Disable](offload-modes-matrix-disable-2026-10-11.json), [strict kill-switch](offload-modes-matrix-strict-kill-2026-10-11.json), [medium kill-switch](offload-modes-matrix-medium-kill-2026-10-11.json): no private table/owner, empty PPE, diagnostics and retained tunnel configuration; both kill-switch cases reject marked IPv4 after the VPN default route is temporarily removed. |
| Ownerless strict LuCI | [Software fallback](offload-modes-software-fallback-2026-10-11.json): actual native unchecked apply and unconfirmed rollback, no asynchronous lock left behind, subsequent apply and service transport allowed, diagnostics successful, no reboot. |
| Native LuCI commands | [Five actual HTTP operations](offload-modes-commands-2026-10-11.json): firewall reload, WAN down/up, network reload, sing-box restart, all without reboot; WAN recovery checked through netifd. |
| LuCI apply/rollback/DNS | [HTTP suite](offload-modes-luci-2026-10-11.json): asynchronous unchecked/checked apply, valid-token-only reopening, actual firewall-rule rollback, persistent closed admission after rollback callbacks, session/path/CSRF validation, manual DNS/IP Sets add/delete, conflicting global acceleration refused. |
| Ucode boundaries | [Fifteen groups](offload-modes-ucode-2026-10-11.json): native/foreign hook validation, foreign cache refusal, stable object identity, removed manual row classification, native execution ACLs/software fallback, queued-apply exclusion, invalid requests/injection, WAN port restoration, changed snapshot/commit failure, native NoData success, checked apply/confirmation publication failures, confirmation and reversible native-view edits. Device mutation mocked in this fixture. |
| Kernel owner and failures | [Transaction deadline](offload-modes-owner-2026-10-11.json), [empty queue deadline](offload-modes-owner-queue-2026-10-11.json): real owner/persist table protection, generation and phase fencing, death after RETIRE, standby/keeper replenishment and independent timeout retention. Isolated namespace; three-second test deadline instead of production 180 seconds; no physical forwarding claim. |
| Physical direct TCP NAT | [Eight connections](offload-modes-nat-tcp-8-2026-10-11.json): eight direct classifications and HW_OFFLOAD flags, five physically bound PPE entries in the snapshot; existing direct connections stay sticky when the target is learned, eight new selected connections get VPN marks and no HW_OFFLOAD. |
| Physical direct UDP NAT | [Eight connections](offload-modes-nat-8-2026-10-11.json): eight direct classifications/HW_OFFLOAD flags and sixteen bound PPE entries; sticky existing decisions and new selected VPN connections verified. |
| Low-rate UDP | [NTP](offload-modes-nat-ntp-8-2026-10-11.json): replies and eight direct classifications verified; HW_OFFLOAD flags present but zero bound PPE entries. A flag alone does not prove physical acceleration. |
| Supported critical revocation | [Baseline](offload-modes-revoke-2026-10-11.json), [worker death](offload-modes-revoke-worker-2026-10-11.json), [standby death](offload-modes-revoke-standby-2026-10-11.json), [keeper death](offload-modes-revoke-keeper-2026-10-11.json): real accelerated TCP, old test tuple removed from PPE, new rejection blocks old/new test TCP, rule removal restores connectivity without reboot. Single-holder failures rotate the generation and replenish holders under the physical barrier. |
| Medium policy and reboot | [Actual TCP policy change](offload-modes-medium-policy-2026-10-11.json): the old accelerated TCP connection continued through a newly applied rejection with two bound PPE entries; reboot removed that tuple and blocked old/new TCP. Removal plus another reboot restored connectivity. Passive expiry was not assumed. |
| Supervisor failure | [Emergency reboot](offload-modes-revoke-supervisor-2026-10-11.json): kill of the actual supervisor caused an automatic reboot; ready hardware recovered in 46.72 seconds. Old test entries were absent; fresh accelerated TCP and subsequent policy revocation/removal passed. This measures recovery, not zero packets in the failure window. |
| Removal | [Uninstall](offload-modes-uninstall-2026-10-11.json): live ownership retained until automatic reboot, native LuCI/fw4 files restored exactly, private table/PPE cleared, tunnel preserved, `wdns` definition removed while static-lease tags remained. |
| Quiet-load resources | [Ten-second sample](offload-modes-resources-2026-10-11.json): supervisor plus reaped children used 9.25% of one core, active owner 0.09%, standby/keeper 0% at this resolution; FD counts stayed 6/6/4/4. RSS per role is recorded; shared pages prevent interpreting its sum as unique memory. PSS is unavailable, not zero. Includes SSH measurement activity. |

Traffic snapshots include outstanding replies and can include unrelated background
traffic. They are not throughput, packet-loss or CPU measurements. The revoke
fixture checks its own original/reply tuple so newly admitted background flows
are not confused with stale test entries.
The controller was corrected iteratively during qualification. Final host/ucode,
strict fresh-install/emergency and medium-install checks cover the last safety
changes. Earlier NAT and single-holder measurements exercise the unchanged
classifier/native-owner behavior; they are not independent load qualifications.

## Testbed restoration

[Final restoration](offload-modes-restoration-2026-10-11.json) passed: all 16
saved configuration/program hashes and two additional native-view hashes matched,
package inventory was unchanged, private tables/PPE/module/recovery service were
absent and the recovery watchdog was disarmed. Original project diagnostics,
router DNS and IPv4 HTTPS explicitly bound to the real tunnel succeeded.

## Defects caught and repaired

- A WAN explicitly stopped before a barrier was missing from its restoration
  snapshot. Native ifup now restores that newly requested child port.
- Service execution incorrectly required an additional UCI configuration-write
  grant. It now retains native file.exec/rc.init permissions; installing a LuCI
  sing-box configuration application is not required to restart the service.
- A competing observer/LuCI transaction could turn ordinary lock contention into
  a reboot. Busy transactions now return a retryable status, observer retries
  retain the pending policy difference, and queued LuCI preparation waits.
- Deferred rollback reloads could race later operations or reopen admission.
  Callbacks serialize through the physical lock, and rollback quarantine remains
  until a successful explicit critical operation or reboot.
- Ownerless strict fallback now retains native apply/rollback cleanup after
  checking that no private/foreign cache is active, preventing an unconfirmed
  software-only apply from leaving the next operation locked indefinitely.
- Cold-boot admission waits for WAN/policy stability. Object handles and table
  enumeration order are excluded from the observer fingerprint, preventing an
  unchanged startup reload from incorrectly requiring another medium reboot.
- A checked apply could fail after scheduling native rollback but before
  publishing its confirmation metadata. The confirmation interval is now armed
  first; apply errors quarantine hardware, reconcile the actual policy, and
  retain a possibly pending checked reservation until confirm/timeout.
- Failed PPE reads and unsuccessful policy/cache queries now refuse hardware
  admission or software-fallback verification. An empty pipeline output is not
  treated as evidence that the hardware or policy is safe.

## Remaining qualification

This is an experimental wired profile. The measured hardware workload is small
and uses actual direct SNAT and the real tunnel; it does not qualify Wi-Fi,
additional devices/topologies, maximum throughput, mixed bidirectional bulk
traffic, hardware table saturation, external WAN address/gateway MAC churn under
load, CPU/resource growth under load or a 24–72 hour soak. Earlier prototype stress
results do not substitute for these production-controller tests.
The available LAN/WAN-side connections belong to the same computer. The earlier
duplex fixture avoids local delivery by using router-side DNAT, which this
production classifier deliberately excludes. Large direct-SNAT qualification
needs an independent controlled WAN peer; public DNS is not a bulk-load endpoint.

Strict preparation guarantees apply to the documented LuCI/fw4/root-wrapper
entry points. Arbitrary external RPC/nft changes are observed after the event,
where detected; simultaneous loss of all holders has an emergency recovery
window. Medium accepts stale existing decisions until reboot. These boundaries
are described in both public READMEs and the installed contract.
