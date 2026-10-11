"""Host-safe controller tests. Device dispatcher and installer are never run."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from test_compiler import ROOT, SH


class ControllerTests(unittest.TestCase):
    def test_failed_policy_query_never_qualifies_admission(self):
        source = (ROOT / 'getdomains-offload.sh').read_text()
        function = 'gd_safe_policy() {' + source.split('gd_safe_policy() {', 1)[1].split('\ngd_fingerprint()', 1)[0]
        result, _, _ = self.run_functions(function + r'''
gd_mode() { printf 'medium\n'; }
gd_kill_switch() { return 1; }
uci() { printf '0\n'; }
ip() { return 1; }
nft() {
 case "$*" in
  'list tables') printf 'table inet fw4\n';;
  '-j list chains') printf '{"nftables":[]}\n';;
  'list chain inet fw4 mangle_prerouting') printf 'getdomains: save connection route direct\n';;
 esac
}
ucode() { cat >/dev/null; }
if gd_safe_policy; then exit 0; else exit 7; fi
''')
        self.assertEqual(result.returncode, 7, result.stderr)

    def test_failed_cache_query_cannot_verify_software_fallback(self):
        result, _, _ = self.run_functions(r'''
nft() {
 case "$*" in '-j list flowtables') printf '{"nftables":[]}\n';; esac
 return 1
}
ucode() { cat >/dev/null; }
uci() { printf '0\n'; }
if gd_software_ok; then exit 0; else exit 7; fi
''')
        self.assertEqual(result.returncode, 7, result.stderr)

    def test_ppe_read_failure_is_not_an_empty_hardware_engine(self):
        source = (ROOT / 'getdomains-offload.sh').read_text()
        function = 'gd_empty() {' + source.split('gd_empty() {', 1)[1].split('\ngd_software_ok()', 1)[0]
        with tempfile.TemporaryDirectory(prefix='gd-ppe-read-') as name:
            directory = Path(name)
            (directory / 'ppe0').write_text('')
            (directory / 'ppe1').write_text('')
            function = function.replace('/sys/kernel/debug/ppe0/bind', '"$1/ppe0"').replace(
                '/sys/kernel/debug/ppe1/bind', '"$1/ppe1"')
            script = directory / 'read.sh'
            script.write_text('set -eu\nPATH=/usr/bin:$PATH\n' + function +
                              '\ncat() { printf "%s\\n" "$DUMP"; return "$READ_ERROR"; }\n'
                              'if gd_empty "$1"; then exit 0; else exit 7; fi\n', newline='\n')
            for error, dump, expected in [('0', '', 0), ('0', 'entry BND tuple', 7), ('1', '', 7)]:
                result = subprocess.run([SH, str(script).replace('\\', '/'), name.replace('\\', '/')],
                                        env=dict(os.environ, READ_ERROR=error, DUMP=dump),
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stderr)

    def run_functions(self, body, failure='', busy=0, epoch_changes=0, extra_env=None, assume_owner=False):
        definitions = (ROOT / 'getdomains-offload.sh').read_text().split(
            '\n# Device dispatcher:', 1)[0]
        with tempfile.TemporaryDirectory(prefix='gd-offload-test-') as name:
            directory = Path(name)
            definitions = definitions.replace('GD_DIR=/tmp/getdomains-offload', 'GD_DIR=$1')
            if assume_owner:
                definitions = definitions.replace('[ ! -S "$GD_DIR/owner.sock" ]', 'false')
            mocks = r'''
PATH=/usr/bin:$PATH
trace() { printf '%s\n' "$*" >> "$GD_DIR/trace"; }
gd_state() { trace "state:$1"; }
gd_call() {
    trace "owner:$1"
    [ "$1" != "$FAILURE" ] || return 1
    case $1 in
        EPOCH)
            n=$(cat "$GD_DIR/epochs" 2>/dev/null || printf 0)
            printf '%s\n' "$((n+1))" > "$GD_DIR/epochs"
            printf 'EPOCH %s\n' "$((109 + n * EPOCH_CHANGES))";;
        *) printf 'OK\n';;
    esac
}
gd_ct_clear() { trace ct-clear; [ "$FAILURE" != ct ]; }
gd_snapshot_ports() { trace snapshot; printf 'lan3\nwan\n' > "$GD_DIR/ports"; }
ip() { trace "ip:$*"; [ "$FAILURE" != ip ]; }
sleep() { trace wait; }
gd_empty() { trace ppe-sample; POLLS=$((POLLS+1)); [ "$POLLS" -gt "$BUSY" ]; }
gd_render() { trace render; printf 'ADMISSION\n' > "$GD_DIR/admission.nft"; }
gd_safe_policy() { [ "$FAILURE" != policy ]; }
gd_fingerprint() { printf 'fingerprint\n'; }
POLLS=0
'''
            script = directory / 'functions.sh'
            script.write_text(definitions + mocks + body, encoding='utf-8', newline='\n')
            environment = dict(os.environ, FAILURE=failure, BUSY=str(busy),
                               EPOCH_CHANGES=str(epoch_changes))
            environment.update(extra_env or {})
            result = subprocess.run([SH, str(script).replace('\\', '/'),
                                     str(directory).replace('\\', '/')],
                                    env=environment, capture_output=True, text=True)
            files = {p.name: p.read_text() for p in directory.iterdir() if p.is_file()}
            return result, files.get('trace', '').splitlines(), files

    def test_barrier_retains_flowtable_until_physical_empty_and_final_ct_clear(self):
        result, trace, files = self.run_functions('gd_prepare\n', busy=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(trace.index('owner:HOLD'), trace.index('ct-clear'))
        self.assertLess(trace.index('snapshot'), trace.index('ip:link set dev eth0 down'))
        self.assertEqual(trace.count('ppe-sample'), 5)
        self.assertEqual(trace.count('ct-clear'), 2)
        self.assertLess(max(i for i, x in enumerate(trace) if x == 'ct-clear'),
                        trace.index('owner:RETIRE'))
        self.assertEqual(trace[-1], 'state:HELD')
        self.assertEqual(files['drained'], '109\n')

    def test_timeout_does_not_unregister_or_restore_links(self):
        result, trace, files = self.run_functions('gd_prepare\n', busy=100)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('owner:RETIRE', trace)
        self.assertNotIn('ip:link set dev eth0 up', trace)
        self.assertNotIn('drained', files)

    def test_generation_change_rejects_old_drain_acknowledgement(self):
        result, trace, files = self.run_functions('gd_prepare\n', epoch_changes=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('owner:RETIRE', trace)
        self.assertNotIn('drained', files)

    def test_failed_preparation_never_retires_or_restores(self):
        for failure in ('HOLD', 'ct', 'ip', 'RETIRE'):
            with self.subTest(failure=failure):
                result, trace, _ = self.run_functions('gd_prepare\n', failure=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('state:HELD', trace)
                self.assertNotIn('ip:link set dev eth0 up', trace)

    def test_failure_is_propagated_even_when_caller_uses_a_conditional(self):
        for failure in ('HOLD', 'EPOCH', 'ct', 'ip', 'RETIRE', 'CONFIGURE', 'RELEASE', 'OPEN'):
            with self.subTest(failure=failure):
                result, trace, _ = self.run_functions(
                    'if gd_prepare && gd_resume; then exit 0; else exit 7; fi\n', failure=failure)
                self.assertEqual(result.returncode, 7, (failure, trace, result.stderr))

    def test_policy_is_configured_before_guard_and_links_are_released(self):
        result, trace, _ = self.run_functions('gd_prepare\ngd_resume\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(trace.index('state:POLICY_APPLIED'), trace.index('owner:CONFIGURE'))
        self.assertLess(trace.index('owner:CONFIGURE'), trace.index('owner:RELEASE'))
        self.assertLess(trace.index('owner:RELEASE'), trace.index('ip:link set dev eth0 up'))
        self.assertEqual(trace[-1], 'state:READY')

    def test_checked_apply_and_unsupported_policy_leave_admission_closed(self):
        for body, failure in (
                ('gd_prepare\ntouch "$GD_DIR/await-confirm"\ngd_resume\n', ''),
                ('gd_prepare\ngd_resume\n', 'policy')):
            result, trace, files = self.run_functions(body, failure=failure)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(files['admission.nft'], 'flush chain inet gd_offload admission\n')
            self.assertIn('owner:RELEASE', trace)

    def test_failed_configuration_does_not_release_guard(self):
        result, trace, _ = self.run_functions('gd_prepare\ngd_resume\n', failure='CONFIGURE')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('owner:RELEASE', trace)
        self.assertNotIn('ip:link set dev eth0 up', trace)

    def test_interface_names_reject_shell_and_nft_injection(self):
        for value, valid in [('lan3', True), ('br-lan', True), ('wan.10', True),
                             ('', False), ('wan;reboot', False), ('"wan"', False),
                             ('a' * 33, False), ('wan\nlan3', False)]:
            result, _, _ = self.run_functions('gd_identifier "$VALUE"\n', extra_env={'VALUE': value})
            self.assertEqual(result.returncode == 0, valid, (value, result.stderr))

    def test_queue_deadline_excludes_checked_confirmation_wait(self):
        for age, awaiting, overdue in [(1, False, False), (181, False, True), (601, True, False)]:
            body = '''
mkdir "$GD_DIR/submission.lock"
now=$(cut -d. -f1 /proc/uptime)
printf '%s\\n' "$((now - AGE))" > "$GD_DIR/submission.lock/start"
[ "$AWAITING" != 1 ] || touch "$GD_DIR/await-confirm"
if gd_submission_overdue; then printf overdue; else printf healthy; fi
'''
            result, _, _ = self.run_functions(body, extra_env={'AGE': str(age), 'AWAITING': str(int(awaiting))})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, 'overdue' if overdue else 'healthy')

    def test_queue_unlock_removes_deadline_before_directory(self):
        result, _, _ = self.run_functions('mkdir "$GD_DIR/submission.lock"\ntouch "$GD_DIR/submission.lock/start"\ngd_unreserve\n[ ! -d "$GD_DIR/submission.lock" ]\n')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_root_commands_do_not_race_checked_luci_apply(self):
        body = '''
mkdir "$GD_DIR/submission.lock"
gd_transaction() { trace transaction; }
if gd_submit /bin/true; then exit 9; fi
if gd_requested_transaction /bin/true; then exit 9; fi
GD_OFFLOAD_FW4_CALLBACK=1 gd_requested_transaction /bin/true
'''
        result, trace, _ = self.run_functions(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace, ['transaction'])

    def test_deferred_fw4_waits_for_physical_transaction_lock(self):
        body = '''
mkdir "$GD_DIR/transaction.lock"
sleep() { trace wait; rmdir "$GD_DIR/transaction.lock"; }
GD_OFFLOAD_FW4_CALLBACK=1 gd_lock
gd_unlock
'''
        result, trace, _ = self.run_functions(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace, ['wait'])

    def test_busy_transaction_is_retryable_and_never_reboots(self):
        body = '''
gd_mode() { printf strict; }
gd_lock() { return 1; }
gd_fail() { trace failed; }
gd_transaction /bin/true
'''
        result, trace, _ = self.run_functions(body, assume_owner=True)
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertEqual(trace, [])

    def test_boot_settle_opens_only_after_stable_wan_and_empty_hardware(self):
        body = '''
touch "$GD_DIR/boot-settling"
ubus() { printf '{"up":true}'; }
jsonfilter() { printf true; }
ip() { printf 'default via test dev wan\\n'; }
gd_boot_settle
'''
        result, trace, files = self.run_functions(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace.count('wait'), 5)
        self.assertLess(trace.index('ppe-sample'), trace.index('owner:OPEN'))
        self.assertEqual(trace[-1], 'state:READY')
        self.assertNotIn('boot-settling', files)

    def test_boot_without_wan_uses_software_and_does_not_reboot(self):
        body = '''
touch "$GD_DIR/boot-settling"
ubus() { printf '{"up":false}'; }
jsonfilter() { printf false; }
gd_boot_settle
'''
        result, trace, _ = self.run_functions(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('owner:OPEN', trace)
        self.assertEqual(trace[-1], 'state:SOFTWARE_STARTUP')

    def test_root_submission_waits_for_boot_settle(self):
        body = '''
touch "$GD_DIR/boot-settling"
if gd_submit /bin/true; then exit 9; fi
if gd_requested_transaction /bin/true; then exit 9; fi
'''
        result, trace, _ = self.run_functions(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace, [])

    def test_rollback_quarantine_survives_automatic_reconciliation(self):
        body = '''
touch "$GD_DIR/rolled-back"
gd_safe_policy() { [ ! -f "$GD_DIR/rolled-back" ]; }
gd_prepare
gd_resume
'''
        result, trace, files = self.run_functions(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('owner:OPEN', trace)
        self.assertEqual(trace[-1], 'state:SOFTWARE_AFTER_ROLLBACK')
        self.assertEqual(files['admission.nft'], 'flush chain inet gd_offload admission\n')

    def test_platform_allowlist_rejects_other_boards_kernels_and_versions(self):
        definitions = (ROOT/'getdomains-offload.sh').read_text().split('\n# Device dispatcher:', 1)[0]
        definitions = definitions.replace('/sys/kernel/debug/', '$GD_DIR/debug/').replace('/sys/class/net/', '$GD_DIR/net/')
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            for path in ['debug/ppe0', 'debug/ppe1', 'net/eth0', 'net/wan']:
                (directory/path).mkdir(parents=True)
            for path in ['debug/ppe0/bind', 'debug/ppe1/bind']:
                (directory/path).touch()
            script = directory/'qualified.sh'
            script.write_text(definitions + r'''
GD_DIR=$1
jsonfilter() { printf '%s\n' "$MODEL"; }
uname() { if [ "$1" = -m ]; then printf '%s\n' "$ARCH"; else printf '%s\n' "$KERNEL"; fi; }
nft() { printf 'nftables v%s (test)\n' "$NFT_VERSION"; }
if gd_supported; then exit 0; else exit 7; fi
''', newline='\n')
            base = dict(os.environ, MODEL='xiaomi,mi-router-ax3000t', ARCH='aarch64', KERNEL='6.12.94', NFT_VERSION='1.1.6')
            for overrides in [{}, {'MODEL': 'another-board'}, {'ARCH': 'x86_64'},
                              {'KERNEL': '6.12.95'}, {'NFT_VERSION': '1.1.5'}]:
                result = subprocess.run([SH, str(script).replace('\\', '/'), str(directory).replace('\\', '/')],
                                        env={**base, **overrides}, capture_output=True, text=True)
                self.assertEqual(result.returncode, 7 if overrides else 0, result.stderr)


class OptionTests(unittest.TestCase):
    def run_options(self, args):
        source = (ROOT/'getdomains-install.sh').read_text().split('\n. /etc/os-release', 1)[0]
        return subprocess.run([SH, '-c', source + '\nprintf "mode=%s\\n" "$OFFLOAD_MODE"',
                               'options', *args], capture_output=True, text=True)

    def test_medium_default_and_explicit_modes(self):
        for args, expected in [([], 'medium'), (['--offload', 'medium'], 'medium'),
                               (['--offload', 'strict'], 'strict'),
                               (['--offload', 'disable'], 'disable'),
                               (['--offload', 'strict', '--kill-switch'], 'strict')]:
            result = self.run_options(args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('mode=' + expected, result.stdout)

    def test_invalid_and_missing_mode_fail_before_device_actions(self):
        for args in [['--offload'], ['--offload', 'fast'], ['--offload', ''],
                     ['--offload', 'medium;reboot']]:
            self.assertEqual(self.run_options(args).returncode, 2)

    def test_help_documents_modes(self):
        result = self.run_options(['--help'])
        self.assertEqual(result.returncode, 0)
        self.assertIn('--offload medium|strict|disable', result.stdout)


if __name__ == '__main__':
    unittest.main()
