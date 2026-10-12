from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


REPO = Path(__file__).resolve().parents[2]
PREPARER = REPO / "scripts" / "prepare_ios_ui_test_app.sh"


class PrepareIOSUITestAppTests(unittest.TestCase):
    def make_fake_xcrun(self, root: Path, installed_container: Path) -> tuple[Path, Path]:
        bin_dir = root / "bin"
        bin_dir.mkdir()
        calls = root / "calls.log"
        fake = bin_dir / "xcrun"
        fake.write_text(
            textwrap.dedent(
                f"""\
                #!/bin/sh
                printf '%s\\n' "$*" >> "{calls}"
                if [ "$1 $2" = "simctl install" ]; then
                  exit "${{FAKE_INSTALL_STATUS:-0}}"
                fi
                if [ "$1 $2" = "simctl get_app_container" ]; then
                  printf '%s\\n' "${{FAKE_INSTALLED_CONTAINER:-{installed_container}}}"
                  exit 0
                fi
                exit 64
                """
            ),
            encoding="utf-8",
        )
        fake.chmod(0o755)
        return bin_dir, calls

    def run_preparer(
        self,
        bin_dir: Path,
        app_bundle: Path,
        installed_container: Path,
        **extra_env: str,
    ) -> subprocess.CompletedProcess[str]:
        environment = {
            "PATH": f"{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin",
            "FAKE_INSTALLED_CONTAINER": str(installed_container),
            **extra_env,
        }
        return subprocess.run(
            [str(PREPARER), "SIM-123", str(app_bundle), "io.ethan.pushgo"],
            cwd=REPO,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

    def test_installs_exact_built_app_and_requires_observable_container(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app_bundle = root / "DerivedData" / "PushGo.app"
            app_bundle.mkdir(parents=True)
            installed_container = root / "Simulator" / "PushGo.app"
            installed_container.mkdir(parents=True)
            bin_dir, calls = self.make_fake_xcrun(root, installed_container)

            result = self.run_preparer(bin_dir, app_bundle, installed_container)

            self.assertEqual(0, result.returncode, result.stdout)
            self.assertIn(f"ios_ui_app_preinstalled={installed_container}", result.stdout)
            self.assertEqual(
                [
                    f"simctl install SIM-123 {app_bundle}",
                    "simctl get_app_container SIM-123 io.ethan.pushgo app",
                ],
                calls.read_text(encoding="utf-8").splitlines(),
            )

    def test_install_failure_blocks_before_any_test_launch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app_bundle = root / "PushGo.app"
            app_bundle.mkdir()
            installed_container = root / "installed" / "PushGo.app"
            installed_container.mkdir(parents=True)
            bin_dir, calls = self.make_fake_xcrun(root, installed_container)

            result = self.run_preparer(
                bin_dir,
                app_bundle,
                installed_container,
                FAKE_INSTALL_STATUS="1",
            )

            self.assertEqual(2, result.returncode, result.stdout)
            self.assertIn("reason=ios_ui_app_preinstall_failed:SIM-123", result.stdout)
            self.assertEqual(1, len(calls.read_text(encoding="utf-8").splitlines()))

    def test_unobservable_install_blocks_instead_of_racing_xctest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app_bundle = root / "PushGo.app"
            app_bundle.mkdir()
            missing_container = root / "missing" / "PushGo.app"
            bin_dir, _ = self.make_fake_xcrun(root, missing_container)

            result = self.run_preparer(bin_dir, app_bundle, missing_container)

            self.assertEqual(2, result.returncode, result.stdout)
            self.assertIn("reason=ios_ui_app_install_not_observable", result.stdout)

    def test_both_simulator_runners_propagate_preinstall_failure_to_blocked_status(self) -> None:
        for runner_name in ("run_ios_ui_tests.sh", "run_watchos_ui_tests.sh"):
            source = (REPO / "scripts" / runner_name).read_text(encoding="utf-8")
            self.assertIn('if ! "$repo_root/scripts/prepare_ios_ui_test_app.sh"', source)
            self.assertIn("printf 'BLOCKED\\n' > \"$runner_status_file\"", source)


if __name__ == "__main__":
    unittest.main()
