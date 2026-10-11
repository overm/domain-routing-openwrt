"""Opt-in removal with a live owner, native-file and static-tag checks."""
import json
import time
from offload_lifecycle_support import arguments, Device, save


def main():
    args = arguments(__doc__)
    device = Device(args)
    report = {'status': 'incomplete', 'cases': []}
    try:
        device.run('test -S /tmp/getdomains-offload/owner.sock')
        boot = device.run('cat /proc/sys/kernel/random/boot_id')[1]
        tunnel = device.run('sha256sum /etc/sing-box/config.json')[1]
        originals = {}
        for path, backup in [('sbin/fw4', 'fw4'), ('www/luci-static/resources/ui.js', 'ui'),
                             ('www/luci-static/resources/view/network/interfaces.js', 'interfaces'),
                             ('www/luci-static/resources/view/system/startup.js', 'startup')]:
            originals[path] = device.run('sha256sum /etc/getdomains/' + backup + '.original')[1].split()[0]
        device.run('test ! -e /etc/getdomains/offload-uninstall-fixture; '
                   '! uci -q get dhcp.gd_offload_static_tag_fixture')
        device.upload('''#!/bin/sh
set -eu
/etc/init.d/getdomains stop
uci set dhcp.wdns=tag
uci set dhcp.wdns.dhcp_option='6,192.0.2.53'
uci set dhcp.gd_offload_static_tag_fixture=host
uci set dhcp.gd_offload_static_tag_fixture.name='offload-uninstall-fixture'
uci set dhcp.gd_offload_static_tag_fixture.mac='02:00:00:00:99:77'
uci add_list dhcp.gd_offload_static_tag_fixture.tag='wdns'
uci add_list dhcp.gd_offload_static_tag_fixture.tag='preserved-fixture'
uci commit dhcp
exec /usr/bin/getdomains-uninstall
''', '/tmp/getdomains-offload-uninstall-test.sh')
        device.run('setsid sh /tmp/getdomains-offload-uninstall-test.sh '
                   '</dev/null >/root/getdomains-offload-uninstall-test.log 2>&1 &')
        time.sleep(8)
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            try:
                device.reconnect(deadline=15)
                if device.run('cat /proc/sys/kernel/random/boot_id')[1] != boot:
                    time.sleep(12)
                    break
            except (OSError, device.paramiko.SSHException, RuntimeError):
                pass
            time.sleep(2)
        else:
            raise RuntimeError('Uninstall did not reboot to revoke owned hardware')
        for path, digest in originals.items():
            assert device.run('sha256sum /' + path)[1].split()[0] == digest, path
        device.run('test ! -e /usr/libexec/getdomains-offload; '
                   'test ! -e /etc/init.d/getdomains-offload; '
                   'test ! -e /usr/share/luci/menu.d/zz-getdomains-offload.json')
        assert device.run('nft list table inet gd_offload', False)[0] != 0
        assert ' BND ' not in device.run('cat /sys/kernel/debug/ppe0/bind /sys/kernel/debug/ppe1/bind')[1]
        assert device.run('sha256sum /etc/sing-box/config.json')[1] == tunnel
        report['cases'].append({'case': 'owner-removal-reboots-restores-native-files-and-clears-ppe', 'passed': True})
        assert device.run('uci -q get dhcp.wdns', False)[0] != 0
        assert device.run('uci -q get dhcp.gd_offload_static_tag_fixture.tag')[1].strip() == 'wdns preserved-fixture'
        assert device.run('uci -q get dhcp.gd_offload_static_tag_fixture')[1].strip() == 'host'
        report['cases'].append({'case': 'wdns-definition-removed-static-lease-tags-retained', 'passed': True})
        device.run('uci delete dhcp.gd_offload_static_tag_fixture; uci commit dhcp')
        report['status'] = 'passed'
    finally:
        save(args, report)
        device.close()
    print(json.dumps(report))


if __name__ == '__main__':
    main()
