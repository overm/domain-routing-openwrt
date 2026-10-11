"""Reinstall/reboot each production offload mode on an expendable router."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import shlex
import sys
import time
from offload_lifecycle_support import Device

CASES = {'strict': ('strict', False, 'READY'), 'medium': ('medium', False, 'READY'),
         'disable': ('disable', False, 'DISABLED'),
         'strict-kill': ('strict', True, 'DISABLED_KILL_SWITCH'),
         'medium-kill': ('medium', True, 'DISABLED_KILL_SWITCH')}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--router', default=os.environ.get('GETDOMAINS_TEST_HOST'))
    parser.add_argument('--known-hosts', required=True)
    parser.add_argument('--ssh-libs')
    parser.add_argument('--private-evidence-dir', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--case', choices=['all', *CASES], default='all')
    args = parser.parse_args()
    if os.environ.get('GETDOMAINS_ALLOW_DESTRUCTIVE_TESTS') != '1': parser.error('Explicit test opt-in required')
    device = Device(args)
    harness = Path(__file__).with_name('router-offload-modes.py')
    report = {'status': 'incomplete', 'cases': []}
    tunnel_hash = device.run('sha256sum /etc/sing-box/config.json')[1]
    try:
        for name in CASES if args.case == 'all' else [args.case]:
            mode, kill, expected = CASES[name]
            base = [sys.executable, '-B', str(harness), '--router', args.router,
                    '--known-hosts', args.known_hosts, '--private-evidence-dir',
                    str(Path(args.private_evidence_dir)/name)]
            if args.ssh_libs: base.extend(['--ssh-libs', args.ssh_libs])
            live_owner = device.run('test -S /tmp/getdomains-offload/owner.sock', False)[0] == 0
            policy_snapshot = ('for chain in forward forward_lan mangle_prerouting mangle_output srcnat; '
                               'do nft -s list chain inet fw4 "$chain"; done; ip -4 rule show')
            before = device.run(policy_snapshot)[1]
            for action in ['upload', 'install', 'reboot']:
                print(json.dumps({'case': name, 'phase': action}), flush=True)
                command = base + [action, '--mode', mode] + (['--kill-switch'] if kill else [])
                subprocess.run(command, check=True)
                if action == 'install':
                    assert 'reboot_required=1' in device.run('/usr/libexec/getdomains-offload status')[1]
                    if live_owner:
                        assert device.run(policy_snapshot)[1] == before, 'Reinstallation changed live policy before reboot'
                        assert device.run('test -S /tmp/getdomains-offload/owner.sock')[0] == 0
            device.reconnect()
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                status = device.run('/usr/libexec/getdomains-offload status')[1]
                if 'state=STARTING\n' not in status:
                    break
                time.sleep(2)
            assert 'mode='+mode+'\n' in status and 'state='+expected+'\n' in status and 'reboot_required=0' in status, status
            table = device.run('nft list table inet gd_offload', False)
            if expected == 'READY':
                assert table[0] == 0 and 'flow add @direct' in table[1]
            else:
                assert table[0] != 0 and device.run('test -S /tmp/getdomains-offload/owner.sock', False)[0] != 0
                assert ' BND ' not in device.run('cat /sys/kernel/debug/ppe0/bind /sys/kernel/debug/ppe1/bind')[1]
            if kill:
                route = device.run('ip -4 route show table 99 default')[1].strip()
                assert route and '\n' not in route
                try:
                    device.run('ip -4 route del table 99 default')
                    assert device.run('ip -4 route get 198.18.0.10 mark 0x1', False)[0] != 0
                finally:
                    device.run('ip -4 route replace table 99 ' + ' '.join(shlex.quote(part) for part in route.split()))
            device.run('getdomains-check --lang=en')
            assert device.run('sha256sum /etc/sing-box/config.json')[1] == tunnel_hash
            report['cases'].append({'case': name, 'state': expected, 'reboot_required': False,
                                    'tunnel_preserved': True, 'passed': True})
        report['status'] = 'passed'
    finally:
        Path(args.output).write_text(json.dumps(report, indent=2)+'\n')
        device.close()
    print(json.dumps(report))


if __name__ == '__main__':
    main()
