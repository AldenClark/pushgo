import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
STORE = REPO_ROOT / "Shared/Repositories/LocalDataStore.swift"
UPGRADE_TEST = REPO_ROOT / "Tests/PushGoAppleCoreTests/RuntimeQualityLargeScaleTests.swift"


class StoreMigrationRegistryContractTest(unittest.TestCase):
    def test_v17_upgrade_fixture_tracks_every_registered_suffix_migration(self):
        store_text = STORE.read_text()
        test_text = UPGRADE_TEST.read_text()
        migrations = re.findall(r'registerMigration\("(v(\d+)[^"]*)"\)', store_text)
        self.assertTrue(migrations)

        versions = {int(version) for _, version in migrations}
        self.assertEqual(set(range(1, max(versions) + 1)), versions)

        supported_suffix = {name for name, version in migrations if int(version) > 17}
        self.assertTrue(supported_suffix)
        for migration in supported_suffix:
            self.assertIn(
                f"'{migration}'",
                test_text,
                f"v17 downgrade must remove {migration} so the production migrator really executes it",
            )
            self.assertIn(
                f'applied.contains("{migration}")',
                test_text,
                f"upgrade evidence must prove {migration} was applied",
            )

        self.assertIn('migratedTables.contains("pending_local_deletions")', test_text)
        self.assertIn('migratedTables.contains("canonical_derived_work")', test_text)
        self.assertIn(
            "currentV24StorePreservesPendingDeletionThroughV25AndReopen",
            test_text,
        )
        self.assertIn(
            "loadPendingLocalDeletions(now: now)",
            test_text,
        )
        self.assertIn("afterMigration.first == pending", test_text)
        self.assertIn("afterReopen.first == pending", test_text)


if __name__ == "__main__":
    unittest.main()
