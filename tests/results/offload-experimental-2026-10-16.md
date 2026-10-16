# Experimental medium profile: target validation, 2026-10-16

Branch: `codex/experimental-medium-offload` (working tree). Physical target:
Xiaomi AX3000T / MT7981, OpenWrt 25.12.5, Linux 6.12.94, nftables 1.1.6,
aarch64. Raw logs, credentials, addresses and configuration backups remain
private. These are functional checks, not throughput qualification. The
[source manifest](offload-experimental-source-2026-10-16.json) records the base
commit, working-tree hashes and host checks.

## Scope

The experimental path was exercised on real wired hardware by temporarily
changing only its board identity to an unqualified test identity. Driver,
device tree, Ethernet topology, kernel, PPE and native owner were real.
This does **not** qualify a different physical model or MT7986 hardware.
The temporary sing-box TUN used a controlled SOCKS5 TCP/UDP peer; an external
encrypted VPN provider was not part of this test.

## Completed checks

| Area | Result |
| --- | --- |
| Host | 87 Python tests passed, including 16 JavaScript transport assertions; shell/JavaScript syntax and whitespace checks passed. |
| Platform probe | [8 target cases](offload-experimental-platform-2026-10-16.json) passed using real hardware and isolated board/consent metadata. |
| Ucode | [15 target groups](offload-experimental-ucode-2026-10-16.json) passed; mutations mocked in this fixture. |
| General installation | [661 assertions](offload-experimental-software-2026-10-16.json): 640 passed, 0 failed, 21 skipped retries. All option combinations, country selections, reinstall/uninstall, routing, DNS sets and timeouts covered. |
| DNS lifecycle | 31 assertions passed, including live TCP routing marks and preservation of unrelated conntrack/packet bits. |
| Boot restoration | 11 assertions passed after a real reboot with stable TUN/DNS readiness. |
| Consent | [14 cases](offload-experimental-consent-2026-10-16.json): no, empty input and EOF persisted disable, cleared consent and booted without owner/table/PPE bindings. Explicit yes persisted medium plus board-bound consent and booted READY. |
| Limits | Unqualified strict selected disable. Explicit disable and kill-switch skipped the prompt; medium/strict with kill-switch booted DISABLED_KILL_SWITCH. |
| LuCI | [Authenticated status](offload-experimental-luci-status-2026-10-16.json) reported medium, READY, experimental consent and no pending reboot. |
| Physical forwarding | [TCP](offload-experimental-nat-tcp-2026-10-16.json) and [UDP](offload-experimental-nat-udp-2026-10-16.json) each established 8 HW_OFFLOAD connections with 16 PPE bindings. Existing direct decisions stayed sticky after target learning; 8 new selected connections received VPN marks with zero VPN HW_OFFLOAD and working replies through TUN. |
| Medium policy | [An existing accelerated TCP connection](offload-experimental-medium-policy-2026-10-16.json) survived a newly added reject rule before reboot (2 PPE bindings). Reboot enforced the reject; removal followed by reboot restored connectivity. |
| Reinstallation | Declining again cleared consent and selected disable. Live policy remained unchanged before the required reboot; the reboot removed the owner/table. Tunnel configuration was preserved. |
| Quiet resources | [Approximately 0% core](offload-experimental-resources-2026-10-16.json) for the three holders and 8.47% for the supervisor including reaped children over 10.86 seconds; stable file descriptors. PSS unavailable; this is not a load benchmark. |
| Owner namespace faults | Three suites of five groups passed: [transaction](offload-experimental-owner-transaction-2026-10-16.json), [queue](offload-experimental-owner-queue-2026-10-16.json), [empty queue](offload-experimental-owner-empty-queue-2026-10-16.json). These use an isolated test build and marker emergency callback. |
| Strict LuCI | [6 groups](offload-experimental-strict-luci-2026-10-16.json) passed: authentication, unchecked/checked apply, confirmation fencing, automatic rollback with closed admission, routine DNS and conflicting global offload rejection. No cleanup error was reported. |
| Strict native commands | [5 commands](offload-experimental-strict-commands-2026-10-16.json) passed without reboot: firewall reload, WAN down/up, network reload and sing-box restart. Tunnel configuration preserved; final diagnostics passed. |
| Strict physical policy | [Baseline](offload-experimental-strict-revoke-none-2026-10-16.json) established real HW_OFFLOAD/PPE TCP forwarding, revoked the old entries on a supported reject-rule change, rejected old/new connections and recovered on rule removal without reboot. |
| Strict holder faults | [Worker](offload-experimental-strict-revoke-worker-2026-10-16.json), [standby](offload-experimental-strict-revoke-standby-2026-10-16.json) and [keeper](offload-experimental-strict-revoke-keeper-2026-10-16.json) loss each drained old physical entries and replenished holders without reboot, then passed the reject/remove policy test. |
| Strict supervisor fault | [Supervisor loss](offload-experimental-strict-revoke-supervisor-2026-10-16.json) caused emergency reboot and recovery in 46.48 seconds, cleared old test entries, rebuilt physical forwarding and passed the reject/remove test. This does not establish uninterrupted forwarding during failure. |
| Qualified lifecycle | [17 stages](offload-experimental-strict-lifecycle-2026-10-16.json) passed, ending with strict plus kill-switch, medium plus kill-switch, medium READY and disable DISABLED after mandatory reboots. Live-policy snapshots were unchanged before mode-change reboots; disabled states had no owner/table/PPE bindings. |
| Software-only strict | [3 groups](offload-experimental-strict-fallback-2026-10-16.json) passed with kill-switch: native apply/rollback without owner, no stale lock on the next apply, service command and diagnostics. |
| Uninstall | [Live-owner removal](offload-experimental-uninstall-2026-10-16.json) rebooted, restored the four native LuCI/fw4 files, removed the owner/table/PPE bindings and WDNS definition, preserved static-lease tags and the test tunnel. The [removal lifecycle](offload-experimental-removal-lifecycle-2026-10-16.json) also verified consent-marker removal and restored board identity. |
| Final restoration | [Passed](offload-experimental-restoration-2026-10-16.json): all 18 archived regular files and 33 symlinks matched, including the original 17 primary hashes; rc symlink and package-name inventories matched the baseline. Project artifacts, test namespaces, temporary sing-box configuration and recovery service were absent. Native DNS and HTTPS worked after reboot. |

The functional cycle is complete. The original configuration and package-name
inventory were restored and verified; the local controlled proxy was stopped.
Private backup/evidence files remain outside the repository and in the root-only
backup directory on the testbed. No raw configurations or credentials are
published here.

## Corrections and test setup

The Windows checkout converted checksum metadata to CRLF. The installer
correctly rejected it before installation; the binary digest matched. Added
`*.sha256 text eol=lf`, normalized uploader metadata and added a raw-byte
regression assertion. Integrity validation remains strict; no native binary,
kernel or driver changes were needed.

Initial fixture attempts required a reachable DNS server, a working TUN peer,
an authenticated LuCI session token, and waiting for stable DNS/TUN readiness
after reboot. These setup attempts were corrected before the successful runs
reported above. A long pause triggered the armed recovery and required test
fixture restoration before the strict regression resumed.

During final restoration, the local cached APK lacked an independently trusted
package signature. The original dnsmasq variant was instead restored through
the trusted OpenWrt repository index, without disabling signature checks.
The final verifier was resumed after a short SSH reconnect deadline expired
during reboot; all baseline, artifact and connectivity checks subsequently passed.

Maximum throughput, large flow counts/table saturation, Wi-Fi, other physical
router models and a 24-72-hour soak were not tested.
