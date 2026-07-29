# Repository guidance

## Purpose and supported environments

This repository contains two ways to configure policy-based domain routing on an
OpenWrt router:

1. an Ansible role in the conventional `defaults/`, `tasks/`, `handlers/`,
   `templates/`, and `meta/` directories;
2. standalone `getdomains-*.sh` scripts that are downloaded and run directly on
   OpenWrt.

Read `docs/REPOSITORY_MAP.md` before changing behavior. It records the main data
flow, the ownership of each file, and the important OpenWrt version split.

## Change rules

- Keep the Ansible role and the standalone installer aligned when a change
  affects behavior shared by both installation paths. They are separate
  implementations; changing one does not update the other.
- Treat commands that edit UCI, firewall, routing tables, dnsmasq, packages, or
  services as device-destructive. Do not execute the installer, uninstaller, or
  `tests/test.yml` on a development host.
- Shell scripts target OpenWrt's BusyBox shell (`ash`/`sh`). Avoid Bash-only
  syntax in new code, even if the existing installer contains some legacy Bash
  idioms.
- Preserve compatibility branches for pre-22 `ipset` and 22+ `nftables`/`nfset`
  unless the supported-version policy is intentionally changed and documented.
- Ansible variables belong in `defaults/main.yml`; use handlers for service
  restarts and keep tasks idempotent where the available OpenWrt modules allow
  it.
- Never put real router addresses or credentials in tracked fixtures. The value
  in `tests/inventory` is an example and the playbook targets that host directly.
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

If `ansible-playbook` and the `gekmihesg.openwrt` dependency are installed, also
run:

```sh
ansible-playbook --syntax-check -i tests/inventory tests/test.yml
```

This is only a syntax check. A real integration run modifies the router named in
`tests/inventory` and therefore requires an explicitly provisioned disposable
OpenWrt target.

## Release workflow

Tags trigger `.github/workflows/public-galaxy.yml`, which publishes the role to
Ansible Galaxy. Do not create or move release tags as part of an ordinary code
change.
