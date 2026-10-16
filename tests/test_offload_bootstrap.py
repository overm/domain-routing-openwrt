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
    def run_stage(self, mode='medium', fail='', corrupt='', kill='0', qualified='1', answer=''):
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
green() { printf '%s\n' "$*"; }
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
sh() {
    case "$*" in *getdomains-offload.sh.*' platform-profile')
        case $QUALIFIED in 1) echo qualified;; experimental) echo experimental;; *) return 1;; esac;;
        *) return 1;;
    esac
}
uname() { case $1 in -m) echo aarch64;; -r) echo 6.12.94;; esac; }
nft() { echo 'nftables v1.1.6 (test)'; }
''' + stage + '\nprintf "staging-ok owner=%s mode=%s consent=%s\\n" "$OWNER_REQUIRED" "$OFFLOAD_MODE" "$EXPERIMENTAL_BOARD"\n', encoding='utf-8', newline='\n')
            environment = dict(os.environ, ABI_VERSION='2' if corrupt == 'abi' else '1')
            result = subprocess.run([SH, str(script).replace('\\', '/'),
                                     str(directory).replace('\\', '/'), str(ROOT).replace('\\', '/'),
                                     mode, fail, corrupt, kill, qualified], env=environment,
                                    input=answer.encode(), capture_output=True)
            result.stdout = result.stdout.decode()
            result.stderr = result.stderr.decode()
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

    def test_experimental_medium_requires_explicit_consent(self):
        for answer, owner in [('', 0), ('\n', 0), ('n\n', 0), ('anything\n', 0),
                              ('y', 0), ('y\n', 1), ('yes\n', 1), ('Y\n', 1), ('YES\n', 1)]:
            with self.subTest(answer=answer):
                result, urls, remaining = self.run_stage(qualified='experimental', answer=answer)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('staging-ok owner=' + str(owner), result.stdout)
                self.assertIn('mode=' + ('medium' if owner else 'disable'), result.stdout)
                self.assertIn('consent=' + ('unsupported' if owner else '') + '\n', result.stdout)
                self.assertIn('bypass new firewall restrictions until reboot', result.stderr)
                self.assertEqual(any(u.endswith('/getdomains-offload-owner') for u in urls), bool(owner))
                self.assertEqual(remaining, [])

    def test_consent_cannot_enable_strict_incompatible_disabled_or_kill_switch(self):
        for mode, profile, kill, expected in [('strict', 'experimental', '0', 'disable'),
                                               ('medium', '0', '0', 'disable'),
                                               ('disable', 'experimental', '0', 'disable'),
                                               ('medium', 'experimental', '1', 'medium')]:
            result, urls, remaining = self.run_stage(mode=mode, qualified=profile, kill=kill, answer='yes\n')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('staging-ok owner=0 mode=' + expected + ' consent=\n', result.stdout)
            self.assertNotIn('at your own risk?', result.stdout)
            self.assertFalse(any(u.endswith('/getdomains-offload-owner') for u in urls))
            self.assertEqual(remaining, [])

    def test_each_failed_asset_and_owner_download_is_cleaned_before_mutation(self):
        for name in (*ASSETS, 'getdomains-offload-owner', 'getdomains-offload-owner.sha256'):
            result, _, remaining = self.run_stage(fail=name)
            self.assertNotEqual(result.returncode, 0, name)
            self.assertNotIn('staging-ok', result.stdout)
            self.assertEqual(remaining, [], name)

    def test_reinstallation_replaces_or_removes_previous_board_consent(self):
        source = (ROOT/'getdomains-install.sh').read_text()
        persistence = source[source.index("printf '%s\\n' \"$OFFLOAD_MODE\" > /etc/getdomains/offload-mode"):]
        persistence = persistence.split('\ncat /proc/sys/kernel/random/boot_id', 1)[0]
        persistence = persistence.replace('/etc/getdomains/', './')
        self.assertNotIn('/etc/', persistence)
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            script = directory/'persist.sh'
            script.write_text('set -eu\ncd "$1"\nOFFLOAD_MODE=$2\nEXPERIMENTAL_BOARD=$3\n' + persistence,
                              newline='\n')
            for mode, consent in [('medium', 'vendor,new-router'), ('disable', ''), ('strict', '')]:
                marker = directory/'offload-experimental-board'
                marker.write_text('previous,accepted-router\n')
                result = subprocess.run([SH, str(script).replace('\\', '/'), name.replace('\\', '/'),
                                         mode, consent], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((directory/'offload-mode').read_text(), mode + '\n')
                if consent:
                    self.assertEqual(marker.read_text(), consent + '\n')
                else:
                    self.assertFalse(marker.exists())

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
        self.assertEqual(binary.with_name(binary.name+'.sha256').read_bytes(),
                         (hashlib.sha256(data).hexdigest()+'\n').encode('ascii'))


if __name__ == '__main__':
    unittest.main()
