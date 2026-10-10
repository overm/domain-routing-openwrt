"""Destructive physical, independent-duplex flow revocation prototype test."""
import json
import random
import selectors
import shlex
import socket
import struct
import threading
import time
from offload_lifecycle_support import arguments, Device, save


FRAME = struct.Struct('!4sId')


class Traffic:
    def __init__(self, args, router_wan, ports, peer_ports=None):
        self.args, self.router_wan, self.ports = args, router_wan, ports
        self.peer_ports = peer_ports if peer_ports is not None else [p+1 for p in ports]
        self.sockets = []
        self.stop = threading.Event()
        self.threads = []
        self.counts = [[0, 0] for _ in ports]
        self.last_sent = [[None, None] for _ in ports]
        self.attempts = [[0, 0] for _ in ports]
        self.forbidden = [0, 0]
        self.barrier = None
        self.errors = []

    def open(self):
        for port, peer_port in zip(self.ports, self.peer_ports):
            kind = socket.SOCK_DGRAM if self.args.protocol == 'udp' else socket.SOCK_STREAM
            a = socket.socket(socket.AF_INET, kind)
            b = socket.socket(socket.AF_INET, kind)
            self.sockets.extend((a, b))
            for s, address in ((a, (self.args.lan_ip, port)), (b, (self.args.wan_ip, peer_port))):
                s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                s.settimeout(8)
                s.bind(address)
            if kind == socket.SOCK_DGRAM:
                a.connect((self.args.router, peer_port))
                b.connect((self.router_wan, port))
            else:
                barrier = threading.Barrier(2)
                errors = []
                def connect(s, address, delay):
                    try:
                        barrier.wait(4)
                        time.sleep(delay)
                        s.connect(address)
                    except OSError as error:
                        errors.append(type(error).__name__)
                workers = [threading.Thread(target=connect, args=(a, (self.args.router, peer_port), 0)),
                           threading.Thread(target=connect, args=(b, (self.router_wan, port), .02))]
                for t in workers: t.start()
                for t in workers: t.join()
                if errors: raise RuntimeError('TCP simultaneous open failed: ' + str(errors))
            a.setblocking(False)
            b.setblocking(False)

    def start(self):
        # Windows select has a finite fd set. Shard below that limit.
        for begin in range(0, len(self.ports), 64):
            indices = list(range(begin, min(begin + 64, len(self.ports))))
            def sender(indices):
                pending = {}
                while not self.stop.is_set():
                    for i in indices:
                        for direction, tag in ((0, b'LAN!'), (1, b'WAN!')):
                            sock = self.sockets[i * 2 + direction]
                            key = (i, direction)
                            payload = pending.pop(key, None)
                            if payload is None:
                                self.attempts[i][direction] += 1
                                payload = FRAME.pack(tag, i, time.monotonic()).ljust(96, b'#')
                            try:
                                sent = sock.send(payload)
                                if sent < len(payload): pending[key] = payload[sent:]
                            except BlockingIOError:
                                pending[key] = payload
                            except OSError:
                                pass
                    self.stop.wait(.02)
            def receiver(indices):
                selector = selectors.DefaultSelector()
                buffers = {}
                for i in indices:
                    for direction in (0, 1):
                        sock = self.sockets[i * 2 + 1 - direction]
                        selector.register(sock, selectors.EVENT_READ, (i, direction))
                try:
                    while not self.stop.is_set():
                        if not selector.get_map():
                            self.stop.wait(.05)
                            continue
                        for key, _ in selector.select(.05):
                            i, direction = key.data
                            try:
                                data = key.fileobj.recv(65536)
                            except BlockingIOError:
                                continue
                            except OSError:
                                selector.unregister(key.fileobj)
                                continue
                            if not data:
                                selector.unregister(key.fileobj)
                                continue
                            if self.args.protocol == 'tcp':
                                data = buffers.get(key.fileobj, b'') + data
                                size = len(data) // 96 * 96
                                frames = [data[n:n+96] for n in range(0, size, 96)]
                                buffers[key.fileobj] = data[size:]
                            else:
                                frames = [data]
                            for frame in frames:
                                if len(frame) != 96:
                                    self.errors.append('frame-size'); continue
                                tag, index, sent = FRAME.unpack(frame[:FRAME.size])
                                if index != i or tag != (b'LAN!' if direction == 0 else b'WAN!') or frame[FRAME.size:] != b'#' * (96-FRAME.size):
                                    self.errors.append('frame-integrity'); continue
                                self.counts[i][direction] += 1
                                self.last_sent[i][direction] = sent
                                if self.barrier is not None and i < len(self.ports)//2 and sent >= self.barrier:
                                    self.forbidden[direction] += 1
                finally:
                    selector.close()
            for fn in (sender, receiver):
                t = threading.Thread(target=fn, args=(indices,), daemon=True)
                self.threads.append(t); t.start()

    def close(self):
        self.stop.set()
        for t in self.threads: t.join(2)
        for s in self.sockets: s.close()


def main():
    a = arguments(__doc__, physical=True)
    d = Device(a)
    result = {'protocol': a.protocol, 'flows_per_cycle': a.flows, 'cycles': [],
              'observation_seconds': a.post_seconds, 'status': 'incomplete'}
    rwan = json.loads(d.run('ip -j -4 addr show dev wan')[1])[0]['addr_info'][0]['local']
    boot_id = d.run('cat /proc/sys/kernel/random/boot_id')[1].strip()
    traffic = None
    safe = True
    sock = None

    def ppe():
        text = d.run('cat /sys/kernel/debug/ppe0/bind /sys/kernel/debug/ppe1/bind')[1]
        return sum(' BND ' in line for line in text.splitlines())

    def clean_nat():
        d.run('nft delete table inet gd_life_nat 2>/dev/null || true', False)
        d.run('''nft -a list chain inet fw4 forward | sed -n '/comment "gd-life-lab"/s/.* handle //p' |
while read handle; do nft delete rule inet fw4 forward handle "$handle"; done''', False)

    try:
        assert d.run('uci -q get firewall.@defaults[0].flow_offloading')[1].strip() == '0'
        assert ppe() == 0, 'PPE must be empty before starting this scoped fixture.'
        assert 'gd_life_' not in d.run('nft list tables')[1]
        for cycle in range(a.cycles):
            base = a.port + cycle * (a.flows + 2) * 2
            ports = list(range(base, base + a.flows * 2, 2))
            peer_ports = [p+1 for p in ports]
            if a.flows > 16:
                # Adjacent source/destination ports create artificial PPE hash
                # concentration. Spread the large-load tuples reproducibly.
                random.Random(23017+cycle).shuffle(peer_ports)
            high = ports[-1] + 1
            scope_high = high + 4 if a.protocol == 'tcp' else high
            sock = f'/tmp/gd-life-lab/physical{base}-{time.monotonic_ns()}.sock'
            nat = f'''table inet gd_life_nat {{
chain guarded {{ type filter hook forward priority 5; policy accept; }}
chain gd_dnat {{ type nat hook prerouting priority -105; policy accept;
iifname "br-lan" ip daddr {a.router} {a.protocol} dport {base+1}-{scope_high} dnat ip to {a.wan_ip}
iifname "wan" ip daddr {rwan} {a.protocol} dport {base}-{scope_high} dnat ip to {a.lan_ip}
}}
chain gd_snat {{ type nat hook postrouting priority 95; policy accept;
oifname "wan" ip saddr {a.lan_ip} ip daddr {a.wan_ip} {a.protocol} sport {base}-{scope_high} snat ip to {rwan}
oifname "br-lan" ip saddr {a.wan_ip} ip daddr {a.lan_ip} {a.protocol} dport {base}-{scope_high} snat ip to {a.router}
}}
}}
table inet gd_life_ft {{
flags owner,persist;
flowtable direct {{ hook ingress priority 0; devices = {{ "lan3", "wan" }}; flags offload; counter; }}
chain admission {{ type filter hook forward priority 10; policy accept;
meta nfproto ipv4 ct direction original ct state established ct mark 0x40000000 meta mark 0 iifname "br-lan" oifname "wan" ip saddr {a.lan_ip} ip daddr {a.wan_ip} {a.protocol} sport {base}-{high} counter flow add @direct
}}
}}
'''
            worker, guardian = d.start_owner(nat, sock, 'gd_life_ft')
            safe = False
            d.run(f'nft insert rule inet fw4 forward iifname "wan" oifname "br-lan" ip saddr {a.wan_ip} ip daddr {a.lan_ip} ct state established {a.protocol} dport {base}-{scope_high} accept comment "gd-life-lab"')
            traffic = Traffic(a, rwan, ports, peer_ports)
            traffic.open(); traffic.start()
            time.sleep(10)
            warm = ppe()
            counters0 = sum(map(sum, traffic.counts))
            time.sleep(2)
            counters1 = sum(map(sum, traffic.counts))
            assert counters1 > counters0 and not traffic.errors
            assert warm >= (a.flows * 2 if a.flows <= 16 else a.flows), f'Insufficient actual BND coverage: {warm}'
            row = {'cycle': cycle, 'warm_ppe_rows': warm,
                   'warm_receiving_flows_both_directions': sum(all(v) for v in traffic.counts)}
            assert row['warm_receiving_flows_both_directions'] == a.flows
            if a.guardian_crash:
                d.run(f'kill -9 {worker}')
                time.sleep(.3)
                assert 'HELD OK' in d.owner(sock, 'STATUS')[1]
                assert d.run('nft delete table inet gd_life_ft', False)[0] != 0
                d.run('/etc/init.d/firewall reload')
                assert 'flags owner,persist' in d.run('nft list table inet gd_life_ft')[1]
                assert ppe() > 0
                row['worker_crash_and_firewall_reload'] = 'protected table, hardware continues'

            # The controller's pre-change operation drains and unregisters first.
            cmd = 'GETDOMAINS_ALLOW_DESTRUCTIVE_TESTS=1 sh /tmp/gd-life-lab/prepare.sh ' + ' '.join(shlex.quote(str(x)) for x in
                (a.owner, sock, 'wan', 'gd_life_ft', a.protocol, a.lan_ip, a.router, base, high, 45))
            if a.stop_parent:
                d.run('''rm -f /tmp/gd-life-lab/parent.done
( trap "" HUP; sleep 120; [ -f /tmp/gd-life-lab/parent.done ] || reboot ) >/tmp/gd-life-lab/parent-watchdog.log 2>&1 </dev/null &''')
                cmd = 'GD_LIFE_STOP_PARENT=eth0 ' + cmd
                row['quiesce'] = 'wan and common Ethernet parent eth0'
            if a.timeout_probe:
                code, _ = d.run(cmd.rsplit(' ', 1)[0] + ' 0', False)
                assert code != 0
                assert d.run('cat /tmp/gd-life-lab/state')[1].strip() == 'FAILED'
                link = json.loads(d.run('ip -j link show dev wan')[1])[0]
                assert 'UP' not in link['flags']
                assert 'flags owner,persist' in d.run('nft list table inet gd_life_ft')[1]
                row['forced_timeout'] = 'WAN stays down; flowtable remains registered'
                traffic.barrier = time.monotonic()
            begin = time.monotonic()
            blocked = sorted(ports[:len(ports)//2] + peer_ports[:len(ports)//2])
            blocked_text = ','.join(map(str, blocked))
            guard_cmd = f'nft add rule inet gd_life_nat guarded meta l4proto {a.protocol} th sport {{ {blocked_text} }} counter drop'
            if a.stop_parent:
                status_path = f'{a.backup}/parent-{base}.status'
                log_path = f'{a.backup}/parent-{base}.private.log'
                policy_step = ''
                if a.hold_through_policy:
                    cmd = 'GD_LIFE_HOLD_LINKS=1 ' + cmd
                    policy_step = ('if [ "$code" = 0 ]; then\n' + guard_cmd + '\ncode=$?\nfi\n' +
                        'if [ "$code" = 0 ]; then\n' +
                        'printf "POLICY_APPLIED\\n" > /tmp/gd-life-lab/state\n' +
                        'printf "POLICY_APPLIED\\n" >> /tmp/gd-life-lab/transitions.log\n' +
                        'GETDOMAINS_ALLOW_DESTRUCTIVE_TESTS=1 sh /tmp/gd-life-lab/resume.sh wan eth0\ncode=$?\nfi\n')
                d.run(': > /tmp/gd-life-lab/transitions.log')
                script = ('#!/bin/sh\n' + cmd + '\ncode=$?\n' + policy_step +
                          f'cp /tmp/gd-life-lab/drain.log {shlex.quote(a.backup + "/parent-" + str(base) + ".drain.log")}\n' +
                          'ip -j link show > ' + shlex.quote(a.backup + f'/parent-{base}.links.private.json') + '\n' +
                          'printf "%s\\n" "$code" > ' + shlex.quote(status_path) + '\n')
                action_file = f'/tmp/gd-life-lab/action{base}.sh'
                d.upload(script, action_file)
                d.run('rm -f ' + shlex.quote(status_path))
                d.run('setsid sh ' + shlex.quote(action_file) + ' >' + shlex.quote(log_path) +
                      ' 2>&1 </dev/null &', False)
                time.sleep(3)
                d.reconnect()
                for attempt in range(60):
                    try:
                        status_code, status_text = d.run('cat ' + shlex.quote(status_path), False)
                    except (OSError, d.paramiko.SSHException):
                        # Large batches may still be deleting conntrack when
                        # management first reconnects. Retry only this read;
                        # never repeat the detached mutation.
                        d.reconnect()
                        continue
                    if status_code == 0: break
                    time.sleep(1)
                else: raise RuntimeError('Detached action did not publish a completion status.')
                code = int(status_text.strip())
                prepared = d.run('cat ' + shlex.quote(log_path))[1]
                assert d.run('cat /proc/sys/kernel/random/boot_id')[1].strip() == boot_id, 'Watchdog rebooted the device; not a successful live drain.'
            else:
                code, prepared = d.run(cmd, False)
            row['prepare_seconds'] = round(time.monotonic() - begin, 3)
            row['last_received_frame_sent_after_prepare_begin_seconds'] = [
                [round(t-begin, 3) if t is not None else None for t in pair]
                for pair in traffic.last_sent]
            row['drain_polls_seconds_rows'] = [list(map(int, line.split())) for line in d.run('cat /tmp/gd-life-lab/drain.log')[1].splitlines()]
            if code != 0 or 'PREPARED' not in prepared:
                row['status'] = 'drain-timeout'
                row['remaining_ppe_rows'] = ppe()
                row['traffic_after_forced_timeout_while_wan_down'] = list(traffic.forbidden)
                result['cycles'].append(row)
                print(json.dumps(row), flush=True)
                raise RuntimeError('Drain failed; retain WAN block and registered table.')
            safe = True
            if a.stop_parent: d.run('touch /tmp/gd-life-lab/parent.done')
            # Critical policy changes happen only after the prepare barrier.
            if a.hold_through_policy:
                transitions = d.run('cat /tmp/gd-life-lab/transitions.log')[1].splitlines()
                assert transitions == ['HELD', 'POLICY_APPLIED', 'RESTORED'], transitions
                row['policy_applied_before_link_restore'] = True
            else:
                d.run(guard_cmd)
            traffic.barrier = time.monotonic()
            traffic.forbidden = [0, 0]
            controls_before = [sum(v[n] for v in traffic.counts[len(ports)//2:]) for n in (0, 1)]
            controls_before_each = [list(v) for v in traffic.counts[len(ports)//2:]]
            for tick in range(a.post_seconds):
                time.sleep(1)
                if tick % 15 == 0:
                    print(json.dumps({'phase': 'post-revoke', 'cycle': cycle, 'elapsed': tick,
                                      'forbidden': traffic.forbidden}), flush=True)
            controls_after = [sum(v[n] for v in traffic.counts[len(ports)//2:]) for n in (0, 1)]
            row['forbidden_forward_reverse'] = list(traffic.forbidden)
            row['control_forward_reverse'] = [x-y for x, y in zip(controls_after, controls_before)]
            row['after_ppe_rows'] = ppe()
            assert row['forbidden_forward_reverse'] == [0, 0]
            assert row['after_ppe_rows'] == 0 and not traffic.errors
            if a.protocol == 'udp':
                assert all(v > 0 for v in row['control_forward_reverse']), 'Allowed UDP controls must resume in software.'
                row['minimum_allowed_frames_per_flow_direction'] = min(
                    traffic.counts[i+len(ports)//2][n]-before[n]
                    for i, before in enumerate(controls_before_each) for n in (0, 1))
                assert row['minimum_allowed_frames_per_flow_direction'] > 0
            traffic.close(); traffic = None
            if a.protocol == 'udp':
                # Closing and reopening the same tuple previously revived orphans.
                traffic = Traffic(a, rwan, ports, peer_ports)
                traffic.open(); traffic.barrier = time.monotonic(); traffic.start()
                time.sleep(5)
                row['same_tuple_reopen_forbidden'] = list(traffic.forbidden)
                assert traffic.forbidden == [0, 0] and ppe() == 0
                traffic.close(); traffic = None
            else:
                # A physical reset may abort ALL existing TCP sockets. Verify
                # policy on fresh allowed TCP and a new attempt at the old tuple.
                traffic = Traffic(a, rwan, [high+1])
                traffic.open(); traffic.start(); time.sleep(3)
                row['fresh_tcp_control_forward_reverse'] = list(traffic.counts[0])
                assert all(traffic.counts[0]) and not traffic.errors and ppe() == 0
                traffic.close(); traffic = None
                import re
                before_drop = int(re.search(r'counter packets (\d+)', d.run('nft list chain inet gd_life_nat guarded')[1]).group(1))
                traffic = Traffic(a, rwan, [ports[0]], [peer_ports[0]])
                try:
                    traffic.open()
                except RuntimeError:
                    row['same_tuple_tcp_connect'] = 'blocked'
                else:
                    raise RuntimeError('Forbidden old TCP tuple connected after drain.')
                finally:
                    traffic.close(); traffic = None
                after_drop = int(re.search(r'counter packets (\d+)', d.run('nft list chain inet gd_life_nat guarded')[1]).group(1))
                row['same_tuple_tcp_drop_counter_delta'] = after_drop-before_drop
                assert after_drop > before_drop, 'A local socket error alone is not proof of policy enforcement.'
            d.owner(sock, 'STOP')
            clean_nat()
            result['cycles'].append(row)
            print(json.dumps({k: v for k, v in row.items()
                              if k != 'last_received_frame_sent_after_prepare_begin_seconds'}), flush=True)
        result['status'] = 'passed'
    finally:
        if traffic: traffic.close()
        if safe:
            if sock: d.owner(sock, 'STOP', False)
            clean_nat()
            result['cleanup'] = 'flowtable removed only after completed drain'
        else:
            result['cleanup'] = 'recovery required; owned flowtable retained'
        save(a, result)
        d.close()


if __name__ == '__main__':
    main()
