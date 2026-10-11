"""Opt-in real LuCI interface/service commands through the strict job API."""
import json
import os
import secrets
import shlex
import time
import urllib.error
import urllib.parse
import urllib.request
from offload_lifecycle_support import arguments, Device, save


def main():
    args = arguments(__doc__)
    device = Device(args)
    report = {'status': 'incomplete', 'cases': []}
    sid = None
    wan_down = False

    def rpc(obj, method, fields, sensitive=False):
        text = device.run('ubus call ' + shlex.quote(obj) + ' ' + shlex.quote(method) +
                          ' ' + shlex.quote(json.dumps(fields)), sensitive=sensitive)[1]
        return json.loads(text) if text.strip() else {}

    def http(endpoint, fields=None, post=True):
        query = urllib.parse.urlencode({'sid': sid, 'token': token, **(fields or {})})
        request = urllib.request.Request('http://' + args.router + '/cgi-bin/luci/admin/uci/' +
                                         endpoint + '?' + query, data=b'' if post else None,
                                         headers={'Cookie': 'sysauth_http=' + sid})
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.status, json.loads(response.read())

    def command(path, argument):
        status, body = http('getdomains_command', {'command': path, 'argument': argument})
        assert status == 202, (status, body)
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            try:
                status, result = http('getdomains_job', {'job': body['getdomains_job']}, False)
                if status == 200 and not result.get('pending'):
                    assert result['status'] == 200 and result['body']['code'] == 0, result
                    device.reconnect()
                    assert device.run('cat /proc/sys/kernel/random/boot_id')[1] == boot
                    assert device.run('test ! -d /tmp/getdomains-offload/submission.lock')[0] == 0
                    return
            except (OSError, urllib.error.URLError):
                try:
                    device.reconnect(deadline=15)
                    if device.run('cat /proc/sys/kernel/random/boot_id')[1] != boot:
                        raise RuntimeError('Unexpected reboot during native command')
                except (OSError, device.paramiko.SSHException):
                    pass
            time.sleep(1)
        raise RuntimeError('LuCI command did not complete without reboot')

    try:
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            state = device.run('/usr/libexec/getdomains-offload status')[1]
            if 'mode=strict\nstate=READY' in state:
                break
            time.sleep(2)
        else:
            raise RuntimeError('Initial strict policy did not settle')
        boot = device.run('cat /proc/sys/kernel/random/boot_id')[1]
        tunnel = device.run('sha256sum /etc/sing-box/config.json')[1]
        sid = rpc('session', 'login', {'username': 'root', 'password':
                  os.environ['GETDOMAINS_TEST_PASSWORD'], 'timeout': 1200}, True)['ubus_rpc_session']
        rpc('session', 'set', {'ubus_rpc_session': sid,
                              'values': {'token': secrets.token_hex(16)}}, True)
        request = urllib.request.Request('http://' + args.router + '/cgi-bin/luci/admin/status/overview',
                                         headers={'Cookie': 'sysauth_http=' + sid})
        with urllib.request.urlopen(request, timeout=20) as response:
            response.read()
        token = rpc('session', 'get', {'ubus_rpc_session': sid})['values']['token']
        operations = [('/etc/init.d/firewall', 'reload'), ('/sbin/ifdown', 'wan'),
                               ('/sbin/ifup', 'wan'), ('/etc/init.d/network', 'reload'),
                               ('/etc/init.d/sing-box', 'restart')]
        only = os.environ.get('GETDOMAINS_TEST_COMMAND_ONLY')
        if only:
            assert only in ('network', 'sing-box'), 'Unsupported targeted command'
            operations = [item for item in operations if item[0] == '/etc/init.d/' + only]
        for path, argument in operations:
            print(json.dumps({'phase': 'native-command', 'command': path, 'argument': argument}), flush=True)
            if path == '/sbin/ifdown':
                wan_down = True
            command(path, argument)
            if path == '/sbin/ifdown':
                assert not rpc('network.interface.wan', 'status', {}).get('up')
            elif path == '/sbin/ifup':
                until = time.monotonic() + 60
                while time.monotonic() < until:
                    if rpc('network.interface.wan', 'status', {}).get('up'):
                        break
                    time.sleep(1)
                else:
                    raise RuntimeError('WAN did not come back after its native restart')
                wan_down = False
            assert device.run('sha256sum /etc/sing-box/config.json')[1] == tunnel
            report['cases'].append({'case': path.rsplit('/', 1)[-1] + '-' + argument,
                                    'without_reboot': True, 'passed': True})
        device.run('getdomains-check --lang=en')
        report['status'] = 'passed'
    finally:
        if wan_down:
            device.reconnect()
            device.run('/usr/libexec/getdomains-offload submit /sbin/ifup wan')
        if sid:
            device.reconnect()
            device.run('ubus call session destroy ' + shlex.quote(json.dumps(
                {'ubus_rpc_session': sid})), False, sensitive=True)
        save(args, report)
        device.close()
    print(json.dumps(report))


if __name__ == '__main__':
    main()
