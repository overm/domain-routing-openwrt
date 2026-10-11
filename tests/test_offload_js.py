"""Host-safe JavaScript transport validation; no native browser/network needed."""
import json
from pathlib import Path
import shutil
import subprocess
import unittest


class TransportTests(unittest.TestCase):
    def test_native_async_retry_auth_failure_and_command_transport(self):
        node = shutil.which('node')
        if not node: self.skipTest('Node.js unavailable')
        result = subprocess.run([node, str(Path(__file__).with_name('offload-js-unit.cjs'))],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['passed'], 16)


if __name__ == '__main__': unittest.main()
