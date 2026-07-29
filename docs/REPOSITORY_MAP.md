# Repository map

## What the project does

The project downloads domain and IP lists, places destinations into OpenWrt
firewall sets, marks matching LAN traffic, and sends packets with that mark
through a dedicated `vpn` routing table. It can also configure an encrypted DNS
resolver. There are two independent entry points:

- **Ansible role:** declarative setup driven by variables from
  `defaults/main.yml` and implemented by `tasks/main.yml`.
- **Standalone scripts:** interactive installation in
  `getdomains-install.sh`, diagnostics in `getdomains-check.sh`, and partial
  cleanup in `getdomains-uninstall.sh`.

The standalone installer is not generated from the Ansible role. When shared
behavior changes, compare both implementations explicitly.

## Directory and file ownership

| Path | Responsibility |
| --- | --- |
| `defaults/main.yml` | Public defaults for list selection, tunnel, DNS encryption, country, editor installation, and WireGuard access. |
| `tasks/main.yml` | Entire Ansible convergence flow: package installation, tunnel/firewall/network setup, list sets and mark rules, cleanup, and DNS resolver setup. |
| `handlers/main.yml` | Deferred service restarts invoked by role tasks. |
| `meta/main.yml` | Galaxy metadata and the `gekmihesg.openwrt` role dependency that provides OpenWrt modules such as `opkg` and `uci`. |
| `templates/openwrt-getdomains.j2` | Renders `/etc/init.d/getdomains`; downloads selected lists and restarts dnsmasq/firewall. |
| `templates/openwrt-30-vpnroute.j2` | Creates the default route in table `vpn` for `wg0` or `tun0`. |
| `templates/sing-box-json.j2` | Starter sing-box TUN configuration; connection placeholders still require user configuration. |
| `templates/config-sing-box.j2` | UCI service configuration for sing-box. |
| `getdomains-install.sh` | Interactive OpenWrt 23.05/24.10 installer, including WireGuard, AmneziaWG, tunnel zones, sets, dnsmasq, and resolver choices. |
| `getdomains-check.sh` | Russian/English device diagnostics; optional DNS-poisoning checks and redacted dump creation. |
| `getdomains-uninstall.sh` | Removes getdomains artifacts and routing/firewall rules, while intentionally retaining tunnels and DNS proxy packages. |
| `tests/test.yml` | Minimal role application playbook for a real OpenWrt host. |
| `tests/inventory` | Example integration inventory; not a local mock or unit-test fixture. |
| `.github/workflows/public-galaxy.yml` | Publishes the Ansible role when a Git tag is pushed. |
| `README.md`, `README.EN.md` | Russian primary documentation and shorter English role documentation. |

## Ansible execution flow

`tasks/main.yml` is a single ordered task list. Its major phases are:

1. inspect the dnsmasq and OpenWrt versions;
2. install packages selected by `tunnel`, `dns_encrypt`, and `nano`;
3. render and schedule the getdomains init script;
4. create routing table `99 vpn` and its per-tunnel default route;
5. configure WireGuard, sing-box, OpenVPN, or tun2socks zones/interfaces;
6. map firewall mark `0x1` to the `vpn` routing table;
7. create destination sets and MARK rules for enabled lists;
8. remove sets and rules for disabled lists;
9. optionally configure dnscrypt-proxy2 or stubby;
10. commit UCI configurations and notify restart handlers.

Task order matters: later UCI commits and notified handlers make earlier section
changes effective.

## Central behavior and compatibility boundaries

### List selection

- `list_domains` uses a country-specific list from the external
  `itdoginfo/allow-domains` repository.
- `list_subnet`, `list_ip`, and `list_community` use antifilter list endpoints.
- Disabled list variables cause the Ansible role to remove their corresponding
  set and mark rule.

### OpenWrt versions

- The role retains an important split at OpenWrt 22: older releases use ipset
  syntax, while 22+ releases use nftables-compatible sets.
- The standalone installer currently exits unless the detected major release is
  23 or 24.
- sing-box role tasks reject releases older than 22 and automatic package
  installation is limited to newer releases.

Keep comparisons consistent: the role commonly obtains version values as text,
so changing a quoted comparison to a numeric comparison can alter Ansible/Jinja
evaluation.

### Routing model

Matching firewall rules set mark `0x1`. An OpenWrt network rule looks up table
`vpn`, registered as table number 99. WireGuard routes through `wg0`; OpenVPN,
sing-box, and tun2socks route through `tun0`. The standalone YouTube-specific
WireGuard/AmneziaWG path additionally uses mark `0x2` and table `vpninternal`.

### Generated and runtime files

Most paths mentioned in templates and scripts are files on the target router,
not repository outputs. Important examples are `/etc/init.d/getdomains`,
`/tmp/dnsmasq.d/domains.lst`, `/tmp/lst/*.lst`,
`/etc/hotplug.d/iface/30-vpnroute`, `/etc/iproute2/rt_tables`, and UCI configs
under `/etc/config`. Do not add these runtime artifacts to the repository.

## Safe change workflow

1. Identify whether the feature belongs to the role, standalone scripts, or
   both.
2. Trace every affected public variable through defaults, task `when`
   conditions, and Jinja templates.
3. Check both sides of the pre-22/22+ firewall-set split.
4. Check enable and disable paths so a second role run remains convergent.
5. Update Russian and English documentation for public behavior.
6. Run the non-device checks documented in `AGENTS.md`.
7. Use a disposable OpenWrt router for integration testing; never treat the
   sample inventory as a safe local test target.
