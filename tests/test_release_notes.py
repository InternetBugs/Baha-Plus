import io
import json
import unittest
from unittest.mock import patch

from tools.release_notes import make_notes, translate


class ReleaseNotesTests(unittest.TestCase):
    @patch("tools.release_notes.urlopen")
    def test_translates_subject_and_decodes_entities(self, urlopen):
        urlopen.return_value.__enter__.return_value = io.BytesIO(json.dumps({
            "responseStatus": 200,
            "responseData": {"translatedText": "修复登录 &amp; 播放"},
        }).encode())
        self.assertEqual(translate("Fix login and playback"), "修复登录 & 播放")
        self.assertIn("langpair=en%7Czh-CN", urlopen.call_args.args[0].full_url)

    @patch("tools.release_notes.urlopen")
    def test_translation_errors_stop_release(self, urlopen):
        urlopen.return_value.__enter__.return_value = io.BytesIO(json.dumps({
            "responseStatus": 429,
            "responseDetails": "quota exceeded",
        }).encode())
        with self.assertRaisesRegex(RuntimeError, "quota exceeded"):
            translate("Fix playback")

    @patch("tools.release_notes.translate", return_value="修复播放")
    @patch("tools.release_notes.subprocess.check_output", return_value="Fix playback\0abc123\n")
    def test_notes_include_translated_title_and_commit(self, _git, _translate):
        notes = make_notes("v0.3.0..HEAD", "v0.3.0")
        self.assertIn("- 修复播放 (`abc123`)", notes)
        self.assertIn("机器翻译", notes)

    @patch("tools.release_notes.urlopen")
    def test_chinese_subject_is_preserved(self, urlopen):
        self.assertEqual(translate("修复播放"), "修复播放")
        urlopen.assert_not_called()


if __name__ == "__main__":
    unittest.main()
