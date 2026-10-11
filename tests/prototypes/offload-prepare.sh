#!/bin/sh
# Destructive Filogic research fixture. Not installed by getdomains.
# Arguments: owner socket WAN table proto LAN router first-port last-port timeout.
set -eu
[ "${GETDOMAINS_ALLOW_DESTRUCTIVE_TESTS:-}" = 1 ] || exit 2
[ "$#" = 10 ] || exit 2
owner=$1 socket=$2 wan=$3 table=$4 proto=$5 lan=$6 router=$7 first=$8 last=$9
shift 9
deadline=$1
work=/tmp/gd-life-lab
mkdir "$work/prepare.lock" || exit 1
cleanup() {
    code=$?
    if [ "$code" -ne 0 ]; then printf 'FAILED\n' > "$work/state"; fi
    rmdir "$work/prepare.lock"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
clock() { cut -d. -f1 /proc/uptime; }
start=$(clock)
case "$proto" in tcp|udp) ;; *) exit 2 ;; esac
case "$deadline" in ''|*[!0-9]*) exit 2 ;; esac
# The harness supplies all arguments. This raw fixture has no public RPC API.
status=$("$owner" --client "$socket" STATUS)
case "$status" in 'ACTIVE OK '*|'HELD OK '*) ;; *) exit 1 ;; esac
nft list table inet "$table" | grep -q 'flags owner,persist'
printf 'CLOSING\n' > "$work/state"
"$owner" --client "$socket" "NFT flush chain inet $table admission"
# Keep the flowtable registered during conntrack deletion and NETDEV_DOWN.
# conntrack 1.4.8 accepts "first:last" syntactically but filters only first!
# Delete each exact port rather than trusting apparent range support.
port=$first
while [ "$port" -le "$last" ]; do
    set +e
    conntrack -D -p "$proto" -s "$lan" -d "$router" --sport "$port"
    code=$?
    set -e
    [ "$code" -le 1 ] || exit 1
    port=$((port+1))
done
for pass in 1 2 3; do
    ip link set dev gd-life-sync0 up
    ip link set dev gd-life-sync0 down
done
ip link set dev "$wan" down
parent=${GD_LIFE_STOP_PARENT:-}
if [ -n "$parent" ]; then
    [ "$parent" = eth0 ] || exit 2
    : > "$work/restore-ports"
    parent_index=$(cat "/sys/class/net/$parent/ifindex")
    for link in /sys/class/net/*/iflink; do
        [ "$(cat "$link")" = "$parent_index" ] || continue
        dev=${link%/iflink}; dev=${dev##*/}
        [ "$dev" != "$parent" ] || continue
        if ip link show dev "$dev" | grep -q '<.*[,<]UP[,>]'; then
            printf '%s\n' "$dev" >> "$work/restore-ports"
        fi
    done
    # Filogic-only experiment. This also interrupts LAN management access.
    ip link set dev "$parent" down
fi
printf 'DRAINING\n' > "$work/state"
stable=0
: > "$work/drain.log"
while :; do
    # Read every physical BND entry, not just the conntrack flags or test tuple.
    test -r /sys/kernel/debug/ppe0/bind
    test -r /sys/kernel/debug/ppe1/bind
    rows=$(cat /sys/kernel/debug/ppe0/bind /sys/kernel/debug/ppe1/bind | awk '/ BND / { n++ } END { print n+0 }')
    printf '%s %s\n' "$(( $(clock) - start ))" "$rows" >> "$work/drain.log"
    if [ "$rows" -gt 0 ]; then
        stable=0
    else
        stable=$((stable+1))
        [ "$stable" -ge 2 ] && break
    fi
    elapsed=$(( $(clock) - start ))
    if [ "$elapsed" -ge "$deadline" ]; then
        cat /sys/kernel/debug/ppe0/bind /sys/kernel/debug/ppe1/bind > "$work/drain-timeout.private"
        exit 1
    fi
    sleep 1
done
# A completed drain precedes unregistration. Failure above keeps WAN down and
# the flowtable registered; no automatic unsafe software fallback is attempted.
"$owner" --client "$socket" "NFT delete table inet $table"
if nft list table inet "$table" >/dev/null 2>&1; then exit 1; fi
printf 'SOFTWARE_READY\n' > "$work/state"
if [ "${GD_LIFE_HOLD_LINKS:-0}" = 1 ]; then
    [ -n "$parent" ] || exit 2
    printf 'SOFTWARE_HELD\n' > "$work/state"
    printf 'HELD\n' >> "$work/transitions.log"
    printf 'PREPARED %s\n' "$(( $(clock) - start ))"
    exit 0
fi
if [ -n "$parent" ]; then
    ip link set dev "$parent" up
    while read dev; do ip link set dev "$dev" up; done < "$work/restore-ports"
fi
ip link set dev "$wan" up
printf 'PREPARED %s\n' "$(( $(clock) - start ))"
