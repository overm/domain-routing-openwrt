"""Isolated offload asset staging; never load installer device mutations."""
import hashlib
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from test_compiler import ROOT, SH

ASSETS = ('getdomains-offload-luci.uc', 'getdomains-offload-job.uc',
          'getdomains-offload-setup.uc', 'getdomains-offload-menu.json',
          'getdomains-offload.js', 'getdomains-offload-status.js')


class OffloadBootstrapTests(unittest.TestCase):
    def run_stage(self, mode='medium', fail='', corrupt='', kill='0', qualified='1'):
        source = (ROOT/'getdomains-install.sh').read_text()
        stage = 'cleanup_support() {' + source.split('cleanup_support() {', 1)[1].split('\nDEFER_APPLY=0', 1)[0]
        self.assertNotRegex(stage, r'(?<![\w-])(?:uci|apk|reboot|ip|mv)(?![\w.-])')
        stage = stage.replace('/tmp/', './staged/').replace('/www/luci-static/resources/ui.js', './ui.js')
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            (directory/'staged').mkdir()
            (directory/'ui.js').write_text('fixture')
            script = directory/'stage.sh'
            script.write_text(r'''
#!/bin/sh
set -eu
PATH=/usr/bin:$PATH
cd "$1"
ROOT=$2; OFFLOAD_MODE=$3; FAILED=$4; CORRUPT=$5; KILL_SWITCH=$6; QUALIFIED=$7
SCRIPT_BASE_URL=https://example.invalid/pinned-ref
red() { printf '%s\n' "$*" >&2; }
support_download_error() { red "invalid $1"; }
curl() {
    url= output=
    while [ "$#" -gt 0 ]; do
        case $1 in -fL) shift;; --connect-timeout|--max-time|--retry|--retry-delay) shift 2;;
            -o) output=$2; shift 2;; *) url=$1; shift;; esac
    done
    file=${url##*/}; printf '%s\n' "$url" >> downloads
    [ "$file" != "$FAILED" ] || { printf partial > "$output"; return 22; }
    case $file in
        getdomains-offload-owner)
            printf '#!/bin/sh\necho "getdomains-offload-owner %s"\n' "${ABI_VERSION:-1}" > "$output";;
        getdomains-offload-owner.sha256)
            if [ "$CORRUPT" = checksum-format ]; then printf 'bad!';
            elif [ "$CORRUPT" = checksum-mismatch ]; then printf '%064d' 0;
            else sha256sum ./staged/getdomains-offload-owner.$$ | awk '{ print $1 }'; fi > "$output";;
        *) cp "$ROOT/$file" "$output";;
    esac
    [ "$file" != "$CORRUPT" ] || printf 'INVALID' >> "$output"
}
ucode() {
    [ "${CORRUPT:-}" != preflight ] || [ "$2" != check ] || return 1
    [ "$1" != -c ] || ! tail -c 7 "$2" | grep -q INVALID
}
jsonfilter() {
    case "$*" in *board.json*) [ "$QUALIFIED" = 1 ] && printf 'xiaomi,mi-router-ax3000t\n' || printf 'unsupported\n';;
        *) ! tail -c 7 "$2" | grep -q INVALID;; esac
}
uname() { case $1 in -m) echo aarch64;; -r) echo 6.12.94;; esac; }
nft() { echo 'nftables v1.1.6 (test)'; }
''' + stage + '\nprintf "staging-ok owner=%s\\n" "$OWNER_REQUIRED"\n', encoding='utf-8', newline='\n')
            environment = dict(os.environ, ABI_VERSION='2' if corrupt == 'abi' else '1')
            result = subprocess.run([SH, str(script).replace('\\', '/'),
                                     str(directory).replace('\\', '/'), str(ROOT).replace('\\', '/'),
                                     mode, fail, corrupt, kill, qualified], env=environment,
                                    text=True, capture_output=True)
            downloads = (directory/'downloads').read_text().splitlines()
            return result, downloads, list((directory/'staged').iterdir())

    def test_modes_and_unsupported_profiles_stage_coherent_source(self):
        for mode, kill, qualified, owner in [('medium', '0', '1', 1), ('strict', '0', '1', 1),
                                            ('disable', '0', '1', 0), ('strict', '1', '1', 0),
                                            ('medium', '0', '0', 0)]:
            result, urls, remaining = self.run_stage(mode=mode, kill=kill, qualified=qualified)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('staging-ok owner='+str(owner), result.stdout)
            self.assertEqual([u.rsplit('/', 1)[1] for u in urls[:6]], list(ASSETS))
            self.assertTrue(all(u.startswith('https://example.invalid/pinned-ref/') for u in urls))
            self.assertEqual(remaining, [])

    def test_each_failed_asset_and_owner_download_is_cleaned_before_mutation(self):
        for name in (*ASSETS, 'getdomains-offload-owner', 'getdomains-offload-owner.sha256'):
            result, _, remaining = self.run_stage(fail=name)
            self.assertNotEqual(result.returncode, 0, name)
            self.assertNotIn('staging-ok', result.stdout)
            self.assertEqual(remaining, [], name)

    def test_invalid_ucode_json_checksum_abi_and_strict_preflight_abort(self):
        for name in (*ASSETS[:4], 'checksum-format', 'checksum-mismatch', 'abi', 'preflight'):
            result, _, remaining = self.run_stage(mode='strict', corrupt=name)
            self.assertNotEqual(result.returncode, 0, (name, result.stdout, result.stderr))
            self.assertEqual(remaining, [], name)

    def test_shipped_binary_is_aarch64_musl_and_matches_checksum(self):
        binary = ROOT/'offload/bin/aarch64_cortex-a53/getdomains-offload-owner'
        data = binary.read_bytes()
        self.assertEqual(data[:6], b'\x7fELF\x02\x01')
        self.assertEqual(struct.unpack_from('<H', data, 18)[0], 183)
        self.assertIn(b'/lib/ld-musl-aarch64.so.1', data)
        self.assertNotIn(b'/tmp/getdomains-offload-unit', data)
        self.assertEqual(hashlib.sha256(data).hexdigest(),
                         binary.with_name(binary.name+'.sha256').read_text().strip())


if __name__ == '__main__':
    unittest.main()
