"""Exercise the production transaction with mocked device boundaries.

Only function definitions are loaded. The device dispatcher is never executed.
All writes go to a temporary directory; service/UCI/nft/download calls are mocked.
"""
from pathlib import Path
import subprocess
import tempfile
import unittest
from test_compiler import ROOT, SH


class RuntimeTests(unittest.TestCase):
    def run_transaction(self, scenario):
        definitions = (ROOT/'getdomains-runtime.sh').read_text().split('\ncase ${1:-} in\n')[0]
        definitions = definitions.replace('\nsync_wdns_route() {', '\nproduction_sync_wdns_route() {')
        definitions = definitions.replace('\nsnapshot() {', '\nproduction_snapshot() {')
        with tempfile.TemporaryDirectory(prefix='getdomains-runtime-test-') as tmp:
            tmp = Path(tmp)
            (tmp/'work').mkdir()
            (tmp/'conf').mkdir()
            script = tmp/'test.sh'
            script.write_text(definitions + r'''
PATH=/usr/bin:$PATH
ROOT=$1
COMPILER=$2
work=$ROOT/work
PENDING=$ROOT/pending
STATIC=$ROOT/static
GUARDS=$ROOT/guards
action=reload
printf 'nftset=/example.test/4#inet#fw4#vpn_domains\n' > "$ROOT/source"
printf 'previous configuration\n' > "$ROOT/conf/domains.lst"
printf 'S\t192.0.2.53\t0\n' > "$ROOT/snapshot"
uci() { case "$*" in *confdir) printf '%s/conf\n' "$ROOT";; *) return 1;; esac; }
snapshot() { cat "$ROOT/snapshot"; }
fingerprint() { printf 'stable\n'; }
sync_wdns_route() { :; }
restart_dnsmasq() { printf 'restart\n' >> "$ROOT/restarts"; }
log() { printf '%s\n' "$*" >> "$ROOT/log"; }
dnsmasq() { return 0; }
nft() { printf 'nft\n' >> "$ROOT/nft-calls"; }
ip() { return 0; }
nslookup() { return 0; }
curl() { return 1; }
''' + scenario, newline='\n')
            result = subprocess.run([SH, str(script).replace('\\', '/'),
                str(tmp).replace('\\', '/'), str(ROOT/'getdomains-compile.awk').replace('\\', '/')],
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def test_invalid_download_preserves_active_generation(self):
        self.run_transaction(r'''
printf 'server=/#/192.0.2.99\n' > "$ROOT/source"
if apply "$ROOT/source"; then exit 9; fi
grep -qx 'previous configuration' "$ROOT/conf/domains.lst"
[ ! -e "$ROOT/restarts" ]
''')

    def test_dnsmasq_validation_failure_preserves_active_generation(self):
        self.run_transaction(r'''
dnsmasq() { return 1; }
if apply "$ROOT/source"; then exit 9; fi
grep -qx 'previous configuration' "$ROOT/conf/domains.lst"
[ ! -e "$ROOT/restarts" ]
''')

    def test_concurrent_luci_change_aborts_before_replace(self):
        self.run_transaction(r'''
fingerprint() {
    if [ -f "$ROOT/seen" ]; then printf 'changed\n'; else touch "$ROOT/seen"; printf 'before\n'; fi
}
if apply "$ROOT/source"; then exit 9; fi
grep -qx 'previous configuration' "$ROOT/conf/domains.lst"
[ ! -e "$ROOT/restarts" ]
''')

    def test_changed_generation_restarts_once_and_unchanged_does_not(self):
        self.run_transaction(r'''
apply "$ROOT/source"
apply "$ROOT/source"
[ "$(wc -l < "$ROOT/restarts")" -eq 1 ]
grep -qx 'server=/example.test/192.0.2.53' "$ROOT/conf/domains.lst"
[ ! -e "$PENDING" ]
''')

    def test_prepare_restores_cache_without_restart(self):
        self.run_transaction(r'''
apply "$ROOT/source" prepare
grep -qx 'server=/example.test/192.0.2.53' "$ROOT/conf/domains.lst"
[ ! -e "$ROOT/restarts" ]
''')

    def test_service_failure_is_retried_even_when_file_is_unchanged(self):
        self.run_transaction(r'''
restart_dnsmasq() { return 1; }
if apply "$ROOT/source"; then exit 9; fi
[ -e "$PENDING" ]
restart_dnsmasq() { printf 'retry\n' > "$ROOT/restarts"; }
apply "$ROOT/source"
grep -qx retry "$ROOT/restarts"
[ ! -e "$PENDING" ]
''')

    def test_static_seed_failure_does_not_lose_pending_restart(self):
        self.run_transaction(r'''
printf 'H\texample.test\t198.51.100.9\n' >> "$ROOT/snapshot"
nft() { return 1; }
if apply "$ROOT/source"; then exit 9; fi
[ -e "$PENDING" ]
[ ! -e "$ROOT/restarts" ]
nft() { return 0; }
apply "$ROOT/source"
grep -qx restart "$ROOT/restarts"
''')

    def test_download_failure_preserves_flash_cache_and_dns(self):
        self.run_transaction(r'''
printf 'https://invalid.example/list\n' > "$ROOT/source-url"
cp "$ROOT/source" "$ROOT/domains.source"
cp "$ROOT/source" "$ROOT/cache-before"
if refresh; then exit 9; fi
cmp -s "$ROOT/cache-before" "$ROOT/domains.source"
grep -qx 'previous configuration' "$ROOT/conf/domains.lst"
''')

    def test_refresh_stores_only_validated_source_and_restarts_once(self):
        self.run_transaction(r'''
printf 'https://invalid.example/list\n' > "$ROOT/source-url"
curl() { for last do :; done; cp "$ROOT/source" "$last"; }
action=refresh
refresh
cmp -s "$ROOT/source" "$ROOT/domains.source"
[ "$(wc -l < "$ROOT/restarts")" -eq 1 ]
''')

    def test_luci_add_and_delete_each_regenerate_dns_rules(self):
        self.run_transaction(r'''
apply "$ROOT/source"
printf 'M\tmanual.test\t4#inet#fw4#vpn_domains\n' >> "$ROOT/snapshot"
apply "$ROOT/source"
grep -qx 'server=/manual.test/192.0.2.53' "$ROOT/conf/domains.lst"
sed -i '/^M/d' "$ROOT/snapshot"
apply "$ROOT/source"
if grep -q manual.test "$ROOT/conf/domains.lst"; then exit 9; fi
[ "$(wc -l < "$ROOT/restarts")" -eq 3 ]
''')

    def test_publication_failure_preserves_active_generation(self):
        self.run_transaction(r'''
mv() { return 1; }
if apply "$ROOT/source"; then exit 9; fi
grep -qx 'previous configuration' "$ROOT/conf/domains.lst"
[ ! -e "$ROOT/restarts" ]
''')

    def test_empty_download_is_rejected_before_replace(self):
        self.run_transaction(r'''
printf 'https://invalid.example/list\n' > "$ROOT/source-url"
curl() { for last do :; done; : > "$last"; }
if refresh; then exit 9; fi
grep -qx 'previous configuration' "$ROOT/conf/domains.lst"
[ ! -e "$ROOT/domains.source" ]
''')

    def test_server_change_guards_old_and_new_destination_until_publish(self):
        self.run_transaction(r'''
wdns=192.0.2.53
uci() {
    case "$*" in
        *get*network.wdns*) echo 192.0.2.54/32;;
        *batch*) cat > "$ROOT/batch";;
        *commit*) return 0;;
    esac
}
ip() {
    case "$*" in *show*) printf '80: from all to 192.0.2.53 lookup vpn\n81: from all to 192.0.2.53 unreachable\n';;
        *) printf '%s\n' "$*" >> "$ROOT/ip-calls";; esac
}
reload_network() { touch "$ROOT/reloaded"; }
production_sync_wdns_route
grep -qx '192.0.2.54/32' "$GUARDS"
grep -qx '192.0.2.53/32' "$GUARDS"
[ -f "$ROOT/reloaded" ]
clear_wdns_guards
[ ! -e "$GUARDS" ]
grep -q 'rule del priority 79 to 192.0.2.54/32 unreachable' "$ROOT/ip-calls"
''')

    def test_boot_keeps_wdns_guard_without_reloading_network(self):
        self.run_transaction(r'''
wdns=192.0.2.53
action=prepare
uci() { case "$*" in *batch*) cat >/dev/null;; *commit*) return 0;; *) return 1;; esac; }
reload_network() { exit 9; }
production_sync_wdns_route
grep -qx '192.0.2.53/32' "$GUARDS"
''')

    def test_ready_wdns_routes_do_not_reload_network(self):
        self.run_transaction(r'''
wdns=192.0.2.53
uci() { echo 192.0.2.53/32; }
ip() { printf '80: from all to 192.0.2.53 lookup vpn\n81: from all to 192.0.2.53 unreachable\n'; }
reload_network() { exit 9; }
production_sync_wdns_route
[ ! -e "$GUARDS" ]
''')

    def test_snapshot_uses_loaded_instance_id_and_retains_local_overrides(self):
        self.run_transaction(r'''
load_config_snapshot() { printf 'vpn_domains\t4\n' > "$work/families"; }
config_foreach() {
    case $2 in dnsmasq) "$1" cfgfirst; "$1" cfgsecond;;
        ipset) "$1" row;; domain) "$1" local;; cname) "$1" alias;; esac
    return 0
}
config_get() {
    value=${4:-}
    case "$2:$3" in
        wdns:dhcp_option) value='42,192.0.2.9 6,192.0.2.53';;
        cfgfirst:server) value='/custom.test/192.0.2.54 /#/192.0.2.55';;
        cfgfirst:local) value='/lan/';;
        row:instance) value=cfgfirst;; row:name) value=vpn_domains;; row:domain) value=manual.test;;
        local:name) value=local.test;; local:ip) value=198.51.100.9;;
        alias:cname) value=alias.test;; alias:target) value=local.test;;
    esac
    export "$1=$value"
}
production_snapshot > "$ROOT/actual-snapshot"
grep -qx 'M\tmanual.test\t4#inet#fw4#vpn_domains' "$ROOT/actual-snapshot"
grep -qx 'X\tcustom.test' "$ROOT/actual-snapshot"
grep -qx 'X\t\*' "$ROOT/actual-snapshot"
grep -qx 'H\tlocal.test\t198.51.100.9' "$ROOT/actual-snapshot"
grep -qx 'C\talias.test\tlocal.test' "$ROOT/actual-snapshot"
grep -qx 'S\t192.0.2.53\t0' "$ROOT/actual-snapshot"
'''.replace('\\t', '\t'))


if __name__ == '__main__':
    unittest.main()
