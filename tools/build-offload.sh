#!/bin/sh
# Reproducible musl build using the official matching SDK.
set -eu
[ "$#" = 2 ] || { echo 'Usage: build-offload.sh SDK_DIRECTORY OUTPUT' >&2; exit 2; }
sdk=$1 output=$2
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cc=$(find "$sdk/staging_dir" -path '*/bin/aarch64-openwrt-linux-musl-gcc' -type f | head -1)
[ -x "$cc" ] || exit 1
STAGING_DIR="$sdk/staging_dir" "$cc" -Os -Wall -Wextra -Werror \
    -Wl,--build-id=none \
    "$root/offload/getdomains-offload-owner.c" -ldl -o "$output"
"${cc%gcc}strip" "$output"
sha256sum "$output"
sha256sum "$output" | awk '{ print $1 }' > "$output.sha256"
