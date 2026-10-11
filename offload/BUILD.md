# Native owner build provenance

Source: `getdomains-offload-owner.c` in this repository.
Target: aarch64_cortex-a53, Linux/musl, OpenWrt 25.12.5 Filogic SDK.
Compiler: gcc 14.3.0. Commands: `tools/build-offload.sh`.

SDK archive:
`openwrt-sdk-25.12.5-mediatek-filogic_gcc-14.3.0_musl.Linux-x86_64.tar.zst`

Verified SDK SHA-256:
`ff4a38a397caa2cfe1c39e18f84ddede14878221b3593c3f2c4cfe24e3ec4c25`

[Official SDK directory](https://downloads.openwrt.org/releases/25.12.5/targets/mediatek/filogic/).
The binary's checksum is alongside it, generated after stripping. No target
library is copied into the build. Runtime dlopen uses the installed
`libnftables.so.1`; `--version` checks its three required public API symbols.
`--version` does not create an nft context, table, service or route.
The [OpenWrt nftables package](https://github.com/openwrt/openwrt/blob/openwrt-25.12/package/network/utils/nftables/Makefile)
installs the shared library with its CLI; a separate copied router library is
not required.

Rebuild twice in the matching SDK and compare hashes. Compile with
`-Wall -Wextra -Werror`; do not use the research fixture's libc/link-stub
workaround for release binaries. `owner-test` is ignored and never downloaded
by the installer. The isolated build shortens deadlines to three seconds;
the production deadline remains 180 seconds.
