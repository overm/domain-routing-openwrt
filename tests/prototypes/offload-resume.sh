#!/bin/sh
# Research-only second phase; policy must be committed while links are held.
set -eu
[ "${GETDOMAINS_ALLOW_DESTRUCTIVE_TESTS:-}" = 1 ] || exit 2
[ "$#" = 2 ] && [ "$2" = eth0 ] || exit 2
work=/tmp/gd-life-lab
[ "$(cat "$work/state")" = POLICY_APPLIED ] || exit 1
if nft list table inet gd_life_ft >/dev/null 2>&1; then exit 1; fi
ip link set dev "$2" up
while read dev; do ip link set dev "$dev" up; done < "$work/restore-ports"
ip link set dev "$1" up
printf 'RESTORED\n' >> "$work/transitions.log"
printf 'SOFTWARE_READY\n' > "$work/state"
