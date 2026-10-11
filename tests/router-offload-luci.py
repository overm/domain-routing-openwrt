"""Opt-in tests of installed production LuCI apply, auth, rollback and DNS."""
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


def main():
    a = arguments(__doc__)
    d = Device(a)
    report = {'status': 'incomplete', 'cases': []}
    sid = second = None
    marker = 'gd_offload_test'
    section = None

    def rpc(obj, method, data, sensitive=False):
        text = d.run('ubus call '+shlex.quote(obj)+' '+shlex.quote(method)+' '+
                     shlex.quote(json.dumps(data)), sensitive=sensitive)[1]
        return json.loads(text) if text.strip() else {}

    def login():
        s = rpc('session', 'login', {'username': 'root', 'password':
                os.environ['GETDOMAINS_TEST_PASSWORD'], 'timeout': 1200}, True)['ubus_rpc_session']
        rpc('session', 'set', {'ubus_rpc_session': s, 'values': {'token': secrets.token_hex(16)}}, True)
        return s

    def http(endpoint, fields=None, session=None, post=True):
        session = session or sid
        data = {'sid': session, 'token': token, **(fields or {})}
        req = urllib.request.Request('http://'+a.router+'/cgi-bin/luci/admin/uci/'+endpoint+'?'+
                                     urllib.parse.urlencode(data), data=b'' if post else None,
                                     headers={'Cookie': 'sysauth_http='+session})
        try:
            with urllib.request.urlopen(req, timeout=10) as response:
                return response.status, response.read().decode()
        except urllib.error.HTTPError as error:
            return error.code, error.read().decode()

    def apply(checked=False, expect_async=True):
        status, body = http('apply_rollback' if checked else 'apply_unchecked')
        if status in (200, 204) and not expect_async: return {'status': status}
        assert status == 202, (status, body)
        job = json.loads(body)['getdomains_job']
        deadline = time.monotonic()+180
        while time.monotonic() < deadline:
            try:
                status, body = http('getdomains_job', {'job': job}, post=False)
                if status == 200:
                    result = json.loads(body)
                    if not result.get('pending'):
                        assert result['status'] == (200 if checked else 204), result
                        d.reconnect()
                        assert d.run('cat /proc/sys/kernel/random/boot_id')[1] == boot
                        assert http('getdomains_job', {'job': job}, second, False)[0] == 403
                        return result
            except (OSError, urllib.error.URLError): pass
            time.sleep(1)
        raise RuntimeError('Asynchronous job did not finish')

    def stage(value):
        rpc('uci', 'set', {'ubus_rpc_session': sid, 'config': 'firewall',
                          'section': section, 'values': {marker: value}})

    def committed():
        return d.run('uci -q get firewall.'+section+'.'+marker, False)[1].strip()

    def admission():
        return d.run('nft list chain inet gd_offload admission')[1]

    try:
        assert 'mode=strict' in d.run('/usr/libexec/getdomains-offload status')[1]
        boot = d.run('cat /proc/sys/kernel/random/boot_id')[1]
        sid, second = login(), login()
        token = rpc('session', 'get', {'ubus_rpc_session': sid})['values']['token']
        # Force native session setup and menu regeneration.
        req = urllib.request.Request('http://'+a.router+'/cgi-bin/luci/admin/status/overview',
                                     headers={'Cookie': 'sysauth_http='+sid})
        with urllib.request.urlopen(req, timeout=20) as response: response.read()
        token = rpc('session', 'get', {'ubus_rpc_session': sid})['values']['token']
        values = rpc('uci', 'get', {'ubus_rpc_session': sid, 'config': 'firewall'})['values']
        section = next(k for k, v in values.items() if v['.type'] == 'defaults')
        assert not committed() or committed().startswith(('unchecked', 'checked', 'dns-next')), 'Unexpected existing test marker'
        assert http('getdomains_job', {'job': '../../etc/shadow'}, post=False)[0] == 400
        assert http('getdomains_command', {'command': '/bin/sh', 'argument': 'reboot'})[0] == 400
        assert http('apply_unchecked', {'token': 'bad-token'})[0] == 403
        report['cases'].append({'case': 'authentication-and-input-validation', 'passed': True})

        unchecked = 'unchecked-'+secrets.token_hex(4)
        checked = 'checked-'+secrets.token_hex(4)
        stage(unchecked)
        apply()
        assert committed() == unchecked and 'flow add @direct' in admission()
        report['cases'].append({'case': 'unchecked-asynchronous-critical-apply', 'passed': True})

        stage(checked)
        result = apply(True)
        confirm = result['body']['token']
        assert committed() == checked and 'flow add @direct' not in admission()
        assert http('apply_unchecked')[0] == 409
        assert d.run('/usr/libexec/getdomains-offload submit /bin/true', False)[0] != 0
        assert d.run('/usr/libexec/getdomains-offload transaction /bin/true', False)[0] != 0
        assert http('confirm', {'token': 'bad-token'})[0] == 403
        assert 'flow add @direct' not in admission()
        assert http('confirm', {'token': confirm})[0] in (200, 204)
        assert 'flow add @direct' in admission()
        report['cases'].append({'case': 'checked-confirm-opens-admission-only-on-valid-token', 'passed': True})

        stage('will-roll-back')
        rpc('uci', 'add', {'ubus_rpc_session': sid, 'config': 'firewall',
            'type': 'rule', 'name': 'gd_offload_rollback_probe',
            'values': {'name': 'getdomains offload rollback probe', 'src': 'lan', 'dest': 'wan',
                       'family': 'ipv4', 'proto': 'tcp', 'dest_ip': '198.18.0.99',
                       'dest_port': '9', 'target': 'REJECT'}})
        result = apply(True)
        assert 'getdomains offload rollback probe' in d.run('nft list chain inet fw4 forward_lan')[1]
        assert 'flow add @direct' not in admission()
        deadline = time.monotonic()+115
        last_progress = 0
        while time.monotonic() < deadline:
            if time.monotonic()-last_progress > 20:
                print(json.dumps({'phase': 'checking-native-automatic-rollback'}), flush=True)
                last_progress = time.monotonic()
            try:
                if committed() == checked: break
            except (OSError, d.paramiko.SSHException): d.reconnect()
            time.sleep(2)
        else: raise RuntimeError('Native rollback did not restore previous UCI')
        time.sleep(8)
        d.reconnect()
        assert 'flow add @direct' not in admission()
        assert d.run('cat /proc/sys/kernel/random/boot_id')[1] == boot
        rpc('uci', 'revert', {'ubus_rpc_session': sid, 'config': 'firewall'})
        report['cases'].append({'case': 'automatic-rollback-keeps-hardware-closed', 'passed': True})

        # UCI rollback precedes its deferred firewall reload/physical pause.
        # Keep the next operation serialized until network recovery finishes.
        deadline = time.monotonic()+120
        while time.monotonic() < deadline:
            try:
                if d.run('test ! -d /tmp/getdomains-offload/submission.lock && '
                         'test ! -d /tmp/getdomains-offload/transaction.lock && '
                         'test ! -f /tmp/getdomains-offload/await-confirm', False)[0] == 0 and \
                   'getdomains offload rollback probe' not in d.run('nft list chain inet fw4 forward_lan')[1]: break
            except (OSError, d.paramiko.SSHException): d.reconnect()
            time.sleep(2)
        else: raise RuntimeError('Rollback serialization did not release the next apply')
        assert 'flow add @direct' not in admission(), 'Deferred rollback reopened hardware admission'

        # Reconcile once, then verify the native DNS/IP Sets path changes neither
        # owner generation nor connection decisions.
        stage('dns-next'); apply()
        epoch = d.run('/usr/libexec/getdomains-offload-owner --client EPOCH')[1]
        for name, kind, values in (
            ('gd_offload_dns_probe', 'domain', {'name': 'offload-probe.example', 'ip': '198.18.0.1'}),
            ('gd_offload_dns_set', 'ipset', {'name': ['vpn_domains'], 'domain': ['offload-probe.example']})):
            rpc('uci', 'add', {'ubus_rpc_session': sid, 'config': 'dhcp', 'type': kind,
                              'name': name, 'values': values})
        assert http('apply_unchecked')[0] in (200, 204)
        time.sleep(12)
        answer = d.run('nslookup offload-probe.example 127.0.0.1')[1]
        assert '198.18.0.1' in answer
        d.run('nft get element inet fw4 vpn_domains { 198.18.0.1 }')
        assert d.run('/usr/libexec/getdomains-offload-owner --client EPOCH')[1] == epoch
        for name in ('gd_offload_dns_probe', 'gd_offload_dns_set'):
            rpc('uci', 'delete', {'ubus_rpc_session': sid, 'config': 'dhcp', 'section': name})
        assert http('apply_unchecked')[0] in (200, 204)
        report['cases'].append({'case': 'manual-dns-and-ipsets-native-add-delete', 'passed': True})

        rpc('uci', 'set', {'ubus_rpc_session': sid, 'config': 'firewall', 'section': section,
                          'values': {'flow_offloading_hw': '1'}})
        assert http('apply_unchecked')[0] == 409
        rpc('uci', 'revert', {'ubus_rpc_session': sid, 'config': 'firewall'})
        report['cases'].append({'case': 'native-broad-offload-conflict-rejected', 'passed': True})
        report['status'] = 'passed'
    finally:
        if sid and section:
            try:
                d.reconnect()
                for package in ('firewall', 'dhcp'):
                    rpc('uci', 'revert', {'ubus_rpc_session': sid, 'config': package})
                rpc('uci', 'delete', {'ubus_rpc_session': sid, 'config': 'firewall',
                                     'section': section, 'option': marker})
                if 'gd_offload_rollback_probe' in rpc('uci', 'get', {
                        'ubus_rpc_session': sid, 'config': 'firewall'})['values']:
                    rpc('uci', 'delete', {'ubus_rpc_session': sid, 'config': 'firewall',
                                         'section': 'gd_offload_rollback_probe'})
                dhcp = rpc('uci', 'get', {'ubus_rpc_session': sid, 'config': 'dhcp'})['values']
                for name in ('gd_offload_dns_probe', 'gd_offload_dns_set'):
                    if name in dhcp:
                        rpc('uci', 'delete', {'ubus_rpc_session': sid, 'config': 'dhcp', 'section': name})
                apply(expect_async=False)
                rpc('session', 'destroy', {'ubus_rpc_session': sid})
                if second: rpc('session', 'destroy', {'ubus_rpc_session': second})
            except Exception as error:
                report['cleanup_requires_device_restore'] = type(error).__name__
        save(a, report)
        d.close()
    print(json.dumps(report))


if __name__ == '__main__': main()
