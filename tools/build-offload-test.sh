#!/bin/sh
# Isolated test variant: real nft owner, no physical interface/reboot callback.
set -eu
[ "$#" = 2 ] || exit 2
sdk=$1 output=$2
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cc=$(find "$sdk/staging_dir" -path '*/bin/aarch64-openwrt-linux-musl-gcc' -type f | head -1)
[ -x "$cc" ] || exit 1
STAGING_DIR="$sdk/staging_dir" "$cc" -Os -Wall -Wextra -Werror \
    -DGD_DIRECTORY='"/tmp/getdomains-offload-unit"' -DGD_DEADLINE_SECONDS=3 \
    -DGD_EMERGENCY='"/bin/touch /tmp/getdomains-offload-unit/emergency"' \
    "$root/offload/getdomains-offload-owner.c" -ldl -o "$output"
