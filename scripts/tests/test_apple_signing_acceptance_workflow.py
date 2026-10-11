import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/apple-release.yml"
FASTFILE = ROOT / "fastlane/Fastfile"


def job_block(source: str, name: str) -> str:
    start = re.search(rf"^  {re.escape(name)}:\s*$", source, re.MULTILINE)
    if not start:
        raise AssertionError(f"workflow job is missing: {name}")
    following = re.search(r"^  [A-Za-z_][A-Za-z0-9_-]*:\s*$", source[start.end() :], re.MULTILINE)
    end = start.end() + following.start() if following else len(source)
    return source[start.start() : end]


def named_steps(job: str) -> dict[str, str]:
    lines = job.splitlines()
    starts = [i for i, line in enumerate(lines) if re.match(r"^      - name: ", line)]
    steps = {}
    for index, start in enumerate(starts):
        end = starts[index + 1] if index + 1 < len(starts) else len(lines)
        header = lines[start].split(":", 1)[1].strip()
        steps[header] = "\n".join(lines[start:end])
    return steps


class AppleSigningAcceptanceWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = WORKFLOW.read_text(encoding="utf-8")
        cls.jobs = {
            name: job_block(cls.source, name)
            for name in ("smoke", "release_gate", "app_store_release", "dmg_release")
        }

    def test_dispatch_is_candidate_only_and_does_not_run_smoke(self):
        self.assertIn("workflow_dispatch:", self.source)
        self.assertRegex(self.source, r"target:[\s\S]*?options: \[app-store, dmg\]")
        self.assertRegex(self.source, r"candidate_version:[\s\S]*?default: \"1\.3\.3\"")
        self.assertIn("if: github.event_name == 'push'", self.jobs["smoke"])
        self.assertIn("github.event_name == 'workflow_dispatch'", self.jobs["release_gate"])
        self.assertIn("CANDIDATE_VERSION", self.jobs["release_gate"])

    def test_verified_tag_push_is_derived_from_event_and_tag_after_version_checks(self):
        gate = self.jobs["release_gate"]
        self.assertIn("verified_tag_push: ${{ steps.release_context.outputs.verified_tag_push }}", gate)
        self.assertIn('GITHUB_EVENT_NAME" == "push" && "$GITHUB_REF_TYPE" == "tag"', gate)
        self.assertIn('verified_tag_push=true', gate)
        self.assertIn('verified_tag_push=false', gate)
        self.assertIn("for scheme in PushGo-iOS PushGo-macOS PushGo-watchOS", gate)
        self.assertGreater(gate.index('echo "verified_tag_push=$verified_tag_push"'), gate.index('for scheme in PushGo-iOS'))
        self.assertIn("if [[ \"$verified_tag_push\" == \"true\" ]]", gate)

    def test_dispatch_runs_only_the_selected_acceptance_target_after_gate(self):
        for job, target in (("app_store_release", "app-store"), ("dmg_release", "dmg")):
            condition = self.jobs[job].split("    runs-on:", 1)[0]
            self.assertIn("needs.release_gate.result == 'success'", condition)
            self.assertIn(f"inputs.target == '{target}'", condition)
            self.assertIn("needs.smoke.result == 'success'", condition)
        self.assertIn("release_kind=\"acceptance\"", self.jobs["app_store_release"])
        self.assertIn("release_kind=\"acceptance\"", self.jobs["dmg_release"])

    def test_every_external_publication_step_requires_verified_tag_push(self):
        expected = {
            "app_store_release": (
                "Attest store artifacts",
                "Upload attested store artifacts",
            ),
            "dmg_release": (
                "Attest signed DMG",
                "Prepare Sparkle Ed25519 signing key",
                "Generate Sparkle appcast",
                "Prepare update deploy SSH key",
                "Install update deploy known_hosts",
                "Publish DMG update artifacts to update host",
                "Verify public Sparkle artifact after deployment",
                "Upload Sparkle feed artifacts",
                "Publish DMG to GitHub Release",
                "Upload DMG assets to GitHub Release",
                "Commit Sparkle appcast state",
            ),
        }
        guard = "needs.release_gate.outputs.verified_tag_push == 'true'"
        for job_name, names in expected.items():
            steps = named_steps(self.jobs[job_name])
            for name in names:
                self.assertIn(name, steps, f"missing {name}")
                self.assertIn(guard, steps[name], f"{name} lacks the release authorization guard")

    def test_manual_outputs_are_internal_artifacts_with_explicit_acceptance_receipts(self):
        store_steps = named_steps(self.jobs["app_store_release"])
        dmg_steps = named_steps(self.jobs["dmg_release"])
        self.assertIn("fastlane ios store_build", store_steps["Build signed store artifacts"])
        self.assertIn("fastlane ios release_dmg", dmg_steps["Run fastlane release dmg"])
        self.assertIn("if: github.event_name == 'workflow_dispatch'", store_steps["Record manual store signing acceptance"])
        self.assertIn("if: github.event_name == 'workflow_dispatch'", dmg_steps["Record manual DMG signing acceptance"])
        self.assertIn("actions/upload-artifact@", store_steps["Retain manual signed store candidates"])
        self.assertIn("actions/upload-artifact@", dmg_steps["Retain manual signed DMG candidate"])
        for retained in (store_steps["Retain manual signed store candidates"], dmg_steps["Retain manual signed DMG candidate"]):
            self.assertNotRegex(retained, r"(?i)\*\.(?:p12|p8|mobileprovision|provisionprofile|key|pem)")
        receipt = (ROOT / "scripts/record_apple_signing_acceptance.py").read_text(encoding="utf-8")
        self.assertIn('"publication": "NOT_PERFORMED"', receipt)
        self.assertIn('"product_acceptance": "NOT_CERTIFIED"', receipt)

    def test_fastlane_build_lanes_do_not_upload_app_store_artifacts(self):
        fastfile = FASTFILE.read_text(encoding="utf-8")
        start = fastfile.index("lane :store_build do")
        end = fastfile.index("\n  end", start)
        lane = fastfile[start:end]
        self.assertIn("build_store_artifacts!", lane)
        self.assertNotRegex(lane, r"upload_(?:to_testflight|to_app_store)|upload_(?:beta|release)_artifacts!")

        dmg_start = fastfile.index("lane :release_dmg do")
        dmg_end = fastfile.index("\n  end", dmg_start)
        dmg_lane = fastfile[dmg_start:dmg_end]
        self.assertIn("build_release_dmg!", dmg_lane)
        self.assertNotRegex(dmg_lane, r"upload_(?:to_testflight|to_app_store)|publish_update_artifacts|upload_(?:beta|release)_artifacts!")


if __name__ == "__main__":
    unittest.main()
