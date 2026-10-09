"""Test only the isolated support-download stage, never the full installer.

curl is mocked, validation uses real sh/awk, and staging stays in a temporary
directory. No package, configuration, service or installation action is loaded.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from test_compiler import ROOT, SH


DEFAULT_SOURCE = 'https://raw.githubusercontent.com/overm/domain-routing-openwrt/master'
HELPERS = ('getdomains-check.sh', 'getdomains-uninstall.sh',
           'getdomains-runtime.sh', 'getdomains-compile.awk')


class BootstrapTests(unittest.TestCase):
    def run_downloads(self, override=None, failed='', invalid=''):
        source = (ROOT / 'getdomains-install.sh').read_text(encoding='utf-8')
        definitions = source.split('\nADD_IP_CHECK_DOMAIN=1\n', 1)[0]
        stage = source.split('\nSCRIPT_BASE_URL=', 1)[1].split(
            '\nmkdir -p /usr/libexec\n', 1)[0]
        stage = 'SCRIPT_BASE_URL=' + stage
        self.assertNotRegex(stage, r'\b(?:apk|uci|service|nft|mv|chmod)\b')
        stage = stage.replace('/tmp/', './staged/')
        expected = override or DEFAULT_SOURCE
        env = dict(os.environ)
        env.pop('GETDOMAINS_SCRIPT_BASE_URL', None)
        if override is not None:
            env['GETDOMAINS_SCRIPT_BASE_URL'] = override
        with tempfile.TemporaryDirectory(prefix='getdomains-bootstrap-test-') as tmp:
            tmp = Path(tmp)
            (tmp / 'staged').mkdir()
            script = tmp / 'test.sh'
            script.write_text(definitions + r'''
PATH=/usr/bin:$PATH
ROOT=$1
EXPECTED_BASE=$2
REPOSITORY=$3
FAILED_FILE=$4
INVALID_FILE=$5
cd "$ROOT"
curl() {
    download_url=
    download_output=
    while [ "$#" -gt 0 ]; do
        case $1 in
            -fL) shift ;;
            --connect-timeout|--max-time|--retry|--retry-delay) shift 2 ;;
            -o) download_output=$2; shift 2 ;;
            *) download_url=$1; shift ;;
        esac
    done
    printf '%s\n' "$download_url" >> "$ROOT/downloads"
    download_name=${download_url##*/}
    [ "$download_url" = "$EXPECTED_BASE/$download_name" ] || return 99
    if [ "$download_name" = "$FAILED_FILE" ]; then
        printf 'partial download\n' > "$download_output"
        return 22
    fi
    if [ "$download_name" = "$INVALID_FILE" ]; then
        case $download_name in
            *.sh) printf 'if then\n' > "$download_output" ;;
            *.awk) printf 'BEGIN {\n' > "$download_output" ;;
        esac
    else
        cp "$REPOSITORY/$download_name" "$download_output"
    fi
}
''' + stage, encoding='utf-8', newline='\n')
            result = subprocess.run(
                [SH, str(script).replace('\\', '/'), str(tmp).replace('\\', '/'),
                 expected, str(ROOT).replace('\\', '/'), failed, invalid],
                env=env, capture_output=True, text=True)
            downloads = (tmp / 'downloads').read_text().splitlines()
            staged = {p.name.split('.sh.')[0] + '.sh' if '.sh.' in p.name
                      else 'getdomains-compile.awk': p.read_bytes()
                      for p in (tmp / 'staged').iterdir()}
            return result, downloads, staged

    def assert_successful_source(self, override=None):
        result, downloads, staged = self.run_downloads(override=override)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(downloads, [f'{override or DEFAULT_SOURCE}/{name}'
                                     for name in HELPERS])
        self.assertEqual(staged, {name: (ROOT / name).read_bytes() for name in HELPERS})

    def test_default_and_empty_override_use_master(self):
        for override in (None, ''):
            with self.subTest(override=override):
                self.assert_successful_source(override)

    def test_every_helper_uses_the_explicit_source(self):
        for override in (
                DEFAULT_SOURCE.rsplit('/', 1)[0] + '/codex-split-dns-sticky-routing',
                DEFAULT_SOURCE.rsplit('/', 1)[0] + '/' + 'a' * 40,
                'file:///tmp/domain-routing-source'):
            with self.subTest(override=override):
                self.assert_successful_source(override)

    def assert_aborted_download(self, name, **kwargs):
        base = DEFAULT_SOURCE.rsplit('/', 1)[0] + '/test-branch'
        result, downloads, staged = self.run_downloads(override=base, **kwargs)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(downloads, [f'{base}/{helper}'
                                     for helper in HELPERS[:HELPERS.index(name) + 1]])
        self.assertEqual(staged, {})
        self.assertIn(f'Source: {base}/{name}', result.stderr)
        self.assertIn('GETDOMAINS_SCRIPT_BASE_URL', result.stderr)
        self.assertIn('No router configuration was changed.', result.stderr)

    def test_partial_downloads_abort_and_remove_all_staged_helpers(self):
        for name in HELPERS:
            with self.subTest(name=name):
                self.assert_aborted_download(name, failed=name)

    def test_invalid_syntax_aborts_and_removes_all_staged_helpers(self):
        for name in HELPERS:
            with self.subTest(name=name):
                self.assert_aborted_download(name, invalid=name)


if __name__ == '__main__':
    unittest.main()
