"""Host-only platform/consent probes against a fake sysfs and mocked OpenWrt APIs."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from test_compiler import ROOT, SH


class PlatformTests(unittest.TestCase):
    def run_probe(self, command='probe', model='vendor,other-router', mode='medium',
                  consent=None, chip='mt7981', missing=(), **overrides):
        definitions = (ROOT/'getdomains-offload.sh').read_text().split('\n# Device dispatcher:', 1)[0]
        definitions = definitions.replace('/sys/', '$FIXTURE/sys/').replace(
            '/etc/getdomains/', '$FIXTURE/etc/').replace('GD_DIR=/tmp/getdomains-offload', 'GD_DIR=$FIXTURE/run')
        with tempfile.TemporaryDirectory(prefix='gd-platform-') as name:
            directory = Path(name)
            files = {
                'sys/kernel/debug/ppe0/bind': '', 'sys/kernel/debug/ppe1/bind': '',
                'sys/class/net/eth0/ifindex': '2\n', 'sys/class/net/wan/iflink': '2\n',
                'sys/class/net/lan1/iflink': '2\n', 'sys/class/net/lan2/iflink': '2\n',
                'sys/class/net/eth0/device/of_node/compatible': f'mediatek,{chip}-eth\0',
                'etc/offload-mode': mode + '\n',
            }
            for path, data in files.items():
                target = directory/path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(data, newline='\n')
            for path in ['sys/class/net/br-lan/brif/lan1', 'sys/class/net/br-lan/brif/lan2', 'run']:
                (directory/path).mkdir(parents=True, exist_ok=True)
            if consent is not None:
                (directory/'etc/offload-experimental-board').write_text(consent, newline='\n')
            if overrides.pop('third_ppe', False):
                (directory/'sys/kernel/debug/ppe2').mkdir()
            if overrides.pop('wrong_parent', False):
                (directory/'sys/class/net/wan/iflink').write_text('3\n')
            if overrides.pop('wrong_lan_parent', False):
                (directory/'sys/class/net/lan2/iflink').write_text('3\n')
            if overrides.pop('bridged_wan', False):
                (directory/'sys/class/net/br-lan/brif/wan').mkdir()
            for path in missing:
                target = directory/path
                if target.is_dir():
                    target.rmdir()
                else:
                    target.unlink()
            script = directory/'probe.sh'
            script.write_text('FIXTURE=$2\n' + definitions + r'''
PATH=/usr/bin:$PATH
jsonfilter() {
    case "$*" in
        *model.id*) [ "$MODEL_ERROR" = 0 ] || return 1; printf '%s\n' "$MODEL";;
        *network.lan.ports*) printf '%s\n' "$LAN_PORTS";;
        *l3_device*) cat >/dev/null; printf '%s\n' "$LAN";;
        *device*) cat >/dev/null; printf '%s\n' "$WAN";;
        *) return 1;;
    esac
}
ubus() { printf '{}\n'; }
uname() { case $1 in -m) echo "$ARCH";; -r) echo "$KERNEL";; esac; }
nft() { printf 'nftables v%s (test)\n' "$NFT_VERSION"; }
readlink() { printf '/drivers/%s\n' "$DRIVER"; }
cat() {
    case "$*" in *ppe*/bind*) [ "$PPE_READ_ERROR" = 0 ] || return 1;; esac
    command cat "$@"
}
case $1 in
    probe) gd_platform_profile;;
    supported) if gd_supported; then exit 0; else exit 7; fi;;
    status) gd_status;;
esac
''', encoding='utf-8', newline='\n')
            environment = dict(os.environ, MODEL=model, ARCH='aarch64', KERNEL='6.12.94',
                               NFT_VERSION='1.1.6', DRIVER='mtk_soc_eth', LAN_PORTS='lan1 lan2',
                               LAN='br-lan', WAN='wan', PPE_READ_ERROR='0', MODEL_ERROR='0')
            environment.update(overrides)
            return subprocess.run([SH, str(script).replace('\\', '/'), command, name.replace('\\', '/')],
                                  env=environment, text=True, capture_output=True)

    def test_qualified_profile_and_experimental_chips(self):
        for model, chip, expected in [('xiaomi,mi-router-ax3000t', 'mt7981', 'qualified'),
                                       ('vendor,other-router', 'mt7981', 'experimental'),
                                       ('vendor,other-router', 'mt7986', 'experimental')]:
            result = self.run_probe(model=model, chip=chip)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), expected)

    def test_incompatible_stack_and_hardware_cannot_be_overridden_by_consent(self):
        cases = [{'ARCH': 'mips'}, {'KERNEL': '6.12.95'}, {'NFT_VERSION': '1.1.5'},
                 {'DRIVER': 'other'}, {'chip': 'mt7988'}, {'third_ppe': True},
                 {'PPE_READ_ERROR': '1'}, {'wrong_parent': True}, {'wrong_lan_parent': True},
                 {'bridged_wan': True}, {'LAN': 'br-other'},
                 {'WAN': 'pppoe-wan'}, {'LAN_PORTS': ''}, {'LAN_PORTS': 'lan1 invalid/port'},
                 {'MODEL_ERROR': '1'}, {'model': ''},
                 {'missing': ['sys/kernel/debug/ppe1/bind']},
                 {'missing': ['sys/class/net/eth0/device/of_node/compatible']},
                 {'missing': ['sys/class/net/br-lan/brif/lan2']},
                 {'missing': ['sys/class/net/lan2/iflink']}]
        for case in cases:
            with self.subTest(case=case):
                for command in ['probe', 'supported']:
                    result = self.run_probe(command, consent='vendor,other-router\n', **case)
                    self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_consent_is_board_bound_medium_only_and_not_inferred_from_mode(self):
        for mode, consent, accepted in [('medium', None, False), ('medium', '', False),
                                        ('medium', 'vendor,another-router\n', False),
                                        ('medium', 'vendor,other-router\n', True),
                                        ('strict', 'vendor,other-router\n', False),
                                        ('disable', 'vendor,other-router\n', False)]:
            result = self.run_probe('supported', mode=mode, consent=consent)
            self.assertEqual(result.returncode, 0 if accepted else 7, result.stderr)
        result = self.run_probe('supported', model='xiaomi,mi-router-ax3000t', mode='strict')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_status_identifies_experimental_opt_in(self):
        for consent, expected in [(None, 0), ('vendor,other-router\n', 1)]:
            result = self.run_probe('status', consent=consent)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f'experimental_opt_in={expected}\n', result.stdout)


if __name__ == '__main__':
    unittest.main()
