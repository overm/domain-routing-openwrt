# Repository guidance

## Purpose and supported environments

This repository contains standalone `getdomains-*.sh` scripts that configure
policy-based domain routing and are downloaded and run directly on OpenWrt.

Read `docs/REPOSITORY_MAP.md` before changing behavior. It records the main data
flow, the ownership of each file, and the supported OpenWrt design.

## Change rules

- Treat commands that edit UCI, firewall, routing tables, dnsmasq, packages, or
  services as device-destructive. Do not execute the installer or uninstaller
  on a development host.
- Shell scripts target OpenWrt's BusyBox shell (`ash`/`sh`). Avoid Bash-only
  syntax in new code, even if the existing installer contains some legacy Bash
  idioms.
- Preserve the OpenWrt 25+ `apk`, firewall4/nftables, and dnsmasq `nfset` design
  unless the supported-version policy is intentionally changed and documented.
- Never put real router addresses or credentials in tracked files.
- Update both `README.md` and `README.EN.md` when changing public installation
  steps, supported options, or user-visible behavior.

## Validation

Run the checks that are available without an OpenWrt target:

```sh
sh -n getdomains-install.sh
sh -n getdomains-check.sh
sh -n getdomains-uninstall.sh
git diff --check
```
