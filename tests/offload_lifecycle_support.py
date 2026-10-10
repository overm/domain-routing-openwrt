"""Private device I/O for explicitly authorized, destructive research tests."""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import sys
import time


def arguments(description, physical=False):
    p = argparse.ArgumentParser(description=description)
    p.add_argument('--router', default=os.environ.get('GETDOMAINS_TEST_HOST'))
    p.add_argument('--known-hosts', required=True)
    p.add_argument('--ssh-libs')
    p.add_argument('--output', required=True, help='Reviewed, address-free JSON.')
    p.add_argument('--private-evidence-dir', required=True)
    p.add_argument('--owner', default='/tmp/gd-life-lab/owner')
    p.add_argument('--backup', default='/root/getdomains-lifecycle-20261010')
    if physical:
        p.add_argument('--lan-ip', required=True)
        p.add_argument('--wan-ip', required=True)
        p.add_argument('--flows', type=int, default=8)
        p.add_argument('--protocol', choices=('tcp', 'udp'), default='udp')
        p.add_argument('--cycles', type=int, default=3)
        p.add_argument('--port', type=int, default=29000)
        p.add_argument('--post-seconds', type=int, default=30)
        p.add_argument('--guardian-crash', action='store_true')
        p.add_argument('--timeout-probe', action='store_true')
        p.add_argument('--stop-parent', action='store_true', help='Filogic eth0 stop: interrupts LAN management too.')
        p.add_argument('--hold-through-policy', action='store_true', help='Keep Ethernet stopped until the new lab guard is applied locally.')
    a = p.parse_args()
    if os.environ.get('GETDOMAINS_ALLOW_DESTRUCTIVE_TESTS') != '1':
        p.error('Set GETDOMAINS_ALLOW_DESTRUCTIVE_TESTS=1 for the expendable target.')
    if not a.router or not os.environ.get('GETDOMAINS_TEST_PASSWORD'):
        p.error('Provide a router and GETDOMAINS_TEST_PASSWORD.')
    import ipaddress
    for address in [a.router] + ([a.lan_ip, a.wan_ip] if physical else []):
        ipaddress.IPv4Address(address)
    if not re.fullmatch(r'/root/getdomains-lifecycle-[A-Za-z0-9_-]+', a.backup):
        p.error('Backup must be an explicit /root/getdomains-lifecycle-* directory.')
    if not re.fullmatch(r'/tmp/gd-life-lab/[A-Za-z0-9_.-]+', a.owner):
        p.error('Owner must be a lab binary inside /tmp/gd-life-lab.')
    if physical and not (2 <= a.flows <= 2048 and 1 <= a.cycles <= 20 and
                         1024 <= a.port and a.port + (a.flows + 2) * 2 * a.cycles < 32768 and
                         5 <= a.post_seconds <= 86400):
        p.error('Invalid flow count, cycle count, ports or observation duration.')
    if physical and a.hold_through_policy and not a.stop_parent:
        p.error('--hold-through-policy requires --stop-parent.')
    if physical and a.timeout_probe and a.stop_parent:
        p.error('The foreground timeout probe requires LAN management to remain up; omit --stop-parent.')
    return a


class Device:
    def __init__(self, args):
        if args.ssh_libs:
            sys.path.insert(0, args.ssh_libs)
        import paramiko
        self.args = args
        self.paramiko = paramiko
        self.ssh = None
        self.connect()
        self.raw = []
        self.channels = []
        self.folder = Path(args.private_evidence_dir)
        self.folder.mkdir(parents=True, exist_ok=True)

    def connect(self):
        self.ssh = self.paramiko.SSHClient()
        self.ssh.load_host_keys(self.args.known_hosts)
        self.ssh.connect(self.args.router, username='root',
                         password=os.environ['GETDOMAINS_TEST_PASSWORD'],
                         timeout=3, banner_timeout=3, auth_timeout=3,
                         allow_agent=False, look_for_keys=False)

    def reconnect(self, deadline=180):
        if self.ssh: self.ssh.close()
        start = time.monotonic()
        while time.monotonic()-start < deadline:
            try:
                self.connect()
                return
            except self.paramiko.BadHostKeyException:
                raise
            except (OSError, self.paramiko.SSHException):
                if self.ssh: self.ssh.close()
                print(json.dumps({'phase': 'waiting-for-management',
                                  'seconds': round(time.monotonic()-start)}), flush=True)
                time.sleep(2)
        raise RuntimeError('Management did not recover; automatic device watchdog remains armed.')

    def run(self, command, check=True, timeout=60, sensitive=False):
        _, out, err = self.ssh.exec_command(command, timeout=timeout)
        text = out.read().decode(errors='replace') + err.read().decode(errors='replace')
        code = out.channel.recv_exit_status()
        if not sensitive:
            self.raw.append({'command': command, 'exit': code, 'text': text})
        if code and check:
            raise RuntimeError(f'Device command failed with status {code}; see private evidence.')
        return code, text

    def upload(self, content, path):
        stream, out, err = self.ssh.exec_command('cat > ' + shlex.quote(path))
        stream.write(content.encode() if isinstance(content, str) else content)
        stream.flush()
        stream.channel.shutdown_write()
        out.read()
        if out.channel.recv_exit_status():
            raise RuntimeError('Upload failed: ' + err.read().decode(errors='replace'))

    def start_owner(self, initial, socket, table, namespace=None):
        path = socket + '.nft'
        self.upload(initial, path)
        # BusyBox setsid prefers its built-in `ip`, which lacks netns support.
        # Resolve the installed full ip binary and pass an absolute path.
        ip_full = self.run('readlink -f "$(command -v ip)"')[1].strip() if namespace else ''
        prefix = shlex.quote(ip_full) + ' netns exec ' + shlex.quote(namespace) + ' ' if namespace else ''
        cmd = prefix + ' '.join(shlex.quote(x) for x in
                               (self.args.owner, path, socket, table, 'admission'))
        self.run('setsid ' + cmd + ' >' + shlex.quote(socket + '.ready') +
                 ' 2>' + shlex.quote(socket + '.err') + ' </dev/null &')
        time.sleep(.1)
        ready = self.run('cat ' + shlex.quote(socket + '.ready'))[1].strip()
        match = re.fullmatch(r'READY (\d+) (\d+)', ready)
        if not match:
            raise RuntimeError('Owner failed to start; inspect its private stderr file.')
        return tuple(map(int, match.groups()))

    def owner(self, socket, command, check=True):
        return self.run(' '.join(shlex.quote(x) for x in
                                (self.args.owner, '--client', socket, command)), check)

    def close(self):
        (self.folder / 'commands.private.json').write_text(
            json.dumps(self.raw, indent=2), encoding='utf-8')
        self.ssh.close()


def save(args, result):
    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    Path(args.output).write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
