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


if __name__ == "__main__":
    unittest.main()
