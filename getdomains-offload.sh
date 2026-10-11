#!/bin/sh
# OpenWrt-only controller. Functions above the dispatcher can be host-tested
# with mocked device boundaries. Never run the dispatcher on a development host.
set -eu
umask 0077
GD_DIR=/tmp/getdomains-offload
GD_OWNER=/usr/libexec/getdomains-offload-owner
GD_SELF=/usr/libexec/getdomains-offload

gd_mode() { cat /etc/getdomains/offload-mode 2>/dev/null || printf 'disable\n'; }
gd_boot() { cat /proc/sys/kernel/random/boot_id; }
gd_state() {
    printf '%s\n' "$1" > "$GD_DIR/state.new"
    mv -f "$GD_DIR/state.new" "$GD_DIR/state"
    logger -t getdomains-offload "$1"
}
gd_pending() {
    [ -f /etc/getdomains/offload-reboot-required ] || gd_boot > /etc/getdomains/offload-reboot-required
    gd_state REBOOT_REQUIRED
}
gd_call() { "$GD_OWNER" --client "$1"; }
gd_epoch() {
    answer=$(gd_call EPOCH) || return 1
    case $answer in 'EPOCH '*) answer=${answer#EPOCH };; *) return 1;; esac
    case $answer in ''|*[!0-9]*) return 1;; esac
    printf '%s\n' "$answer"
}
gd_identifier() {
    case $1 in ''|*[!a-zA-Z0-9_.:-]*) return 1;; esac
    [ "${#1}" -le 32 ]
}
gd_supported() {
    [ "$(jsonfilter -i /etc/board.json -e '@.model.id')" = xiaomi,mi-router-ax3000t ] &&
    [ "$(uname -m)" = aarch64 ] && [ "$(uname -r)" = 6.12.94 ] &&
    nft --version | grep -q 'v1.1.6 ' &&
    [ -r /sys/kernel/debug/ppe0/bind ] && [ -r /sys/kernel/debug/ppe1/bind ] &&
    [ -d /sys/class/net/eth0 ] && [ -d /sys/class/net/wan ]
}
gd_empty() {
    [ -r /sys/kernel/debug/ppe0/bind ] && [ -r /sys/kernel/debug/ppe1/bind ] || return 1
    # A failed read must never look like an empty engine through a pipeline.
    ppe_dump=$(cat /sys/kernel/debug/ppe0/bind /sys/kernel/debug/ppe1/bind) || return 1
    if printf '%s\n' "$ppe_dump" | grep -q ' BND '; then
        unset ppe_dump; return 1
    fi
    unset ppe_dump
    return 0
}
gd_software_ok() {
    # A platform with no qualified owner remains on fw4's ordinary path.
    # Missing PPE debugfs is not a reason to reboot an unsupported platform.
    nft list table inet gd_offload >/dev/null 2>&1 && return 1
    # Disk flags alone do not prove the running firewall has no old/foreign
    # cache, particularly between reinstallation and its mandatory reboot.
    flowtables=$(nft -j list flowtables) || return 1
    printf '%s\n' "$flowtables" | ucode -e '
        import { readfile } from "fs";
        let rules = json(readfile("/dev/stdin"));
        if (type(rules?.nftables) != "array") exit(1);
        for (let row in rules.nftables) if (row.flowtable) exit(1);
    ' || return 1
    [ "$(uci -q get firewall.@defaults[0].flow_offloading || true)" = 0 ] &&
    [ "$(uci -q get firewall.@defaults[0].flow_offloading_hw || true)" = 0 ] || return 1
    [ ! -r /sys/kernel/debug/ppe0/bind ] || gd_empty
}
gd_kill_switch() { [ "$(uci -q get network.domain_kill_switch.action || true)" = unreachable ]; }
gd_safe_policy() {
    case $(gd_mode) in medium|strict) ;; *) return 1;; esac
    [ ! -f /etc/getdomains/offload-reboot-required ] && [ ! -f "$GD_DIR/maintenance" ] &&
    [ ! -f "$GD_DIR/rolled-back" ] || return 1
    [ "$(uci -q get firewall.@defaults[0].flow_offloading || true)" = 0 ] &&
    [ "$(uci -q get firewall.@defaults[0].flow_offloading_hw || true)" = 0 ] || return 1
    gd_kill_switch && return 1
    if [ "$(gd_mode)" = strict ] && [ -f /www/luci-static/resources/ui.js ]; then
        grep -q 'getdomains offload lifecycle wrapper' /sbin/fw4 || return 1
        ucode /usr/libexec/getdomains-offload-setup.uc check || return 1
    fi
    # Do not guess how foreign policy routing or traffic shaping interacts with
    # this cache. Unrecognized configurations continue on the ordinary path.
    policy_rules=$(ip -4 rule show) || return 1
    printf '%s\n' "$policy_rules" | awk '
        /^(0:[[:space:]]+from all lookup local|32766:[[:space:]]+from all lookup main|32767:[[:space:]]+from all lookup default)$/ { next }
        /^79:[[:space:]]+from all to [0-9.]+ unreachable$/ { next }
        /^80:[[:space:]]+from all to [0-9.]+ lookup vpn$/ { next }
        /^81:[[:space:]]+from all to [0-9.]+ unreachable$/ { next }
        /^90:[[:space:]]+from all oif tun0 lookup vpn$/ { next }
        /^100:[[:space:]]+from all fwmark 0x1\/0x1 lookup vpn$/ { next }
        { bad=1 } END { exit bad }' || return 1
    for package in pbr mwan3 sqm qos; do
        [ ! -s "/etc/config/$package" ] || return 1
    done
    # A later base chain could reject a packet after flow-add had cached it.
    # Unknown tables/hooks are therefore a software-only configuration.
    tables=$(nft list tables) || return 1
    printf '%s\n' "$tables" | awk '$0 == "table inet fw4" || $0 == "table inet gd_offload" { next } { bad=1 } END { exit bad }' || return 1
    chains=$(nft -j list chains) || return 1
    printf '%s\n' "$chains" | ucode -e '
        import { readfile } from "fs";
        let rules = json(readfile("/dev/stdin"));
        let allowed = {
            raw_prerouting: ["prerouting", -300], raw_output: ["output", -300],
            mangle_prerouting: ["prerouting", -150], mangle_input: ["input", -150],
            mangle_forward: ["forward", -150], mangle_output: ["output", -150],
            mangle_postrouting: ["postrouting", -150], dstnat: ["prerouting", -100],
            srcnat: ["postrouting", 100], prerouting: ["prerouting", 0],
            input: ["input", 0], forward: ["forward", 0], output: ["output", 0]
        };
        if (type(rules?.nftables) != "array") exit(1);
        for (let row in rules.nftables) {
            let c = row.chain;
            if (!c?.hook) continue;
            if (c.family != "inet") exit(1);
            let expected = c.table == "fw4" ? allowed[c.name] :
                c.table == "gd_offload" && c.name == "guard" ? ["forward", -400] :
                c.table == "gd_offload" && c.name == "forward" ? ["forward", 10] : null;
            if (!expected || c.hook != expected[0] || c.prio != expected[1]) exit(1);
            let kind = c.table == "fw4" && (c.name == "dstnat" || c.name == "srcnat") ? "nat" :
                c.table == "fw4" && c.name == "mangle_output" ? "route" : "filter";
            if (c.type != kind) exit(1);
        }
    ' || return 1
    nft list chain inet fw4 mangle_prerouting | grep -q 'getdomains: save connection route direct' || return 1
    nft list chain inet fw4 forward >/dev/null || return 1
}
gd_fingerprint() {
    # Exclude learned DNS set elements, traffic counters and neighbour states.
    # Their ordinary churn must not disconnect existing sticky connections.
    {
        ip -4 rule show
        ip -4 route show table all
        ip -o -4 addr show dev wan | awk '{ print $2, $4 }'
        for gateway in $(ip -4 route show table main default | awk '/^default via/ { print $3 }'); do
            gd_identifier "$gateway" || continue
            mac=$(ip -4 neigh show to "$gateway" dev wan | awk '{ for (i=1;i<=NF;i++) if ($i=="lladdr") print $(i+1) }')
            # Neighbour cache GC/REACHABLE->STALE does not change a forwarding
            # decision. Keep the last known MAC; a different MAC is critical.
            if [ -n "$mac" ]; then printf '%s\n' "$mac" > "$GD_DIR/gateway.$gateway"; fi
            cat "$GD_DIR/gateway.$gateway" 2>/dev/null || true
        done
        for file in /etc/config/network /etc/config/firewall /etc/config/sing-box /etc/config/pbr /etc/config/mwan3 /etc/config/sqm /etc/config/qos /etc/sing-box/config.json /sbin/fw4; do
            [ ! -f "$file" ] || sha256sum "$file"
        done
        nft list tables | sort
        # Handles and table creation order change on an otherwise identical
        # fw4 reload. Keep semantic chain attributes in a canonical order.
        nft -j list chains | ucode -e '
            import { readfile } from "fs";
            let rows = json(readfile("/dev/stdin")), parts = [];
            for (let row in rows.nftables) {
                let c = row.chain;
                if (!c) continue;
                push(parts, sprintf("%J", { family: c.family, table: c.table,
                    name: c.name, type: c.type, hook: c.hook, prio: c.prio,
                    policy: c.policy, dev: c.dev }));
            }
            for (let part in sort(parts)) printf("%s\n", part);
        '
        for chain in forward mangle_prerouting mangle_output srcnat dstnat; do
            nft -s list chain inet fw4 "$chain" 2>/dev/null || true
        done
    } | sha256sum | cut -d' ' -f1
}
gd_render() {
    lan=$(ubus call network.interface.lan status | jsonfilter -e '@.l3_device')
    [ "$lan" = br-lan ] || return 1
    ports=
    for port in $(jsonfilter -i /etc/board.json -e '@.network.lan.ports[*]') wan; do
        gd_identifier "$port" || return 1
        [ -d "/sys/class/net/$port" ] || continue
        ports="${ports}${ports:+, }\"$port\""
    done
    [ -n "$ports" ] || return 1
    cat > "$GD_DIR/policy.nft" <<EOF
add flowtable inet gd_offload direct { hook ingress priority 0; devices = { $ports }; flags offload; }
EOF
    cat > "$GD_DIR/initial.nft" <<'EOF'
add table inet gd_offload { flags owner,persist; }
add chain inet gd_offload admission
add chain inet gd_offload guard { type filter hook forward priority -400; policy accept; }
add chain inet gd_offload forward { type filter hook forward priority 10; policy accept; }
add rule inet gd_offload forward jump admission
EOF
    cat "$GD_DIR/policy.nft" >> "$GD_DIR/initial.nft"
    # fw4 has already accepted these packets. Require the project's explicit
    # DIRECT conntrack classification, SNAT and the normal WAN path. Other
    # packet/conntrack marks, IPv6, DNAT and TUN are never admitted.
    cat > "$GD_DIR/admission.nft" <<'EOF'
flush chain inet gd_offload admission
add rule inet gd_offload admission ct status dnat return
add rule inet gd_offload admission meta nfproto ipv4 iifname "br-lan" oifname "wan" ct direction original ct state established ct status snat ct mark 0x40000000 meta mark 0 meta l4proto { tcp, udp } counter flow add @direct comment "getdomains: direct NAT offload"
EOF
}
gd_snapshot_ports() {
    : > "$GD_DIR/ports"
    index=$(cat /sys/class/net/eth0/ifindex)
    for link in /sys/class/net/*/iflink; do
        [ "$(cat "$link")" = "$index" ] || continue
        dev=${link%/iflink}; dev=${dev##*/}
        [ "$dev" != eth0 ] || continue
        gd_identifier "$dev" || return 1
        if ip link show dev "$dev" | grep -q '<.*[,<]UP[,>]'; then
            printf '%s\n' "$dev" >> "$GD_DIR/ports"
        fi
    done
}
gd_ct_clear() {
    # Critical changes intentionally disconnect all forwarded IPv4 TCP/UDP
    # sessions. Full-family flush also removes software decisions recreated
    # during the first deletion. IPv6 has never entered our flowtable.
    code=0
    conntrack -F -f ipv4 > "$GD_DIR/conntrack.log" 2>&1 || code=$?
    [ "$code" = 0 ]
}
gd_prepare() {
    gd_state PREPARING || return 1
    gd_call HOLD >/dev/null || return 1
    epoch=$(gd_epoch) || return 1
    gd_ct_clear || return 1
    gd_snapshot_ports || return 1
    ip link set dev wan down || return 1
    ip link set dev eth0 down || return 1
    gd_state DRAINING
    stable=0 count=0
    while [ "$count" -lt 30 ]; do
        if gd_empty; then stable=$((stable+1)); else stable=0; fi
        [ "$stable" -lt 2 ] || break
        sleep 1; count=$((count+1))
    done
    [ "$stable" -ge 2 ] || return 1
    # Close the CT recreation race while links and the software guard are held.
    gd_ct_clear || return 1
    [ "$epoch" = "$(gd_epoch)" ] || return 1
    printf '%s\n' "$epoch" > "$GD_DIR/drained"
    gd_call RETIRE >/dev/null || return 1
    gd_state HELD
}
gd_restore_links() {
    ip link set dev eth0 up || return 1
    while IFS= read -r dev; do
        gd_identifier "$dev" || return 1
        ip link set dev "$dev" up || return 1
    done < "$GD_DIR/ports"
}
gd_settle() {
    # Bringing WAN back generates netifd/fw4 events. Keep admission closed while
    # those events complete, avoiding a barrier -> ifup -> barrier loop.
    previous=$(gd_fingerprint)
    stable=0 count=0
    while [ "$count" -lt 30 ]; do
        sleep 1
        current=$(gd_fingerprint)
        if [ "$current" = "$previous" ]; then stable=$((stable+1)); else stable=0; fi
        previous=$current; count=$((count+1))
        [ "$stable" -lt 5 ] || break
    done
    [ "$stable" -ge 5 ] || return 1
    printf '%s\n' "$current" > "$GD_DIR/policy.fingerprint"
    if [ ! -f "$GD_DIR/await-confirm" ] && gd_safe_policy; then
        gd_render || return 1
        gd_call OPEN >/dev/null || return 1
    fi
    rm -f "$GD_DIR/settling"
}

gd_boot_settle() {
    # No entry has ever been admitted in this boot. Late native netifd/fw4
    # callbacks may run normally while the private flowtable remains empty.
    gd_state STARTING
    previous=$(gd_fingerprint)
    stable=0 count=0
    while [ "$count" -lt 60 ]; do
        sleep 1
        current=$(gd_fingerprint)
        ready=$(ubus call network.interface.wan status | jsonfilter -e '@.up')
        if [ "$ready" = true ] && [ "$current" = "$previous" ] &&
            ip -4 route show table main default | grep -q 'dev wan'; then
            stable=$((stable+1))
        else stable=0; fi
        previous=$current; count=$((count+1))
        [ "$stable" -lt 5 ] || break
    done
    printf '%s\n' "$current" > "$GD_DIR/policy.fingerprint"
    rm -f "$GD_DIR/boot-settling"
    if [ "$stable" -ge 5 ] && gd_safe_policy; then
        gd_empty && gd_call OPEN >/dev/null || return 1
        gd_state READY
    else gd_state SOFTWARE_STARTUP; fi
}
gd_resume() {
    gd_state POLICY_APPLIED
    gd_render || return 1
    if gd_call STATUS | grep -q ' DEGRADED '; then gd_call RECOVER >/dev/null || return 1; fi
    gd_call CONFIGURE >/dev/null || return 1
    # A changed policy may make acceleration unsupported. Removing the guard
    # remains necessary, but admission must stay empty in that case.
    printf 'flush chain inet gd_offload admission\n' > "$GD_DIR/admission.nft"
    touch "$GD_DIR/settling"
    gd_call RELEASE >/dev/null || return 1
    gd_restore_links || return 1
    gd_settle || return 1
    if [ -f "$GD_DIR/await-confirm" ]; then gd_state AWAIT_CONFIRM
    elif [ -f "$GD_DIR/rolled-back" ]; then gd_state SOFTWARE_AFTER_ROLLBACK
    elif gd_safe_policy; then gd_state READY
    else gd_state SOFTWARE_POLICY; fi
    rm -f "$GD_DIR/drained"
}
gd_fail() {
    gd_state FAILED_REBOOTING || true
    # Keep the registered table and stopped links on an unconfirmed drain.
    if gd_supported; then ip link set dev eth0 down || true; fi
    sync || true
    reboot || true
    return 1
}
gd_lock() {
    attempts=0
    while ! mkdir "$GD_DIR/transaction.lock" 2>/dev/null; do
        [ "${GD_OFFLOAD_FW4_CALLBACK:-}" = 1 ] || return 1
        attempts=$((attempts+1))
        [ "$attempts" -lt 180 ] || { gd_fail; return 1; }
        sleep 1
    done
    printf '%s\n' "${1:-$$}" > "$GD_DIR/transaction.lock/pid"
    cut -d. -f1 /proc/uptime > "$GD_DIR/transaction.lock/start"
}
gd_unlock() { rm -f "$GD_DIR/transaction.lock/pid" "$GD_DIR/transaction.lock/start"; rmdir "$GD_DIR/transaction.lock"; }
gd_unreserve() { rm -f "$GD_DIR/submission.lock/start"; rmdir "$GD_DIR/submission.lock" 2>/dev/null || true; }
gd_submission_overdue() {
    if [ ! -d "$GD_DIR/submission.lock" ] || [ -f "$GD_DIR/await-confirm" ]; then
        rm -f "$GD_DIR/submission.observed"; return 1
    fi
    started=$(cat "$GD_DIR/submission.lock/start" 2>/dev/null || true)
    case $started in ''|*[!0-9]*)
        # Worker death between mkdir and deadline publication is bounded too.
        [ -f "$GD_DIR/submission.observed" ] || cut -d. -f1 /proc/uptime > "$GD_DIR/submission.observed"
        started=$(cat "$GD_DIR/submission.observed")
        ;;
    esac
    [ "$(( $(cut -d. -f1 /proc/uptime) - started ))" -ge 180 ]
}
gd_transaction() {
    # Root CLI wrapper. An inherited marker is only trusted while its owning
    # transaction lock exists. LuCI accepts only fixed, validated operations.
    if [ "${GD_OFFLOAD_TRANSACTION:-}" = 1 ] && [ -d "$GD_DIR/transaction.lock" ]; then "$@"; return; fi
    if [ "$(gd_mode)" != strict ] || [ ! -S "$GD_DIR/owner.sock" ]; then
        if [ "$(gd_mode)" = strict ] && ! gd_software_ok; then gd_fail; return 1; fi
        if [ -S "$GD_DIR/owner.sock" ]; then
            gd_pending
            gd_call CLOSE >/dev/null
        fi
        "$@"
        return
    fi
    # Distinguish a competing transaction from a failed barrier. The observer
    # can lose the race between its lock check and this atomic mkdir; it must
    # retry later instead of rebooting a correctly running LuCI job.
    gd_lock || return 75
    # A detached process is required if the command is submitted over LAN.
    trap 'gd_fail; exit 1' HUP INT TERM
    gd_prepare || { gd_fail; return 1; }
    code=0
    GD_OFFLOAD_TRANSACTION=1 "$@" || code=$?
    if [ "$code" = 0 ] && [ "${GD_OFFLOAD_EXPLICIT:-}" = 1 ]; then rm -f "$GD_DIR/rolled-back"; fi
    # On command failure still reconcile the actual policy under the barrier.
    gd_resume || { gd_fail; return 1; }
    gd_unlock
    trap - HUP INT TERM
    return "$code"
}
gd_prepare_job() {
    GD_OFFLOAD_FW4_CALLBACK=1 gd_lock "$PPID" || return 1
    if [ ! -S "$GD_DIR/owner.sock" ]; then
        gd_software_ok || { gd_fail; return 1; }
        touch "$GD_DIR/software-job"
    else
        gd_prepare || { gd_fail; return 1; }
    fi
    # rpcd's configuration event children do not inherit the job environment.
    # Authorize fw4 only while the physical barrier/software guard is held.
    touch "$GD_DIR/permit-fw4"
}
gd_resume_job() {
    # Allow rpcd's deferred reload events to start; late fw4 calls still pass
    # through the wrapper and acquire their own barrier after this one ends.
    sleep 3
    if [ -f "$GD_DIR/software-job" ]; then rm -f "$GD_DIR/software-job"
    else gd_resume || { gd_fail; return 1; }; fi
    rm -f "$GD_DIR/permit-fw4"
    gd_unlock
    [ ! -f "$GD_DIR/await-confirm" ] || gd_state AWAIT_CONFIRM
}
gd_confirmed() {
    [ -f "$GD_DIR/await-confirm" ] || return 1
    if [ -S "$GD_DIR/owner.sock" ]; then
        gd_render
        if [ ! -f "$GD_DIR/settling" ] && gd_safe_policy; then gd_call OPEN >/dev/null; fi
    fi
    rm -f "$GD_DIR/await-confirm"
    gd_unreserve
    if [ -f /etc/getdomains/offload-reboot-required ]; then gd_state REBOOT_REQUIRED
    elif [ -S "$GD_DIR/owner.sock" ] && gd_safe_policy; then gd_state READY
    else gd_state SOFTWARE_POLICY; fi
}
gd_status() {
    printf 'mode=%s\nstate=%s\n' "$(gd_mode)" "$(cat "$GD_DIR/state" 2>/dev/null || printf STOPPED)"
    if [ -f /etc/getdomains/offload-reboot-required ]; then printf 'reboot_required=1\n'; else printf 'reboot_required=0\n'; fi
    [ ! -S "$GD_DIR/owner.sock" ] || gd_call STATUS
}
gd_submit() {
    [ ! -f "$GD_DIR/boot-settling" ] || { printf 'Offload is initializing; retry later\n' >&2; return 75; }
    [ ! -d "$GD_DIR/submission.lock" ] || { printf 'Another LuCI apply is pending\n' >&2; return 1; }
    mkdir -p "$GD_DIR/jobs"
    id=$(hexdump -n 16 -e '16/1 "%02x"' /dev/urandom)
    setsid "$GD_SELF" transaction "$@" > "$GD_DIR/jobs/cli-$id.log" 2>&1 </dev/null &
    printf 'pid=%s\nlog=%s/jobs/cli-%s.log\n' "$!" "$GD_DIR" "$id"
}
gd_requested_transaction() {
    [ ! -f "$GD_DIR/boot-settling" ] || return 75
    # Ordinary root submissions must not race a checked LuCI rollback snapshot.
    # Its deferred fw4 callbacks still need the barrier to finish that rollback.
    if [ "${GD_OFFLOAD_FW4_CALLBACK:-}" != 1 ] && [ -d "$GD_DIR/submission.lock" ]; then
        printf 'Another LuCI apply is pending\n' >&2; return 1
    fi
    if [ "${GD_OFFLOAD_FW4_CALLBACK:-}" = 1 ]; then gd_transaction "$@"
    else GD_OFFLOAD_EXPLICIT=1 gd_transaction "$@"; fi
}
gd_detached_transaction() {
    # Native fw4 callers may be an SSH session interrupted by the barrier.
    # Only the waiting caller may disappear; the device operation must finish.
    log="$GD_DIR/fw4.$$.log"
    GD_OFFLOAD_FW4_CALLBACK=1 setsid "$GD_SELF" transaction "$@" > "$log" 2>&1 </dev/null &
    code=0; wait "$!" || code=$?
    cat "$log"; rm -f "$log"
    return "$code"
}
gd_watch() {
    mkdir -p "$GD_DIR/jobs"
    chmod 0700 "$GD_DIR" "$GD_DIR/jobs"
    printf '%s\n' "$$" > "$GD_DIR/supervisor.pid"
    mode=$(gd_mode)
    case $mode in medium|strict|disable) ;; *) gd_state INVALID_MODE; return 1;; esac
    if [ -f /etc/getdomains/offload-reboot-required ]; then
        if [ "$(cat /etc/getdomains/offload-reboot-required)" = "$(gd_boot)" ]; then
            gd_state REBOOT_REQUIRED; while :; do sleep 60; done
        fi
        rm -f /etc/getdomains/offload-reboot-required
    fi
    if [ "$mode" = disable ]; then gd_state DISABLED; while :; do sleep 60; done; fi
    if gd_kill_switch; then gd_state DISABLED_KILL_SWITCH; while :; do sleep 60; done; fi
    if ! gd_supported; then gd_state UNSUPPORTED_PLATFORM; while :; do sleep 60; done; fi
    if [ -S "$GD_DIR/owner.sock" ] || ! gd_empty; then gd_fail; return 1; fi
    gd_render || { gd_state UNSUPPORTED_TOPOLOGY; return 1; }
    touch "$GD_DIR/boot-settling"
    "$GD_OWNER" --serve >> "$GD_DIR/owner.log" 2>&1 &
    owner=$!
    count=0
    while ! gd_call STATUS >/dev/null 2>&1; do
        count=$((count+1)); [ "$count" -lt 10 ] || { gd_fail; return 1; }; sleep 1
    done
    # Resolve the gateway before opening the first hardware decision, so its
    # initial ARP resolution does not look like a later MAC replacement.
    for gateway in $(ip -4 route show table main default | awk '/^default via/ { print $3 }'); do
        ping -c 1 -W 1 "$gateway" >/dev/null 2>&1 || true
    done
    gd_boot_settle || { gd_fail; return 1; }
    while :; do
        sleep 2
        [ ! -f "$GD_DIR/maintenance" ] || continue
        # A detached worker can die before acquiring the physical lock. Do not
        # leave LuCI blocked forever or assume its partially applied policy.
        gd_submission_overdue && gd_fail
        # This independent supervisor remains alive if all socket holders die.
        # It cannot promise instantaneous revocation of already accelerated
        # packets after a simultaneous failure; that boundary is documented.
        if [ -d "$GD_DIR/transaction.lock" ]; then
            pid=$(cat "$GD_DIR/transaction.lock/pid" 2>/dev/null || true)
            case $pid in ''|*[!0-9]*) gd_fail;; *) kill -0 "$pid" 2>/dev/null || gd_fail;; esac
            started=$(cat "$GD_DIR/transaction.lock/start")
            [ "$(( $(cut -d. -f1 /proc/uptime) - started ))" -lt 180 ] || gd_fail
            continue
        fi
        if [ -f "$GD_DIR/await-confirm" ] && [ "$(date +%s)" -gt "$(cat "$GD_DIR/await-confirm")" ]; then
            gd_call CLOSE >/dev/null || true
            touch "$GD_DIR/rolled-back"
            rm -f "$GD_DIR/await-confirm"
            gd_unreserve
            gd_state SOFTWARE_AFTER_ROLLBACK
        fi
        status=$(gd_call STATUS 2>/dev/null || true)
        case $status in *' OK '*) ;; *)
            if [ "$mode" = strict ]; then
                # Single-holder failures retain ownership; replenish only under
                # the same verified physical barrier used for policy changes.
                case $status in *' DEGRADED '*)
                    reconcile_code=0
                    gd_transaction /bin/true || reconcile_code=$?
                    [ "$reconcile_code" != 75 ] || continue
                    [ "$reconcile_code" = 0 ] || gd_fail
                    ;;
                    *) gd_fail;;
                esac
            else gd_pending; fi
            ;;
        esac
        current=$(gd_fingerprint)
        if [ "$current" != "$(cat "$GD_DIR/policy.fingerprint")" ]; then
            if [ "$mode" = strict ]; then
                reconcile_code=0
                gd_transaction /bin/true || reconcile_code=$?
                [ "$reconcile_code" != 75 ] || continue
                [ "$reconcile_code" = 0 ] || gd_fail
            else gd_pending; gd_call CLOSE >/dev/null 2>&1 || true; fi
            gd_fingerprint > "$GD_DIR/policy.fingerprint"
        fi
        if ! gd_safe_policy; then gd_call CLOSE >/dev/null 2>&1 || true; fi
    done
}

# Device dispatcher: never sourced by host-safe tests.
case ${1:-} in
    watch) gd_watch;;
    status) gd_status;;
    software-ok) gd_software_ok;;
    pending)
        mkdir -p "$GD_DIR"; gd_pending
        [ ! -S "$GD_DIR/owner.sock" ] || gd_call CLOSE >/dev/null
        ;;
    transaction) shift; [ "$#" -gt 0 ] || exit 2; gd_requested_transaction "$@";;
    submit) shift; [ "$#" -gt 0 ] || exit 2; gd_submit "$@";;
    before-fw4)
        shift
        case ${1:-} in start|stop|restart|reload|flush|reload-sets)
            for option in flow_offloading flow_offloading_hw; do
                if [ "$(uci -q get "firewall.@defaults[0].$option" || true)" != 0 ]; then
                    uci set "firewall.@defaults[0].$option=0"
                    uci commit firewall
                fi
            done
            ;;
        esac
        if [ -f "$GD_DIR/boot-settling" ] && gd_empty; then
            exec /etc/getdomains/fw4.original "$@"
        fi
        if [ -f "$GD_DIR/permit-fw4" ] && [ -d "$GD_DIR/transaction.lock" ]; then
            if [ -f "$GD_DIR/software-job" ] || gd_call STATUS | grep -q '^RETIRED ' ||
                { [ -f "$GD_DIR/settling" ] && gd_empty; }; then
                exec /etc/getdomains/fw4.original "$@"
            fi
            exit 1
        fi
        if [ -d "$GD_DIR/transaction.lock" ] && [ -f "$GD_DIR/settling" ] && gd_empty; then
            exec /etc/getdomains/fw4.original "$@"
        fi
        # An unchanged hotplug reload does not change forwarding policy. The
        # private owner survives fw4 reloads; learned DNS membership is sticky.
        case ${ACTION:-} in ifup|ifupdate)
            if [ "${1:-}" = reload ] && [ -f "$GD_DIR/policy.fingerprint" ] &&
                [ "$(gd_fingerprint)" = "$(cat "$GD_DIR/policy.fingerprint")" ]; then
                exec /etc/getdomains/fw4.original "$@"
            fi;;
        esac
        case ${1:-} in start|stop|restart|reload|flush|reload-sets)
            if [ "$(gd_mode)" = strict ] && [ -S "$GD_DIR/owner.sock" ] && [ "${GD_OFFLOAD_TRANSACTION:-}" != 1 ]; then
                gd_detached_transaction /etc/getdomains/fw4.original "$@"
            else gd_transaction /etc/getdomains/fw4.original "$@"; fi
            ;;
            *) exec /etc/getdomains/fw4.original "$@";; esac
        ;;
    prepare-job) gd_prepare_job;;
    resume-job|recover-job) gd_resume_job;;
    confirmed) gd_confirmed;;
    emergency)
        if [ "$(gd_mode)" = strict ] && [ ! -f "$GD_DIR/maintenance" ]; then
            ip link set dev eth0 down || true
            gd_fail
        else gd_pending; fi
        ;;
    job) [ "$#" = 2 ] || exit 2; exec ucode /usr/libexec/getdomains-offload-job.uc "$2";;
    *) printf 'Usage: getdomains-offload status|submit COMMAND [ARG...]|transaction COMMAND [ARG...]\n' >&2; exit 2;;
esac
