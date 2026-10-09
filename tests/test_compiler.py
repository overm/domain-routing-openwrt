"""Host-safe tests: execute only the pure awk compiler, never device actions."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SH = os.environ.get('GETDOMAINS_TEST_SH') or shutil.which('sh')
if not SH and os.name == 'nt':
    SH = r'C:\Program Files\Git\bin\sh.exe'


class CompilerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run([SH, '-c', 'PATH=/usr/bin:$PATH; command -v awk'], check=True, capture_output=True)

    def compile(self, domains=('example.test',), config='', ipv6=0, wdns='192.0.2.53', raw=None):
        with tempfile.TemporaryDirectory(prefix='getdomains-test-') as tmp:
            tmp = Path(tmp)
            source, snapshot, static = [tmp / n for n in ('source', 'snapshot', 'static')]
            source.write_text(raw if raw is not None else ''.join(
                f'nftset=/{d}/4#inet#fw4#vpn_domains\n' for d in domains), encoding='ascii')
            snapshot.write_text(config, encoding='ascii')
            args = [str(p).replace('\\', '/') for p in (ROOT/'getdomains-compile.awk', source, snapshot, static)]
            result = subprocess.run([SH, '-c',
                'PATH=/usr/bin:$PATH; awk -v wdns="$5" -v ipv6="$6" -v static_file="$4" -f "$1" "$2" "$3"',
                'sh', *args, wdns, str(ipv6)], text=True, capture_output=True)
            self.static = static.read_text() if static.exists() else ''
            return result

    def success(self, **kwargs):
        result = self.compile(**kwargs)
        self.assertEqual(result.returncode, 0, result.stderr)
        return set(result.stdout.splitlines())

    def test_split_dns_is_domain_scoped(self):
        self.assertEqual(self.success(), {'nftset=/example.test/4#inet#fw4#vpn_domains',
                                        'server=/example.test/192.0.2.53'})

    def test_no_wdns_keeps_provider_resolution(self):
        self.assertEqual(self.success(wdns=''), {'nftset=/example.test/4#inet#fw4#vpn_domains'})

    def test_ipv6_answers_use_only_ipv6_set(self):
        self.assertIn('nftset=/example.test/4#inet#fw4#vpn_domains,6#inet#fw4#vpn_domains6',
                      self.success(ipv6=1))

    def test_case_and_duplicates_are_normalized(self):
        self.assertEqual(len(self.success(domains=('EXAMPLE.test', 'example.test'))), 2)

    def test_manual_vpn_domain_gets_wdns(self):
        lines = self.success(config='M\tmanual.test\t4#inet#fw4#vpn_domains\n')
        self.assertIn('server=/manual.test/192.0.2.53', lines)

    def test_manual_ipv6_only_selection_gets_wdns(self):
        self.assertIn('server=/manual.test/192.0.2.53', self.success(
            config='M\tmanual.test\t6#inet#fw4#vpn_domains6\n', ipv6=1))

    def test_manual_multiple_sets_are_preserved(self):
        self.assertIn('nftset=/manual.test/4#inet#fw4#vpn_domains,4#inet#fw4#other4',
            self.success(config='M\tmanual.test\t4#inet#fw4#vpn_domains,4#inet#fw4#other4\n'))

    def test_duplicate_manual_rows_union_sets_once(self):
        lines = self.success(config='M\texample.test\t4#inet#fw4#other4\n'
            'M\texample.test\t4#inet#fw4#vpn_domains,4#inet#fw4#other4\n')
        nft = [s for s in lines if s.startswith('nftset=/example.test/')]
        self.assertEqual(nft, ['nftset=/example.test/4#inet#fw4#other4,4#inet#fw4#vpn_domains'])

    def test_manual_parent_owns_subtree(self):
        lines = self.success(domains=('example.test', 'child.example.test'),
            config='M\texample.test\t4#inet#fw4#other4\n')
        self.assertEqual(lines, {'nftset=/example.test/4#inet#fw4#other4', 'server=/example.test/#'})

    def test_manual_child_overrides_auto_parent(self):
        lines = self.success(config='M\tchild.example.test\t4#inet#fw4#other4\n')
        self.assertIn('server=/example.test/192.0.2.53', lines)
        self.assertIn('server=/child.example.test/#', lines)

    def test_domain_boundaries_do_not_match_unrelated_suffix(self):
        lines = self.success(domains=('notexample.test',),
            config='M\texample.test\t4#inet#fw4#other4\n')
        self.assertIn('server=/notexample.test/192.0.2.53', lines)

    def test_explicit_forward_owns_subtree(self):
        lines = self.success(domains=('child.example.test',), config='X\texample.test\n')
        self.assertFalse(any(s.startswith('server=') for s in lines))
        self.assertTrue(any(s.startswith('nftset=') for s in lines))

    def test_local_zone_owns_exact_name(self):
        self.assertFalse(any(s.startswith('server=') for s in self.success(config='X\texample.test\n')))

    def test_catchall_override(self):
        self.assertFalse(any(s.startswith('server=') for s in self.success(config='X\t*\n')))

    def test_local_ipv4_and_ipv6_are_seeded(self):
        self.success(ipv6=1, config='H\texample.test\t198.51.100.9\nH\texample.test\t2001:db8::9\n')
        self.assertEqual(set(self.static.splitlines()), {
            'add element inet fw4 vpn_domains { 198.51.100.9 timeout 2d }',
            'add element inet fw4 vpn_domains6 { 2001:db8::9 timeout 2d }'})

    def test_static_host_uses_most_specific_manual_set(self):
        self.success(config='M\tchild.example.test\t4#inet#fw4#other4\nH\tchild.example.test\t198.51.100.9\n')
        self.assertEqual(self.static, '')

    def test_shared_static_ip_is_not_duplicated(self):
        self.success(config='H\tone.example.test\t198.51.100.9\nH\ttwo.example.test\t198.51.100.9\n')
        self.assertEqual(len(self.static.splitlines()), 1)

    def test_address_zone_seeds_selected_descendants(self):
        self.success(domains=('child.example.test',), config='P\texample.test\t198.51.100.9\n')
        self.assertIn('vpn_domains { 198.51.100.9 timeout 2d }', self.static)

    def test_catchall_address_seeds_selected_names(self):
        self.success(config='P\t*\t198.51.100.9\n')
        self.assertIn('vpn_domains { 198.51.100.9 timeout 2d }', self.static)

    def test_blackhole_address_does_not_enter_routing_set(self):
        self.success(config='P\t*\t0.0.0.0\nP\t*\t::\n', ipv6=1)
        self.assertEqual(self.static, '')

    def test_local_cname_chain_seeds_alias_policy(self):
        self.success(config='C\texample.test\tintermediate.test\n'
            'C\tintermediate.test\tlocal.test\nH\tlocal.test\t198.51.100.9\n')
        self.assertIn('vpn_domains { 198.51.100.9 timeout 2d }', self.static)

    def test_more_specific_local_address_beats_parent_mapping(self):
        self.success(domains=('child.example.test',),
            config='P\texample.test\t198.51.100.8\nP\tchild.example.test\t198.51.100.9\n')
        self.assertNotIn('198.51.100.8', self.static)
        self.assertIn('198.51.100.9', self.static)

    def test_local_host_beats_address_mapping(self):
        self.success(config='P\texample.test\t198.51.100.8\nH\texample.test\t198.51.100.9\n')
        self.assertNotIn('198.51.100.8', self.static)
        self.assertIn('198.51.100.9', self.static)

    def test_source_rejects_config_injection_empty_lines_and_extra_targets(self):
        for raw in ('server=/#/192.0.2.99\n', '\n',
                    'nftset=/example.test/4#inet#fw4#vpn_domains,6#inet#fw4#vpn_domains6\n',
                    'nftset=/example..test/4#inet#fw4#vpn_domains\n'):
            with self.subTest(raw=raw):
                result = self.compile(raw=raw)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')

    def test_crlf_download_is_supported(self):
        self.success(raw='nftset=/example.test/4#inet#fw4#vpn_domains\r\n')

    def test_entry_limit(self):
        self.success(domains=('example.test',)*20000)
        self.assertNotEqual(self.compile(domains=('example.test',)*20001).returncode, 0)

    def test_invalid_manual_set_and_snapshot_errors_fail_closed(self):
        for config in ('M\texample.test\t4#inet#fw4#bad;set\n', 'E\tunknown set family\n'):
            with self.subTest(config=config):
                result = self.compile(config=config)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')

    def test_removing_manual_row_restores_auto_policy(self):
        old = self.success(config='M\texample.test\t4#inet#fw4#other4\n')
        new = self.success()
        self.assertIn('server=/example.test/#', old)
        self.assertIn('server=/example.test/192.0.2.53', new)

    def test_list_removal_does_not_emit_stale_rule(self):
        self.assertEqual(self.success(domains=('removed.test',)), {
            'server=/removed.test/192.0.2.53', 'nftset=/removed.test/4#inet#fw4#vpn_domains'})
        self.assertFalse(any('removed.test' in s for s in self.success()))


if __name__ == '__main__':
    unittest.main()
