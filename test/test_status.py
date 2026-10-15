"""Integration checks for status.py against the machine's real drives.

Zero dependencies beyond the stdlib. Run with:
    /usr/bin/python3 -m unittest discover -s test -p 'test_*.py'
"""

import json
import subprocess
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
STATUS = REPO / "status.py"


def run_status(*args):
    proc = subprocess.run(
        ["/usr/bin/python3", str(STATUS), *args],
        capture_output=True, text=True, timeout=120,
    )
    return json.loads(proc.stdout)


class StatusShape(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.payload = run_status()
        if not cls.payload.get("ok"):
            raise unittest.SkipTest(f"status.py not ok: {cls.payload.get('error')}")

    def test_lists_every_device(self):
        self.assertGreater(len(self.payload["devices"]), 0)

    def test_emits_a_summary_per_device(self):
        """The bar needs every disk, not just the selected one."""
        self.assertIn("disks", self.payload)
        self.assertEqual(len(self.payload["disks"]), len(self.payload["devices"]))

    def test_every_summary_carries_the_ranking_fields(self):
        required = {
            "device", "model", "warning", "criticalWarning", "mediaErrors",
            "availableSparePercent", "lifeRemainingPercent", "temperatureC",
        }
        for d in self.payload["disks"]:
            missing = required - set(d)
            self.assertEqual(missing, set(), f"{d.get('device')} missing {missing}")

    def test_keeps_the_single_disk_field_for_compatibility(self):
        self.assertIn("disk", self.payload)
        self.assertIn("device", self.payload["disk"])


if __name__ == "__main__":
    unittest.main()
