import unittest

from tools.release_version import choose_version


class ReleaseVersionTests(unittest.TestCase):
    def test_first_release_uses_pubspec_version(self):
        self.assertEqual(choose_version("0.3.0", []), ("0.3.0", 3000))

    def test_next_release_uses_highest_numeric_tag(self):
        self.assertEqual(
            choose_version("0.3.0", ["v0.3.2", "v0.3.10", "v0.3.11-beta"]),
            ("0.3.11", 3011),
        )

    def test_higher_pubspec_version_sets_new_baseline(self):
        self.assertEqual(choose_version("1.0.0", ["v0.9.0"]), ("1.0.0", 1_000_000))

    def test_patch_and_minor_roll_over(self):
        self.assertEqual(choose_version("0.3.0", ["v0.999.999"]), ("1.0.0", 1_000_000))

    def test_rejects_unrepresentable_version(self):
        with self.assertRaises(ValueError):
            choose_version("2101.0.0", [])

    def test_manual_version_and_optional_prefix(self):
        self.assertEqual(choose_version("0.3.0", ["v0.3.2"], "v0.5.0"), ("0.5.0", 5000))

    def test_manual_version_must_be_newer_than_all_tags(self):
        for version in ("0.3.2", "0.2.9"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                choose_version("0.3.0", ["v0.3.2"], version)

    def test_invalid_manual_versions_are_rejected(self):
        for version in ("1.2", "1.2.3-beta", "1.1000.0", "2101.0.0"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                choose_version("0.3.0", [], version)


if __name__ == "__main__":
    unittest.main()
