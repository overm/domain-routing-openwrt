"""Test native LuCI HTTP apply ordering with a reversible, instrumented prehook.

Hardware MUST be disabled and PPE empty. This verifies integration ordering;
physical revocation is tested separately by offload-revoke-load.py.
"""
import json
import os
from pathlib import Path
import secrets
import shlex
import time
import urllib.error
import urllib.parse
import urllib.request
from offload_lifecycle_support import arguments, Device, save


ROOT = Path(__file__).resolve().parent


def main():
    args = arguments(__doc__)
    d = Device(args)
    result = {'status': 'incomplete', 'cases': [], 'hardware_active': False}
    controller = '/usr/share/ucode/luci/controller/admin/uci.uc'
    extension = '/usr/share/ucode/luci/controller/admin/gd_offload_lab.uc'
    menu = '/usr/share/luci/menu.d/zz-getdomains-offload-lab.json'
    backup = args.backup.rstrip('/') + '/'
    sid = None

    def rpc(object, method, data, sensitive=False):
        cmd = 'ubus call ' + shlex.quote(object) + ' ' + shlex.quote(method) + ' ' + shlex.quote(json.dumps(data))
        code, text = d.run(cmd, sensitive=sensitive)
        return json.loads(text) if text.strip() else {}

    def stage(package, section, value):
        rpc('uci', 'set', {'ubus_rpc_session': sid, 'config': package,
                          'section': section, 'values': {'gd_life_probe': value}})

    def apply(endpoint, confirm_token=None):
        query = urllib.parse.urlencode({'sid': sid, 'token': confirm_token or token})
        req = urllib.request.Request(f'http://{args.router}/cgi-bin/luci/admin/uci/{endpoint}?{query}',
                                     data=b'', headers={'Cookie': cookie}, method='POST')
        try:
            with urllib.request.urlopen(req, timeout=45) as response:
                status, body = response.status, response.read().decode()
        except urllib.error.HTTPError as error:
            status, body = error.code, error.read().decode()
        d.raw.append({'http_endpoint': endpoint, 'status': status, 'body': body})
        return status, body

    def committed(package):
        return d.run(f'uci -q get {package}.{sections[package]}.gd_life_probe', False)[1].strip()

    try:
        assert d.run('uci -q get firewall.@defaults[0].flow_offloading')[1].strip() == '0'
        assert ' BND ' not in d.run('cat /sys/kernel/debug/ppe0/bind /sys/kernel/debug/ppe1/bind')[1]
        assert 'gd_life_ft' not in d.run('nft list tables')[1]
        d.run('test ! -e ' + extension + ' && test ! -e ' + menu)
        stock_menu = json.loads(d.run('cat /usr/share/luci/menu.d/luci-base.json')[1])
        routes = {}
        for action in ('apply_unchecked', 'apply_rollback'):
            key = 'admin/uci/' + action
            routes[key] = stock_menu[key]
            routes[key]['action']['module'] = 'luci.controller.admin.gd_offload_lab'
        # Extend the local recovery script before installing persistent fixtures.
        restore = d.run('cat ' + backup + 'restore.sh')[1]
        cleanup = 'rm -f ' + extension + ' ' + menu + '\n'
        if cleanup not in restore:
            d.upload(restore.replace('reboot\n', cleanup + 'reboot\n'), backup + 'restore.sh')
        d.upload((ROOT/'prototypes/offload-luci.uc').read_text(), extension)
        d.upload(json.dumps(routes), menu)
        d.upload((ROOT/'prototypes/fw4-preapply.sh').read_text(), '/sbin/fw4')
        d.run('cp -p ' + backup + '_sbin_fw4 /tmp/gd-life-lab/fw4.real; chmod 0755 /sbin/fw4')
        instrument = '''#!/bin/sh
set -eu
printf '%s %s\\n' "$1" "$(uci -q get firewall.@defaults[0].gd_life_probe || true)" >> /tmp/gd-life-lab/preapply.log
[ ! -f /tmp/gd-life-lab/preapply.fail ]
'''
        d.upload(instrument, '/tmp/gd-life-lab/instrument')
        d.upload('#!/bin/sh\nexec /tmp/gd-life-lab/instrument LUCI\n', '/tmp/gd-life-lab/luci-prepare')
        d.upload('#!/bin/sh\nexec /tmp/gd-life-lab/instrument FW4\n', '/tmp/gd-life-lab/firewall-prepare')
        d.run('chmod 0700 /tmp/gd-life-lab/instrument /tmp/gd-life-lab/luci-prepare /tmp/gd-life-lab/firewall-prepare; : > /tmp/gd-life-lab/preapply.log')

        # Only the authentication command is omitted from private command logs.
        auth = rpc('session', 'login', {'username': 'root',
                   'password': os.environ['GETDOMAINS_TEST_PASSWORD'], 'timeout': 600}, sensitive=True)
        sid = auth['ubus_rpc_session']
        # LuCI's session_setup adds this value after native rpcd login.
        # A plain rpcd session without it is intentionally rejected by LuCI.
        token = secrets.token_hex(16)
        rpc('session', 'set', {'ubus_rpc_session': sid, 'values': {'token': token}}, sensitive=True)
        cookie = f'sysauth_http={sid}; sysauth={sid}'
        req = urllib.request.Request(f'http://{args.router}/cgi-bin/luci/admin/status/overview',
                                     headers={'Cookie': cookie})
        with urllib.request.urlopen(req, timeout=20) as response: response.read()
        token = rpc('session', 'get', {'ubus_rpc_session': sid})['values']['token']
        sections = {}
        for package, kind in (('firewall', 'defaults'), ('dhcp', 'dnsmasq'), ('network', 'interface')):
            values = rpc('uci', 'get', {'ubus_rpc_session': sid, 'config': package})['values']
            sections[package] = next(k for k, v in values.items() if v['.type'] == kind)

        # Abort occurs before native commit and before any firewall change event.
        stage('firewall', sections['firewall'], 'must-not-commit')
        before = d.run('sha256sum /etc/config/firewall')[1]
        d.run('touch /tmp/gd-life-lab/preapply.fail')
        code, _ = apply('apply_unchecked')
        assert code == 503, code
        assert d.run('sha256sum /etc/config/firewall')[1] == before
        assert not committed('firewall')
        result['cases'].append({'case': 'unchecked-preparation-fails', 'http': code, 'committed': False})
        code, _ = apply('apply_rollback')
        assert code == 503 and d.run('sha256sum /etc/config/firewall')[1] == before
        result['cases'].append({'case': 'checked-preparation-fails', 'http': code, 'committed': False})

        d.run('rm -f /tmp/gd-life-lab/preapply.fail; : > /tmp/gd-life-lab/preapply.log')
        stage('firewall', sections['firewall'], 'accepted')
        code, _ = apply('apply_unchecked')
        assert code in (200, 204), code
        time.sleep(3)
        assert committed('firewall') == 'accepted'
        log = d.run('cat /tmp/gd-life-lab/preapply.log')[1].splitlines()
        assert log[0] == 'LUCI ' and any(line == 'FW4 accepted' for line in log), log
        result['cases'].append({'case': 'unchecked-order', 'prehook_before_commit': True,
                                'fw4_hook_after_commit_before_kernel_apply': True})

        stage('firewall', sections['firewall'], 'checked-confirmed')
        code, body = apply('apply_rollback')
        assert code == 200 and json.loads(body)['token']
        code, _ = apply('confirm', json.loads(body)['token'])
        assert code in (200, 204) and committed('firewall') == 'checked-confirmed'
        result['cases'].append({'case': 'checked-confirm', 'native_rollback_token_and_confirm': True})

        stage('firewall', sections['firewall'], 'checked-will-roll-back')
        code, body = apply('apply_rollback')
        assert code == 200 and json.loads(body)['token']
        assert committed('firewall') == 'checked-will-roll-back'
        for tick in range(105):
            time.sleep(1)
            if tick % 15 == 0:
                print(json.dumps({'phase': 'native-rollback', 'seconds': tick}), flush=True)
            if tick >= 85 and committed('firewall') == 'checked-confirmed': break
        else: raise RuntimeError('Native automatic rollback did not restore the previous configuration.')
        rpc('uci', 'revert', {'ubus_rpc_session': sid, 'config': 'firewall'})
        result['cases'].append({'case': 'checked-automatic-rollback', 'previous_config_restored': True})

        d.run('touch /tmp/gd-life-lab/preapply.fail')
        before_network = d.run('sha256sum /etc/config/network')[1]
        stage('network', sections['network'], 'must-not-commit')
        code, _ = apply('apply_unchecked')
        assert code == 503 and d.run('sha256sum /etc/config/network')[1] == before_network
        rpc('uci', 'revert', {'ubus_rpc_session': sid, 'config': 'network'})
        result['cases'].append({'case': 'network-preparation-fails', 'http': code, 'committed': False})

        d.run('touch /tmp/gd-life-lab/preapply.fail')
        before_dhcp = d.run('sha256sum /etc/config/dhcp')[1]
        rpc('uci', 'set', {'ubus_rpc_session': sid, 'config': 'dhcp', 'section': 'wdns',
                          'values': {'gd_life_probe': 'critical-wdns'}})
        code, _ = apply('apply_unchecked')
        assert code == 503 and d.run('sha256sum /etc/config/dhcp')[1] == before_dhcp
        rpc('uci', 'revert', {'ubus_rpc_session': sid, 'config': 'dhcp'})
        result['cases'].append({'case': 'wdns-preparation-fails', 'http': code, 'committed': False})

        # Saving ordinary DNS settings must retain the native DNS path.
        d.run(': > /tmp/gd-life-lab/preapply.log; touch /tmp/gd-life-lab/preapply.fail')
        stage('dhcp', sections['dhcp'], 'dns-only')
        code, _ = apply('apply_unchecked')
        assert code in (200, 204) and committed('dhcp') == 'dns-only'
        assert 'LUCI' not in d.run('cat /tmp/gd-life-lab/preapply.log')[1]
        result['cases'].append({'case': 'dns-only', 'prehook_called': False, 'committed': True})

        # Native fw4 entry points must refuse mutation when preparation fails.
        for action in ('reload', 'restart', 'stop', 'flush', 'reload-sets'):
            before_chain = d.run('nft -s list chain inet fw4 forward')[1]
            code, _ = d.run('fw4 ' + action, False)
            assert code != 0 and d.run('nft -s list chain inet fw4 forward')[1] == before_chain
            result['cases'].append({'case': 'fw4-' + action + '-blocked', 'kernel_chain_unchanged': True})

        # Negative control: native UCI RPC bypasses the LuCI server hook.
        # Harmless marker with hardware off; this demonstrates the support boundary.
        d.run(': > /tmp/gd-life-lab/preapply.log')
        stage('firewall', sections['firewall'], 'direct-rpc')
        rpc('uci', 'commit', {'ubus_rpc_session': sid, 'config': 'firewall'})
        assert committed('firewall') == 'direct-rpc'
        assert 'LUCI' not in d.run('cat /tmp/gd-life-lab/preapply.log')[1]
        result['cases'].append({'case': 'direct-uci-rpc-negative-control', 'bypasses_luci_precommit': True})
        result['status'] = 'passed'
    finally:
        # Remove the wrappers BEFORE native service reloads.
        d.run('cp -p ' + backup + '_sbin_fw4 /sbin/fw4; rm -f ' + extension + ' ' + menu)
        d.run('cp -p ' + backup + '_etc_config_firewall /etc/config/firewall; cp -p ' + backup + '_etc_config_dhcp /etc/config/dhcp')
        if sid:
            rpc('uci', 'revert', {'ubus_rpc_session': sid, 'config': 'firewall'})
            rpc('uci', 'revert', {'ubus_rpc_session': sid, 'config': 'dhcp'})
            rpc('uci', 'revert', {'ubus_rpc_session': sid, 'config': 'network'})
            rpc('session', 'destroy', {'ubus_rpc_session': sid})
        d.run('/etc/init.d/firewall reload; /etc/init.d/dnsmasq restart')
        save(args, result)
        d.close()


if __name__ == '__main__':
    main()
