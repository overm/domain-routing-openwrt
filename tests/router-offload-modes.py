"""Opt-in OpenWrt deployment harness; credentials and evidence remain private."""
import argparse
import json
import os
from pathlib import Path
import shlex
import sys
import time
from types import SimpleNamespace
from offload_lifecycle_support import Device

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['stage', 'upload', 'install', 'reboot', 'inspect', 'restore'])
    parser.add_argument('--mode', choices=['medium', 'strict', 'disable'], default='medium')
    parser.add_argument('--kill-switch', action='store_true')
    parser.add_argument('--router', default=os.environ.get('GETDOMAINS_TEST_HOST'))
    parser.add_argument('--known-hosts', required=True)
    parser.add_argument('--ssh-libs')
    parser.add_argument('--private-evidence-dir', required=True)
    parser.add_argument('--backup', default='/root/getdomains-lifecycle-offload-modes-20261011')
    args = parser.parse_args()
    if os.environ.get('GETDOMAINS_ALLOW_DESTRUCTIVE_TESTS') != '1':
        parser.error('Explicit destructive-test authorization is required')
    if not args.router or not os.environ.get('GETDOMAINS_TEST_PASSWORD'):
        parser.error('Provide target and password through the private environment')
    import re
    if not re.fullmatch('/root/getdomains-lifecycle-[A-Za-z0-9_-]+', args.backup):
        parser.error('Invalid backup path')
    d = Device(args)
    backup = shlex.quote(args.backup)
    source = '/tmp/getdomains-offload-source'
    try:
        if args.action == 'stage':
            d.run('test ! -e ' + backup)
            d.run('mkdir -m 0700 ' + backup)
            paths = ['etc/config/network', 'etc/config/firewall', 'etc/config/dhcp',
                     'etc/config/sing-box', 'etc/sing-box', 'etc/getdomains',
                     'etc/init.d/getdomains', 'etc/rc.d', 'etc/crontabs/root',
                     'etc/hotplug.d/iface/30-vpnroute', 'etc/iproute2/rt_tables',
                     'usr/bin/getdomains-check', 'usr/bin/getdomains-uninstall',
                     'usr/libexec/getdomains-runtime', 'usr/libexec/getdomains-compile.awk',
                     'sbin/fw4', 'www/luci-static/resources/ui.js',
                     'www/luci-static/resources/view/network/interfaces.js',
                     'www/luci-static/resources/view/system/startup.js']
            d.run('tar -cf ' + backup + '/originals.tar -C / ' + ' '.join(paths))
            d.run('sha256sum ' + ' '.join('/'+p for p in paths if p not in (
                'etc/sing-box', 'etc/getdomains', 'etc/rc.d')) + ' > ' + backup + '/hashes.before')
            d.run('apk info | sort > ' + backup + '/packages.before')
            restore = '''#!/bin/sh
set -eu
backup=$1
mkdir -p /tmp/getdomains-offload
touch /tmp/getdomains-offload/maintenance
/usr/libexec/getdomains-offload-owner --client CLOSE >/dev/null 2>&1 || true
/etc/init.d/getdomains-offload disable 2>/dev/null || true
/etc/init.d/getdomains-offload stop 2>/dev/null || true
rm -f /etc/init.d/getdomains-offload /etc/rc.d/*getdomains-offload \\
 /etc/init.d/getdomains-offload-test-recovery /etc/rc.d/*getdomains-offload-test-recovery \\
 /usr/libexec/getdomains-offload /usr/libexec/getdomains-offload-owner \\
 /usr/libexec/getdomains-offload-job.uc /usr/libexec/getdomains-offload-setup.uc \\
 /usr/share/ucode/luci/controller/admin/getdomains_offload.uc \\
 /usr/share/luci/menu.d/zz-getdomains-offload.json \\
 /www/luci-static/resources/getdomains-offload.js /www/luci-static/resources/view/getdomains_offload.js \\
 /etc/getdomains/offload-mode /etc/getdomains/offload-reboot-required \\
 /etc/getdomains/fw4.original /etc/getdomains/ui.original \\
 /etc/getdomains/interfaces.original /etc/getdomains/startup.original
tar -xf "$backup/originals.tar" -C /
[ ! -f "$backup/extra-originals.tar" ] || tar -xf "$backup/extra-originals.tar" -C /
touch "$backup/watchdog.stop"
sync
reboot
'''
            d.upload(restore, args.backup + '/restore.sh')
            watchdog = '''#!/bin/sh
backup=$1
count=0
while [ "$count" -lt 3600 ]; do
 [ ! -f "$backup/watchdog.stop" ] || exit 0
 sleep 5
 count=$((count+5))
done
exec sh "$backup/restore.sh" "$backup"
'''
            d.upload(watchdog, args.backup + '/watchdog.sh')
            d.run('setsid sh ' + backup + '/watchdog.sh ' + backup +
                  ' >' + backup + '/watchdog.log 2>&1 </dev/null &')
        if args.action in ('stage', 'upload'):
            d.run('test -f ' + backup + '/originals.tar')
            d.run('mkdir -p ' + source + '/offload/bin/aarch64_cortex-a53')
            for path in ROOT.glob('getdomains-*'):
                if path.is_file(): d.upload(path.read_bytes(), source + '/' + path.name)
            binary = ROOT/'offload/bin/aarch64_cortex-a53/getdomains-offload-owner'
            d.upload(binary.read_bytes(), source + '/offload/bin/aarch64_cortex-a53/getdomains-offload-owner')
            # Match raw Git downloads even from a Windows checkout.
            checksum = binary.with_name(binary.name+'.sha256').read_text().strip() + '\n'
            d.upload(checksum, source + '/offload/bin/aarch64_cortex-a53/getdomains-offload-owner.sha256')
            d.run('chmod 0755 ' + source + '/offload/bin/aarch64_cortex-a53/getdomains-offload-owner')
            code, output = d.run('for f in ' + source + '/*.sh; do sh -n "$f" || exit; done; '
                                'for f in ' + source + '/*.uc; do ucode -c "$f" >/dev/null || exit; done; '
                                + source + '/offload/bin/aarch64_cortex-a53/getdomains-offload-owner --version')
            print(output.strip())
            # Recovery survives a test reboot, unlike a /tmp background actor.
            recovery = '''#!/bin/sh /etc/rc.common
START=08
STOP=01
boot() {
 backup=BACKUP
 count=$(cat "$backup/boots" 2>/dev/null || echo 0)
 count=$((count+1)); echo "$count" > "$backup/boots"
 if [ "$count" -gt 3 ]; then exec sh "$backup/restore.sh" "$backup"; fi
 setsid sh "$backup/watchdog.sh" "$backup" > "$backup/watchdog.log" 2>&1 </dev/null &
}
'''.replace('BACKUP', shlex.quote(args.backup))
            d.upload(recovery, '/etc/init.d/getdomains-offload-test-recovery')
            d.run('chmod 0755 /etc/init.d/getdomains-offload-test-recovery; '
                  '/etc/init.d/getdomains-offload-test-recovery enable; '
                  'printf "0\\n" > ' + backup + '/boots')
        elif args.action == 'install':
            # Packages already present on this target. Mock ONLY apk update/add
            # to prevent unrelated firmware package upgrades during the matrix.
            d.run('mkdir -p ' + source + '/test-bin')
            d.upload('#!/bin/sh\ncase $1 in update|add) exit 0;; *) exec /sbin/apk "$@";; esac\n',
                     source + '/test-bin/apk')
            d.run('chmod 0755 ' + source + '/test-bin/apk')
            command = "printf '1\\nn\\n' | env PATH=" + source + '/test-bin:$PATH ' + \
                'GETDOMAINS_SCRIPT_BASE_URL=file://' + source + ' sh ' + source + \
                '/getdomains-install.sh --offload ' + args.mode + (' --kill-switch' if args.kill_switch else '')
            code, output = d.run(command, timeout=180)
            (Path(args.private_evidence_dir)/'installer.private.log').write_text(output, encoding='utf-8')
            print(json.dumps({'installed': True, 'mode': args.mode, 'kill_switch': args.kill_switch}))
        elif args.action == 'inspect':
            print(d.run('/usr/libexec/getdomains-offload status; fw4 check; getdomains-check')[1])
        elif args.action == 'reboot':
            before = d.run('cat /proc/sys/kernel/random/boot_id')[1]
            d.run('setsid sh -c "sleep 1; reboot" </dev/null >/tmp/gd-test-reboot.log 2>&1 &')
            time.sleep(8)
            deadline = time.monotonic()+180
            while time.monotonic() < deadline:
                try:
                    d.reconnect(deadline=30)
                    boot = d.run('cat /proc/sys/kernel/random/boot_id')[1]
                    if boot != before:
                        time.sleep(12)
                        print(d.run('/usr/libexec/getdomains-offload status; fw4 check')[1], flush=True)
                        break
                except (OSError, d.paramiko.SSHException, RuntimeError): pass
            else: raise RuntimeError('Device did not recover from the test reboot')
        else:
            d.run('setsid sh ' + backup + '/restore.sh ' + backup +
                  ' >' + backup + '/restore.log 2>&1 </dev/null &')
            print('Restoration and reboot launched; verify after reconnect.')
    finally:
        d.close()


if __name__ == '__main__':
    main()
