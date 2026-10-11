"""Physical LAN-to-WAN DNS NAT test of the installed production classifier."""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import select
import socket
import struct
import time
from offload_lifecycle_support import Device


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--router', default=os.environ.get('GETDOMAINS_TEST_HOST'))
    p.add_argument('--known-hosts', required=True)
    p.add_argument('--ssh-libs')
    p.add_argument('--private-evidence-dir', required=True)
    p.add_argument('--client-ip', required=True)
    p.add_argument('--server', default='1.1.1.1')
    p.add_argument('--flows', type=int, default=8)
    p.add_argument('--seconds', type=int, default=20)
    p.add_argument('--port', type=int, default=39000)
    p.add_argument('--output', required=True)
    p.add_argument('--learn-target', action='store_true')
    p.add_argument('--protocol', choices=['udp', 'tcp'], default='udp')
    p.add_argument('--service', choices=['dns', 'ntp'], default='dns')
    p.add_argument('--interval', type=float, default=.025, help='DNS query interval per flow, seconds')
    p.add_argument('--expect', choices=['hardware', 'connectivity'], default='hardware')
    a = p.parse_args()
    if a.service == 'ntp' and a.protocol != 'udp': p.error('NTP requires UDP')
    service_port = 123 if a.service == 'ntp' else 53
    if os.environ.get('GETDOMAINS_ALLOW_DESTRUCTIVE_TESTS') != '1': p.error('Explicit test opt-in required')
    for address in (a.router, a.client_ip, a.server): ipaddress.IPv4Address(address)
    if not 1 <= a.flows <= 128 or not 3 <= a.seconds <= 300 or not 1024 <= a.port <= 64000-a.flows*2:
        p.error('Invalid load bounds')
    if not .01 <= a.interval <= 2 or a.service == 'dns' and a.flows/a.interval > 500:
        p.error('DNS load must stay at or below 500 queries/second')
    d = Device(a)
    streams = []
    learned = False
    report = {'protocol': a.protocol, 'service': a.service, 'expect': a.expect, 'cases': [], 'status': 'incomplete'}
    buffers = {}
    labels = b'\x07example\x03com\x00'
    def batch(streams, seconds):
        sent = received = 0
        until = time.monotonic() + seconds
        while time.monotonic() < until:
            iteration = time.monotonic()
            for stream in streams:
                query = struct.pack('!HHHHHH', sent % 65536, 0x100, 1, 0, 0, 0) + labels + struct.pack('!HH', 1, 1)
                if a.service == 'ntp':
                    now = time.time() + 2208988800
                    query = b'\x23' + b'\0'*39 + struct.pack('!II', int(now), int((now % 1)*2**32))
                if a.protocol == 'tcp': stream.sendall(struct.pack('!H', len(query)) + query)
                else: stream.sendto(query, (a.server, service_port))
                sent += 1
            ready, _, _ = select.select(streams, [], [], .15)
            for stream in ready:
                while True:
                    try:
                        if a.protocol == 'tcp':
                            data = stream.recv(4096)
                            if not data: raise RuntimeError('TCP peer closed the test stream')
                            buffers[stream] += data
                            while len(buffers[stream]) >= 2:
                                length = struct.unpack('!H', buffers[stream][:2])[0]
                                if len(buffers[stream]) < length + 2: break
                                assert length >= 12
                                received += 1; buffers[stream] = buffers[stream][length+2:]
                        else:
                            data, peer = stream.recvfrom(4096)
                            if peer == (a.server, service_port) and len(data) >= (48 if a.service == 'ntp' else 12): received += 1
                    except BlockingIOError: break
            time.sleep(max(0, (1 if a.service == 'ntp' else a.interval) - (time.monotonic()-iteration)))
        return {'sent': sent, 'received': received}
    def snapshot(label):
        text = d.run('conntrack -L -f ipv4 -p ' + a.protocol + ' -s ' + a.client_ip + ' --dport ' + str(service_port))[1]
        rows = [line for line in text.splitlines() if 'dport='+str(service_port)+' ' in line and 'dst='+a.server+' ' in line]
        ppe = d.run('cat /sys/kernel/debug/ppe0/bind /sys/kernel/debug/ppe1/bind')[1]
        d.run('nft list table inet gd_offload')
        return {'case': label, 'tracked': len(rows),
                'direct_mark': sum('mark=1073741824' in line for line in rows),
                'vpn_mark': sum('mark=1073741825' in line for line in rows),
                'vpn_hw_offload': sum('mark=1073741825' in line and '[HW_OFFLOAD]' in line for line in rows),
                'hw_offload': sum('[HW_OFFLOAD]' in line for line in rows),
                'ppe_bound': sum(' BND ' in line for line in ppe.splitlines())}
    try:
        status = d.run('/usr/libexec/getdomains-offload status')[1]
        assert 'state=READY' in status and 'reboot_required=0' in status
        for index in range(a.flows):
            stream = socket.socket(socket.AF_INET, socket.SOCK_STREAM if a.protocol == 'tcp' else socket.SOCK_DGRAM)
            stream.bind((a.client_ip, a.port+index))
            if a.protocol == 'tcp':
                stream.settimeout(10); stream.connect((a.server, 53)); buffers[stream] = b''
            stream.setblocking(False); streams.append(stream)
        traffic = batch(streams, a.seconds)
        first = snapshot('direct-nat')
        first.update(traffic)
        report['cases'].append(first)
        assert traffic['received'] > a.flows*2, first
        assert first['direct_mark'] == a.flows, first
        if a.expect == 'hardware': assert first['hw_offload'] > 0 and first['ppe_bound'] > 0, first
        if a.learn_target:
            code, _ = d.run('nft get element inet fw4 vpn_domains { ' + a.server + ' }', False)
            assert code != 0, 'Test target already selected; choose another public DNS target'
            d.run('nft add element inet fw4 vpn_domains { ' + a.server + ' timeout 120s }')
            learned = True
            sticky = batch(streams, 5)
            second = snapshot('existing-direct-remains-sticky')
            second.update(sticky)
            assert second['direct_mark'] == a.flows and second['hw_offload'] > 0
            report['cases'].append(second)
            new = []
            for index in range(a.flows):
                stream = socket.socket(socket.AF_INET, socket.SOCK_STREAM if a.protocol == 'tcp' else socket.SOCK_DGRAM)
                stream.bind((a.client_ip, a.port+a.flows+index))
                if a.protocol == 'tcp':
                    stream.settimeout(10); stream.connect((a.server, 53)); buffers[stream] = b''
                stream.setblocking(False)
                streams.append(stream); new.append(stream)
            vpn = batch(new, 5)
            third = snapshot('new-selected-not-accelerated')
            third.update(vpn)
            assert third['vpn_mark'] == a.flows and third['vpn_hw_offload'] == 0, third
            assert vpn['received'] > a.flows*2, third
            report['cases'].append(third)
        report['status'] = 'passed'
    finally:
        if learned: d.run('nft delete element inet fw4 vpn_domains { ' + a.server + ' }', False)
        for stream in streams: stream.close()
        Path(a.output).write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
        d.close()
    print(json.dumps(report))


if __name__ == '__main__': main()
