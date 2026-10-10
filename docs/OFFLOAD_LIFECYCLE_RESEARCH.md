# Offload lifecycle research

Research fixtures on `codex/offload-lifecycle-prototype`, based on master
`18dba24ebfef8f166de84dda96a00fe182908fa2`. The installer and runtime do not
install these fixtures. Production flow offloading remains disabled.

The objective is to qualify three prerequisites before implementing a service:
physical revocation, preparation before configuration changes, and continued
ownership after a single controller-process failure. No driver or firmware
changes are part of this approach.

## Physical revocation

Closing an nft admission chain stops new `flow add` operations. It does not
revoke packets already forwarded by the hardware. Deleting conntrack is also
insufficient evidence: verify physical PPE BND records and independently
transmitted packets in both directions. Keep the owning flowtable registered
until hardware revocation completes; deleting it early can sever the teardown
relationship needed to clean up hardware entries.

On the tested Filogic device, stopping only WAN was not sufficient. A fresh
eight-flow UDP experiment retained six BND entries at 45 seconds. Earlier
small-flow successes therefore do not establish a bounded WAN-only barrier.

The stronger prototype performs:

1. Acquire a preparation lock, verify the owner and close admission.
2. Delete each exact test conntrack tuple while its flowtable remains registered.
3. Generate private veth device-down events and stop WAN.
4. Stop the common Ethernet parent `eth0`, retaining the list of previously
   enabled child ports for restoration.
5. Require two consecutive empty dumps of both physical PPE tables.
6. Delete the flowtable through its owner while Ethernet is still stopped.
7. Restore Ethernet and its previously enabled ports, then WAN.
8. Only then permit the harness to change policy and test new traffic.

The separate `--hold-through-policy` experiment splits the last steps into two
phases: preparation leaves Ethernet down, a detached local actor applies the
new lab guard, and `offload-resume.sh` restores links only from `POLICY_APPLIED`.
This avoids recreating software conntrack between restoration and the new
policy. Neither phase is a production RPC API or a durable commit token.

This is deliberately platform-specific. It interrupts wired LAN management and
WAN, and can destroy every current TCP connection. Run it as an autonomous
local operation, with a recovery watchdog. An SSH/HTTP request that drops during
the operation is not its completion acknowledgement. The load harness retries
only status reads, checks that the boot ID did not change, and rejects watchdog
reboots as successful live revocation.

On timeout, admission remains closed and the flowtable remains registered;
interfaces already stopped remain stopped. The lab watchdog restores the saved
configuration and reboots. A production fallback must preserve this safety
ordering and explicitly report the loss of connectivity.

`conntrack` 1.4.8 accepted a `first:last` source-port filter but selected only
the first port in the initial experiment. The corrected fixture deletes exact
ports individually. This is a measured tooling limitation, not a conclusion
about conntrack deletion for an entire address or zone.

The driver source supports investigating the common-parent stop: the MediaTek
stop path stops DMA/PPE when the last MAC user closes. That is an explanation
for the observations, not a portable hardware-deletion acknowledgement.
[Linux 6.12.94 driver](https://github.com/gregkh/linux/blob/v6.12.94/drivers/net/ethernet/mediatek/mtk_eth_soc.c),
[flowtable documentation](https://docs.kernel.org/networking/nf_flowtable.html).

## Pre-change integration

The native LuCI unchecked handler commits UCI packages before calling apply.
UCI change notifications and firewall script includes therefore arrive too late
for a universal pre-commit barrier.
[LuCI handler](https://github.com/openwrt/luci/blob/openwrt-25.12/modules/luci-base/ucode/controller/admin/uci.uc),
[rpcd UCI backend](https://github.com/openwrt/rpcd/blob/master/uci.c).

The separate experimental LuCI controller overrides two menu actions and
delegates to the unchanged native handler after preparation. It preserves the
native authentication, POST requirements and checked-apply rollback mechanism.
Pending firewall/network changes and changes to the named `wdns` section are
critical in this limited fixture. Ordinary DNS changes take the native path.
The synchronous callback is instrumented with hardware disabled to isolate
ordering from physical interruption.

A temporary wrapper additionally guards native fw4 start/stop/restart/reload/
flush/reload-sets before invoking the original program. This is an experiment
with a userspace integration point, not a supported fw4 extension. Package
updates, restoration and alternate entry points need an explicit design.

Direct UCI RPC commits bypass the LuCI pre-commit hook. Direct netifd network
RPC, shell edits and changes to sing-box likewise require their own contracts
or exclusion from the supported management surface. A post-change monitor
cannot turn these paths into an atomic pre-change operation.
[netifd RPC implementation](https://github.com/openwrt/netifd/blob/master/ubus.c).

The prototype classifier is intentionally incomplete: arbitrary DHCP options,
multi-instance dnsmasq, interface renames and external policy managers are not
qualified. A production implementation needs normalized policy comparison,
not a rule that every DNS modification is harmless.

## Process ownership and stale requests

The C fixture creates an `owner,persist` nft table and forks a standby after
opening the libnftables context. Both processes retain the same netlink socket,
so loss of the active worker does not relinquish ownership. The standby closes
admission before accepting commands on the inherited root-only UNIX socket.
If the standby dies first, the worker closes admission and can replace it.
[nftables owner/persist semantics](https://www.netfilter.org/projects/nftables/manpage.html).

Each mutation carries a random 64-bit epoch. Worker failover or standby loss
rotates the epoch. Queued commands from an old generation are rejected rather
than reopening admission after a crash. The lab client fetches the epoch before
each mutation; raw wire mode exists only for fault injection.

This protects the tested single-process failures. Simultaneous loss of both
processes is a negative control: the persistent table survives but becomes
unowned, and another process can delete it. The raw lab NFT command channel,
manual recovery, lack of a procd supervisor and incomplete state machine make
this unsuitable as a production daemon.

## Production acceptance still required

- An accepted policy for the common-Ethernet interruption, or a separately
  qualified, less disruptive physical barrier. WAN-only drain is unqualified.
- An asynchronous preparation token/state protocol for LuCI, because the
  physical barrier can interrupt the HTTP client that requested it.
- Coverage or explicit exclusion of every policy-changing entry point,
  including rollback, netifd, sing-box, install/uninstall and watchdog recovery.
- A durable policy generation and strict transition state machine; raw NFT
  commands must be replaced by validated operations.
- Explicit software conntrack semantics across the held-link commit: entries
  can be recreated while the initial batch is being deleted. Qualify deletion
  under the final barrier and preserve only decisions permitted by the new
  policy, rather than inferring this from a lab guard that always drops.
- A defined response to both-process failure, OOM and owner initialization
  failure before hardware admission. Persisted nft state alone is insufficient.
- Extended randomized TCP/UDP and mixed-load tests, reboots, hardware table
  saturation, interface churn, IPv6, loss of management and long observations.
- Qualification of admission for direct IPv4 NAT only, excluding tunnel,
  marked/special-policy and kill-switch flows. These fixtures exercise scoped
  direct NAT traffic; they do not implement that full production classifier.

The [target report](../tests/results/offload-lifecycle-2026-10-10.md) records
measured coverage and limitations. An empty PPE dump and several successful
tests are evidence on this device, not a guarantee for other drivers or boards.
