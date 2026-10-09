"""Check nft mark expressions against the Linux 6.12 bitwise constraints.

Read generated-rule templates only; never execute the installer on the host.
The router suites validate and exercise these rules in the real kernel.
"""
import re
import unittest
from test_compiler import ROOT


class FirewallCompatibilityTests(unittest.TestCase):
    def test_mark_assignments_use_one_register_and_constants(self):
        source = (ROOT / 'getdomains-install.sh').read_text(encoding='utf-8')
        assignments = re.findall(r'(?:meta|ct) mark set (.*?) comment ', source)
        self.assertGreaterEqual(len(assignments), 6)
        for expression in assignments:
            with self.subTest(expression=expression):
                # Combining two runtime register values requires newer kernel
                # bitwise operations. One register with constant masks works.
                self.assertEqual(len(re.findall(r'(?:meta|ct) mark', expression)), 1)
                remainder = re.sub(r'(?:meta|ct) mark', '0', expression)
                self.assertRegex(remainder, r'^[0-9a-fx() &|]+$')


if __name__ == '__main__':
    unittest.main()
