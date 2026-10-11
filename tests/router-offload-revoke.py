"""Physical production TCP revocation using the supported strict root entry point."""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import shlex
import select
import socket
import struct
import time
from offload_lifecycle_support import Device


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--router', default=os.environ.get('GETDOMAINS_TEST_HOST'))
    parser.add_argument('--known-hosts', required=True)
    parser.add_argument('--ssh-libs')
    parser.add_argument('--private-evidence-dir', required=True)
    parser.add_argument('--client-ip', required=True)
    parser.add_argument('--server', default='1.1.1.1')
    parser.add_argument('--output', required=True)
    parser.add_argument('--fault', choices=['worker', 'standby', 'keeper', 'supervisor'])
    parser.add_argument('--mode', choices=['strict', 'medium'], default='strict')
    args = parser.parse_args()
    if args.fault and args.mode != 'strict': parser.error('Fault recovery requires strict mode')
    if os.environ.get('GETDOMAINS_ALLOW_DESTRUCTIVE_TESTS') != '1': parser.error('Explicit test opt-in required')
    for value in (args.router, args.client_ip, args.server): ipaddress.IPv4Address(value)
    device = Device(args)
    stream = None
    changed = False
    report = {'status': 'incomplete', 'cases': []}
    section = 'gd_offload_revoke_test'
    script = '/tmp/getdomains-offload-revoke-test.sh'

    def operation(remove=False):
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            if device.run('test ! -f /tmp/getdomains-offload/boot-settling', False)[0] == 0:
                break
            time.sleep(2)
        else:
            raise RuntimeError('Controller startup did not finish before root operation')
        source = '#!/bin/sh\nset -eu\n'
        if remove: source += 'uci -q delete firewall.'+section+' || true\n'
        else:
            source += "uci set firewall."+section+"=rule\n"
            for key, value in {'name': 'getdomains offload revoke test', 'src': 'lan', 'dest': 'wan',
                               'family': 'ipv4', 'proto': 'tcp', 'dest_ip': args.server,
                               'dest_port': '53', 'target': 'REJECT'}.items():
                source += 'uci set '+shlex.quote('firewall.'+section+'.'+key+'='+value)+'\n'
        source += 'uci commit firewall\nfw4 reload\n'
        device.upload(source, script)
        output = device.run('/usr/libexec/getdomains-offload submit /bin/sh '+script)[1]
        logfile = next(line[4:] for line in output.splitlines() if line.startswith('log='))
        time.sleep(3)
        deadline = time.monotonic()+180
        while time.monotonic() < deadline:
            try:
                device.reconnect(deadline=15)
                state = device.run('/usr/libexec/getdomains-offload status')[1]
                present = device.run('uci -q get firewall.'+section, False)[0] == 0
                expected = 'state=READY' if args.mode == 'strict' else 'state=REBOOT_REQUIRED'
                active = 'getdomains offload revoke test' in device.run('nft list chain inet fw4 forward_lan')[1]
                if expected in state and present != remove and active != remove:
                    assert device.run('cat /proc/sys/kernel/random/boot_id')[1] == boot
                    assert 'FAILED' not in device.run('cat '+shlex.quote(logfile))[1]
                    return
            except (OSError, device.paramiko.SSHException, RuntimeError): pass
            time.sleep(2)
        raise RuntimeError('Strict operation did not finish without reboot')

    def wait_for_fresh_boot(old):
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            try:
                device.reconnect(deadline=15)
                new = device.run('cat /proc/sys/kernel/random/boot_id')[1]
                state = device.run('/usr/libexec/getdomains-offload status')[1]
                if new != old and 'state=READY' in state and 'reboot_required=0' in state:
                    return new
            except (OSError, device.paramiko.SSHException, RuntimeError): pass
            time.sleep(2)
        raise RuntimeError('Controller did not recover on a fresh boot')

    def reboot():
        old = device.run('cat /proc/sys/kernel/random/boot_id')[1]
        device.run('setsid sh -c "sleep 1; reboot" </dev/null >/tmp/gd-test-reboot.log 2>&1 &')
        time.sleep(8)
        return wait_for_fresh_boot(old)

    def connect():
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.settimeout(5); sock.bind((args.client_ip, 0))
        try: sock.connect((args.server, 53)); return sock
        except BaseException: sock.close(); raise

    def physical_rows(sock):
        port = sock.getsockname()[1]
        outbound = f'orig={args.client_ip}:{port}->{args.server}:53 '
        inbound = f'new={args.server}:53->{args.client_ip}:{port} '
        rows = device.run('cat /sys/kernel/debug/ppe0/bind /sys/kernel/debug/ppe1/bind')[1]
        # Admission is reopened after recovery. Unrelated applications on the
        # LAN may already have acquired new hardware entries by this snapshot.
        return [row for row in rows.splitlines() if ' BND ' in row and
                (outbound in row or inbound in row)]

    def connect_after_recovery():
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            try:
                return connect()
            except OSError:
                # Deferred netifd/fw4 events can take another barrier after the
                # previous operation. This retry is only for allowed baselines;
                # the rejection assertions below still use one fresh attempt.
                time.sleep(2)
        raise RuntimeError('Allowed TCP baseline did not recover')

    def exchange(sock):
        query = struct.pack('!HHHHHH', 1, 0x100, 1, 0, 0, 0)+b'\x07example\x03com\x00'+struct.pack('!HH', 1, 1)
        sock.sendall(struct.pack('!H', len(query))+query)
        header = sock.recv(2)
        if len(header) != 2: return False
        length = struct.unpack('!H', header)[0]
        data = b''
        while len(data) < length:
            block = sock.recv(length-len(data))
            if not block: return False
            data += block
        return len(data) >= 12

    def warm(sock):
        # Pipeline queries independently of WAN RTT. Waiting for every response
        # can keep a single flow below the PPE's binding threshold.
        query = struct.pack('!HHHHHH', 1, 0x100, 1, 0, 0, 0)+b'\x07example\x03com\x00'+struct.pack('!HH', 1, 1)
        wire = struct.pack('!H', len(query))+query
        buffer = b''; received = 0
        sock.setblocking(False)
        for _ in range(200):
            sock.sendall(wire)
            if select.select([sock], [], [], 0)[0]: buffer += sock.recv(65536)
            while len(buffer) >= 2:
                length = struct.unpack('!H', buffer[:2])[0]
                if len(buffer) < length+2: break
                buffer = buffer[length+2:]; received += 1
            time.sleep(.01)
        deadline = time.monotonic()+10
        while received < 200 and time.monotonic() < deadline:
            if select.select([sock], [], [], .2)[0]: buffer += sock.recv(65536)
            while len(buffer) >= 2:
                length = struct.unpack('!H', buffer[:2])[0]
                if len(buffer) < length+2: break
                buffer = buffer[length+2:]; received += 1
        assert received == 200 and not buffer, 'Warm-up responses were not fully drained'
        sock.settimeout(5)

    try:
        boot = device.run('cat /proc/sys/kernel/random/boot_id')[1]
        assert 'mode='+args.mode+'\nstate=READY' in device.run('/usr/libexec/getdomains-offload status')[1]
        assert device.run('uci -q get firewall.'+section, False)[0] != 0
        stream = connect_after_recovery()
        began = time.monotonic()
        warm(stream)
        rows = device.run('conntrack -L -p tcp --sport '+str(stream.getsockname()[1]))[1]
        ppe = physical_rows(stream)
        report['warmup_seconds'] = round(time.monotonic()-began, 2)
        report['warmup_hw_flag'] = '[HW_OFFLOAD]' in rows
        report['warmup_ppe_bound'] = len(ppe)
        assert '[HW_OFFLOAD]' in rows and ppe, 'No physical hardware baseline'
        report['cases'].append({'case': 'physical-accelerated-tcp-baseline', 'passed': True})
        if args.fault == 'supervisor':
            pid = int(device.run('cat /tmp/getdomains-offload/supervisor.pid')[1])
            command = device.run('tr "\\000" " " </proc/'+str(pid)+'/cmdline')[1]
            assert '/usr/libexec/getdomains-offload watch' in command
            began = time.monotonic()
            device.run('kill -KILL '+str(pid))
            boot = wait_for_fresh_boot(boot)
            report['supervisor_reboot_recovery_seconds'] = round(time.monotonic()-began, 2)
            assert not physical_rows(stream), 'Old test entries survived the emergency reboot'
            stream.close(); stream = connect_after_recovery(); warm(stream)
            assert physical_rows(stream)
            report['cases'].append({'case': 'supervisor-loss-reboots-and-rebuilds-fresh-hardware', 'passed': True})
        elif args.fault:
            row = device.run('/usr/libexec/getdomains-offload-owner --client STATUS')[1].split()
            old_epoch = row[2]
            index = {'worker': 3, 'standby': 4, 'keeper': 5}[args.fault]
            pid = int(row[index])
            assert device.run('readlink /proc/'+str(pid)+'/exe')[1].strip() == '/usr/libexec/getdomains-offload-owner'
            device.run('kill -KILL '+str(pid))
            deadline = time.monotonic()+120
            while time.monotonic() < deadline:
                try:
                    device.reconnect(deadline=15)
                    status = device.run('/usr/libexec/getdomains-offload status')[1]
                    current = device.run('/usr/libexec/getdomains-offload-owner --client STATUS', False)[1].split()
                    if 'state=READY' in status and current[:2] == ['READY', 'OK'] and current[2] != old_epoch:
                        assert device.run('cat /proc/sys/kernel/random/boot_id')[1] == boot
                        assert not physical_rows(stream), 'Old test flow survived owner recovery'
                        break
                except (OSError, device.paramiko.SSHException, RuntimeError): pass
                time.sleep(2)
            else: raise RuntimeError('Live owner fault did not recover')
            stream.close(); stream = connect_after_recovery(); warm(stream)
            assert physical_rows(stream)
            report['cases'].append({'case': 'live-'+args.fault+'-loss-drains-and-replenishes-without-reboot', 'passed': True})
        changed = True
        operation()
        old_allowed = False
        try: old_allowed = exchange(stream)
        except OSError: pass
        if args.mode == 'strict':
            assert not physical_rows(stream), 'Old physical entries survived the supported barrier'
            assert not old_allowed, 'Old accelerated connection bypassed new rejection'
        else:
            report['medium_before_reboot'] = {'old_connection_allowed': old_allowed,
                                               'test_ppe_bound': len(physical_rows(stream))}
            boot = reboot()
            assert not physical_rows(stream), 'Old physical entries survived reboot'
            try: old_allowed = exchange(stream)
            except OSError: old_allowed = False
            assert not old_allowed
        new_allowed = False
        try:
            probe = connect(); probe.close(); new_allowed = True
        except OSError: pass
        assert not new_allowed, 'New connection bypassed rejection'
        report['cases'].append({'case': ('critical-policy-revokes-old-hardware-and-rejects-new-tcp' if
                                        args.mode == 'strict' else 'reboot-guarantees-new-medium-policy'), 'passed': True})
        operation(True); changed = False
        if args.mode == 'medium': boot = reboot()
        stream.close(); stream = connect_after_recovery()
        assert exchange(stream), 'Connectivity did not recover after rule removal'
        report['cases'].append({'case': ('policy-removal-restores-connectivity-without-reboot' if args.mode == 'strict'
                                        else 'policy-removal-restores-connectivity-after-reboot'), 'passed': True})
        report['status'] = 'passed'
    finally:
        if stream: stream.close()
        if changed:
            try:
                device.reconnect()
                operation(True)
            except Exception as error:
                report['cleanup_requires_device_restore'] = type(error).__name__
        device.run('rm -f '+script, False)
        Path(args.output).write_text(json.dumps(report, indent=2)+'\n')
        device.close()
    print(json.dumps(report))


if __name__ == '__main__':
    main()
