import unittest

from tools.altsource import BUNDLE_IDENTIFIER, build_source


class AltSourceTests(unittest.TestCase):
    def setUp(self):
        self.source = build_source(
            version="0.5.6",
            build_number=5006,
            ipa_size=28_620_750,
            released="2026-11-18",
        )
        self.app = self.source["apps"][0]

    def test_source_points_at_release_ipa(self):
        version = self.app["versions"][0]
        self.assertEqual(
            version["downloadURL"],
            "https://github.com/InternetBugs/Baha-Plus/releases/download/"
            "v0.5.6/BahaPlus-iOS-unsigned.ipa",
        )
        self.assertEqual(version["size"], 28_620_750)
        self.assertEqual(self.app["bundleIdentifier"], BUNDLE_IDENTIFIER)

    def test_version_metadata_matches_the_ipa(self):
        version = self.app["versions"][0]
        self.assertEqual(version["version"], "0.5.6")
        self.assertEqual(version["buildVersion"], "5006")
        self.assertEqual(version["minOSVersion"], "15.0")
        self.assertEqual(version["date"], "2026-11-18")

    def test_raw_assets_use_the_default_branch(self):
        self.assertTrue(self.app["iconURL"].startswith(
            "https://raw.githubusercontent.com/InternetBugs/Baha-Plus/main/assets/"
        ))
        self.assertEqual(self.source["featuredApps"], [BUNDLE_IDENTIFIER])


if __name__ == "__main__":
    unittest.main()
