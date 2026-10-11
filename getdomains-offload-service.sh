#!/bin/sh /etc/rc.common
START=99
STOP=01
USE_PROCD=1
start_service() {
    procd_open_instance
    procd_set_param command /usr/libexec/getdomains-offload watch
    procd_set_param respawn 3600 5 3
    procd_close_instance
}
stop_service() {
    # Holders deliberately outlive an ordinary service stop. Dropping their
    # socket before a physical drain can orphan live hardware entries.
    [ ! -S /tmp/getdomains-offload/owner.sock ] ||
        /usr/libexec/getdomains-offload-owner --client CLOSE || true
}
