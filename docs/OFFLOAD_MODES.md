# Offload modes and lifecycle contract

`--offload medium|strict|disable` defaults to **medium**. This is an experimental
selective hardware profile, not OpenWrt's global acceleration switch. Install,
reinstall and every mode transition require **reboot**. In medium, saved policy
is guaranteed after **Save & Apply + reboot**, not before that reboot.

## Eligibility and compatibility

The initial profile is Xiaomi AX3000T (`xiaomi,mi-router-ax3000t`), MT7981,
OpenWrt 25.12.5 / Linux 6.12.94 / nftables 1.1.6, with Ethernet parent `eth0`,
DSA LAN ports from board.json, `br-lan`, and `wan`. Both PPE debug dumps must be
readable. This remains the only qualified profile and the only profile allowed
to run `strict`.

Other MT7981/MT7986 boards may opt into **experimental medium**, subject to all
of these read-only checks:

- aarch64, Linux 6.12.94 and nftables 1.1.6 (the existing ABI/version gates).
- Readable PPE0 and PPE1 dumps, no third PPE, and `eth0`/`wan` devices.
- `eth0` uses `mtk_soc_eth`; its Ethernet device-tree compatible is
  `mediatek,mt7981-eth` or `mediatek,mt7986-eth`.
- The LAN runtime device is `br-lan`, the WAN runtime device is `wan` (no PPPoE),
  and all board.json LAN ports belong to that bridge. Those ports and `wan`
  must have the `eth0` ifindex as their iflink parent.

The installer invokes the staged controller's `platform-profile` probe, also
used at startup, so there is one compatibility implementation. A compatible but
unqualified board receives a warning about connectivity loss and accelerated
flows retaining old routes or bypassing new firewall restrictions until reboot.
Only `y`, `Y`, `yes` or `YES` followed by a newline accepts the `[y/N]` prompt.
Declining, empty input, EOF, an incompatible platform or unqualified `strict`
selects `disable` and continues installation. `--kill-switch` and `disable`
skip the experimental prompt and do not stage the native owner.

Acceptance is stored as the board ID in `/etc/getdomains/offload-experimental-board`.
Every reinstallation replaces/removes it based on a fresh answer, and uninstall
removes it. Startup requires a matching board ID, medium mode and a successful
platform probe. It never interprets consent as permission for strict, another
architecture/driver/version/topology, or incompatible policy. The CLI status
and diagnostics report `experimental_opt_in`; LuCI also shows an experimental
notice. This flag records consent, not proof of active hardware forwarding;
the runtime state/admission and actual HW_OFFLOAD/PPE entries must be inspected.
Physical validation of these additional boards is pending. Do not add them to
the qualified allowlist solely because they pass this probe.
The [2026-10-16 tests](../tests/results/offload-experimental-2026-10-16.md)
exercise this path on AX3000T with a simulated unqualified board identity;
they do not qualify another physical model.

Cold boot starts with empty admission and waits for a usable WAN default route
and five stable policy samples, for up to 60 iterations. Native startup reloads
may run while the private table is still empty. Missing WAN keeps software
routing; it does not cause a reboot loop. Strict operations are briefly refused
while initialization is pending.
Strict installation also requires a recognized native LuCI profile when LuCI
is present; unknown views fail preflight before network configuration changes.

Admission happens after fw4 accepts an original-direction, established IPv4
TCP/UDP packet from `br-lan` to `wan`. Require SNAT, exact conntrack mark
`0x40000000` (the project's saved direct decision), packet mark zero, and no
DNAT. The table is `inet gd_offload`, flowtable `direct`. TUN, IPv6, DNAT,
router-local traffic and additional packet/connection marks are excluded.
Physical hardware binding and revocation have been tested with wired forwarding.
These checks do not measure throughput; Wi-Fi remains unqualified.

Global `flow_offloading` and `flow_offloading_hw` remain zero in **all modes**.
Do not enable the global LuCI checkboxes: that would admit traffic outside this
classifier. LuCI refuses such conflicting edits; fw4 entry points enforce zero.
The nft flowtable retains the kernel's software fallback where a hardware path
cannot be formed. This does not enable broad OpenWrt software offloading.

`--kill-switch` disables the entire private hardware table, including direct
flows. Nonempty pbr/mwan3/SQM/QoS configurations, foreign nft tables/base hooks,
unexpected policy rules or missing project classification use software routing.
This conservative fallback can include an installed but disabled third-party
package. It avoids guessing how an unrelated policy interacts with cached flows.

## Medium

LuCI applies settings through its native mechanism. Critical edits, fw4 changes
and observed route/address/gateway-MAC/configuration changes close **new**
admission and set `/etc/getdomains/offload-reboot-required` to the current boot
ID. A subsequent boot clears the marker and builds fresh objects. Modes with
an already running owner defer installer runtime changes until this reboot.

Closing admission does not revoke existing PPE entries. They can retain an old
egress/NAT/MAC decision or bypass a new firewall restriction after DHCP renewal,
interface failover, gateway replacement or an external policy change. Passive
expiry has no established upper bound. This accepted medium risk also applies
when nobody edits LuCI. A reboot is the reliable reset.

Routine domain/DNS updates intentionally retain an established connection's
direct/VPN classification. A newly learned selected IP affects new connections;
it does not invalidate an existing direct connection. This is the project's
sticky routing contract, not a stale-hardware error. DNS TTL, two-day nft timeout,
shared-CDN addresses and client caches retain the limitations in both READMEs.

## Strict supported changes

Covered pre-change entry points are:

- Native LuCI Save & Apply (checked and unchecked).
- Native interface ifup/ifdown buttons and network/firewall/sing-box service
  start/stop/restart/reload on the patched pages.
- fw4 start/stop/restart/reload/flush/reload-sets through `/sbin/fw4`.
- Root operations explicitly submitted through the controller.
- Install/uninstall transitions, completed by reboot.

Network/firewall/sing-box and third-party routing/shaping UCI packages are
critical. The `wdns` section and unknown DHCP changes are critical. Local
domain/hostrecord/CNAME, dnsmasq address/server and manual DNS IP Sets edits use
the native DNS path; deleted rows are classified from committed UCI.

Do not treat arbitrary direct UCI commits, netifd RPC, shell/nft changes,
package updates or third-party tools as atomic covered entry points. The
observer samples every two seconds and compares routes, WAN addresses, the last
known gateway MAC, relevant files and active base-chain policy. It excludes
learned DNS elements, counters, neighbour reachability/GC, object handles and
table/chain enumeration order. Detected external
changes trigger reconciliation, but some packets can use the earlier decision
between an uncontrolled event and detection. Strict is a controlled-management
contract; it is not hard real-time protection against every external event.

Submit a root operation asynchronously when using LAN management:

```sh
/usr/libexec/getdomains-offload submit /etc/init.d/network reload
/usr/libexec/getdomains-offload status
```

The response gives a PID and private log path. An arbitrary root command is
allowed by this local CLI only; the LuCI endpoint accepts a fixed whitelist and
validated arguments. Direct `transaction COMMAND ...` is synchronous and must
be run by an autonomous local process. Never interpret a lost SSH connection
as successful completion. Reinstallation is the mode-switch interface.

## Barrier and asynchronous apply

1. Serialize the operation and fence it to the live owner's generation.
2. Flush admission and install a forward drop guard. Keep flowtable registered.
3. Flush IPv4 conntrack, remember enabled Ethernet child ports, stop WAN and the
   common Ethernet parent `eth0`.
4. Require two consecutive empty dumps of **both** physical PPEs. Timeout is
   30 sampling iterations; interface/command stalls have an independent deadline.
5. Flush conntrack again under the held barrier, acknowledge the same generation
   and retire the old flowtable through its owner.
6. Apply policy while Ethernet/guard remain held. Recheck the session's pending
   snapshot so concurrent staged edits cannot silently replace the submitted one.
7. Recreate the flowtable with admission empty, release the software guard,
   restore previously enabled ports, and wait for five stable policy samples.
   Native netifd/fw4 events during settling run with confirmed-empty hardware;
   unchanged hotplug reloads do not recursively drain the network again.
8. Open admission only for a supported policy and, for checked apply, **after**
   a valid native confirmation. Unconfirmed rollback leaves acceleration closed
   through automatic callbacks until a successful explicit critical apply/root
   operation or reboot. Deferred fw4 calls wait for a busy physical transaction
   instead of losing the policy reload.

This interrupts wired management/WAN and clears existing IPv4 connections,
including unrelated direct sessions. TCP applications must reconnect. It is
not a seamless per-flow migration. DNS/list refresh does not take this barrier.
Failed drain/flowtable configuration/settling stays closed and requests a reboot; it never
unregisters the old flowtable based only on elapsed time.
An apply/RPC error reconciles the actual policy with hardware quarantined.
A possibly pending checked snapshot keeps its reservation until confirmation
or timeout; failed status publication cannot reopen acceleration.

LuCI POST returns 202 with an opaque job ID. The transport polls through the
expected link interruption and then supplies the native 200/token or 204 result
to `ui.changes`. Native connectivity checks, confirm tokens and rollback remain.
Status reads are session-bound; root-only job files/logs live in RAM. A second
apply, including an empty/DNS apply, and ordinary root submissions are rejected
while checked apply is pending.
Polling does not resubmit a mutation. Jobs do not survive reboot.

## Ownership and failures

The native owner opens one libnftables context and forks an active worker,
standby and an independent keeper with the **same netlink socket**. The table's
`owner,persist` flags prevent unrelated clients from deleting it while a holder
lives. Shared metadata retains the real phase across failover. Mutations require
the current random 64-bit generation; a failure/recovery rotates it.

Single-worker/standby/keeper loss closes admission and degrades the owner.
Strict can replenish holders only after the verified physical barrier. The
independent keeper detects a nonresponsive server, dead supervisor or an
operation older than 180 seconds, quiesces both writers, retains ownership and
requests emergency recovery. Medium instead requires reboot and accepts the
old-flow risk. A supervisor restart conservatively reboots if an old owner
already exists; stopping the strict service can therefore cause a reboot.

Simultaneous loss of every holder and supervisor, a kernel hang/panic or power
loss is outside the userspace single-failure guarantee. A persistent **unowned**
table alone cannot protect hardware teardown. No realtime zero-packet guarantee
is claimed for failures occurring after admission. No driver/firmware changes
are part of this implementation.

Uninstall restores owned LuCI edits and the original fw4 entry point, preserves
unrelated LuCI/UCI edits, removes the module and automatically reboots when an
owner existed. Holders remain alive until reboot; removal does not unregister
an undrained hardware flowtable. Static-lease `wdns` tag references remain.

## Builds and verification

The checked-in aarch64 binary is built with the official OpenWrt 25.12.5
Filogic SDK, gcc 14.3.0/musl. It resolves libnftables' public API with dlopen;
no router library, credential or configuration is embedded. The installer
checks its SHA-256 and API availability before configuration changes. Pin a
full Git commit when downloading a coherent release; the checksum is a
corruption/coherence check, not a separate signing system.

```sh
sh tools/build-offload.sh /path/to/matching-sdk offload/bin/aarch64_cortex-a53/getdomains-offload-owner
sh tools/build-offload-test.sh /path/to/matching-sdk offload/owner-test
python -m unittest discover -s tests -p 'test_*.py'
```

The isolated owner build changes its private socket directory, emergency
callback to a marker file and deadline to three seconds. It runs real kernel ownership/phase/failure tests in
a network namespace and cannot reboot the router. It does not qualify physical
hardware revocation. See [test instructions](../tests/README.md) and reviewed
results under `tests/results` for the exact measured coverage.

Physical direct-SNAT TCP/UDP, sticky domain decisions, supported policy revocation
and LuCI transactions have production-controller tests under `tests/results`.
Before stable hardware support, extend these to mixed physical bidirectional
traffic, interface/MAC/address churn under load, hardware table saturation,
CPU/resource measurements and a 24–72 hour soak. Prototype measurements are not
substitutes for these production-classifier tests. Namespace tests do not
demonstrate PPE forwarding.

Sources: [kernel flowtable behavior](https://docs.kernel.org/networking/nf_flowtable.html),
[Linux 6.12.94 MediaTek driver](https://github.com/gregkh/linux/blob/v6.12.94/drivers/net/ethernet/mediatek/mtk_eth_soc.c),
[nft owner/persist](https://www.netfilter.org/projects/nftables/manpage.html),
[native LuCI UCI controller](https://github.com/openwrt/luci/blob/openwrt-25.12/modules/luci-base/ucode/controller/admin/uci.uc).
