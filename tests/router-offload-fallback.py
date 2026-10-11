"""Real LuCI apply/rollback when strict uses verified software routing only."""
import json
import os
import secrets
import shlex
import time
import urllib.request
import urllib.parse
from offload_lifecycle_support import arguments, Device, save


def main():
    args = arguments(__doc__)
    device = Device(args)
    report = {'status': 'incomplete', 'cases': []}
    sid = None
    marker = 'gd_offload_fallback_test'

    def rpc(obj, method, data, sensitive=False):
        result = device.run('ubus call ' + shlex.quote(obj) + ' ' + shlex.quote(method) +
                            ' ' + shlex.quote(json.dumps(data)), sensitive=sensitive)[1]
        return json.loads(result) if result.strip() else {}

    def http(endpoint, fields=None):
        query = urllib.parse.urlencode({'sid': sid, 'token': token, **(fields or {})})
        request = urllib.request.Request('http://' + args.router + '/cgi-bin/luci/admin/uci/' +
                                         endpoint + '?' + query, data=b'',
                                         headers={'Cookie': 'sysauth_http=' + sid})
        with urllib.request.urlopen(request, timeout=20) as response:
            return response.status, response.read().decode()

    def stage(value):
        rpc('uci', 'set', {'ubus_rpc_session': sid, 'config': 'firewall',
                          'section': section, 'values': {marker: value}})

    try:
        state = device.run('/usr/libexec/getdomains-offload status')[1]
        assert 'mode=strict' in state
        device.run('/usr/libexec/getdomains-offload software-ok')
        device.run('test ! -S /tmp/getdomains-offload/owner.sock')
        boot = device.run('cat /proc/sys/kernel/random/boot_id')[1]
        sid = rpc('session', 'login', {'username': 'root', 'password':
                  os.environ['GETDOMAINS_TEST_PASSWORD'], 'timeout': 1200}, True)['ubus_rpc_session']
        rpc('session', 'set', {'ubus_rpc_session': sid,
                              'values': {'token': secrets.token_hex(16)}}, True)
        request = urllib.request.Request('http://' + args.router + '/cgi-bin/luci/admin/status/overview',
                                         headers={'Cookie': 'sysauth_http=' + sid})
        with urllib.request.urlopen(request, timeout=20) as response:
            response.read()
        token = rpc('session', 'get', {'ubus_rpc_session': sid})['values']['token']
        values = rpc('uci', 'get', {'ubus_rpc_session': sid, 'config': 'firewall'})['values']
        section = next(key for key, value in values.items() if value['.type'] == 'defaults')
        assert device.run('uci -q get firewall.' + section + '.' + marker, False)[0] != 0
        stage('native-unchecked')
        assert http('apply_unchecked')[0] in (200, 204)
        report['cases'].append({'case': 'ownerless-strict-apply-uses-native-transport', 'passed': True})
        stage('native-rollback')
        status, body = http('apply_rollback')
        assert status == 200 and json.loads(body)['token']
        device.run('test ! -d /tmp/getdomains-offload/submission.lock; '
                   'test ! -f /tmp/getdomains-offload/await-confirm')
        deadline = time.monotonic() + 115
        progress = 0
        while time.monotonic() < deadline:
            if time.monotonic() - progress > 20:
                print(json.dumps({'phase': 'native-software-rollback'}), flush=True)
                progress = time.monotonic()
            if device.run('uci -q get firewall.' + section + '.' + marker)[1].strip() == 'native-unchecked':
                break
            time.sleep(2)
        else:
            raise RuntimeError('Native software rollback did not restore previous configuration')
        report['cases'].append({'case': 'ownerless-rollback-leaves-next-apply-unlocked', 'passed': True})
        rpc('uci', 'revert', {'ubus_rpc_session': sid, 'config': 'firewall'})
        rpc('uci', 'delete', {'ubus_rpc_session': sid, 'config': 'firewall',
                              'section': section, 'option': marker})
        assert http('apply_unchecked')[0] in (200, 204)
        status, body = http('getdomains_command', {'command': '/etc/init.d/sing-box', 'argument': 'restart'})
        assert status == 200 and json.loads(body)['native']
        assert device.run('cat /proc/sys/kernel/random/boot_id')[1] == boot
        device.run('getdomains-check --lang=en')
        report['cases'].append({'case': 'ownerless-service-command-and-diagnostics', 'passed': True})
        report['status'] = 'passed'
    finally:
        if sid:
            device.run('ubus call session destroy ' + shlex.quote(json.dumps(
                {'ubus_rpc_session': sid})), False, sensitive=True)
        save(args, report)
        device.close()
    print(json.dumps(report))


if __name__ == '__main__':
    main()
