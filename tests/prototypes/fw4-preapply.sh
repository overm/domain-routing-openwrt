#!/bin/sh
# Temporary wrapper for stock fw4. The harness restores /sbin/fw4 byte-for-byte.
set -eu
operation() {
    while [ "$#" -gt 0 ]; do
        case "$1" in -q|-v) shift ;; *) printf '%s\n' "$1"; return ;; esac
    done
}
case "$(operation "$@")" in
    start|stop|restart|reload|flush|reload-sets)
        /tmp/gd-life-lab/firewall-prepare || exit 1
        ;;
esac
exec /tmp/gd-life-lab/fw4.real "$@"
