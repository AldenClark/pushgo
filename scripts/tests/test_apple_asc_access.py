"""Keep the Ruby ASC contract tests in the existing script-test entrypoint."""
from pathlib import Path
import os
import subprocess
import unittest


class AppleASCAccessContractTests(unittest.TestCase):
    def test_read_only_access_and_secret_redaction_contracts(self):
        script = Path(__file__).with_suffix(".rb")
        result = subprocess.run(
            ["ruby", str(script)], capture_output=True, text=True, timeout=30,
            env={"PATH": os.environ.get("PATH", "/usr/bin:/bin")},
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
