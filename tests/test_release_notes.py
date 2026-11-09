import unittest
from unittest.mock import patch

from tools.release_notes import make_notes


class ReleaseNotesTests(unittest.TestCase):
    @patch("tools.release_notes.subprocess.check_output", return_value="Fix playback\0abc123\n")
    def test_notes_preserve_original_title_and_commit(self, _git):
        notes = make_notes("v0.3.0..HEAD", "v0.3.0")
        self.assertIn("- Fix playback (`abc123`)", notes)
        self.assertIn("自 v0.3.0 以来", notes)
        self.assertNotIn("机器翻译", notes)

    @patch("tools.release_notes.subprocess.check_output")
    def test_supplied_notes_preserve_markdown_without_reading_commits(self, git):
        notes = make_notes(
            "v0.4.0..HEAD", "v0.4.0", "\n### 播放改进\n\n- 修复 **暂停** 与播放恢复。\n"
        )
        self.assertIn("## 下载说明", notes)
        self.assertIn("## 更新内容\n\n### 播放改进\n\n- 修复 **暂停** 与播放恢复。\n", notes)
        self.assertNotIn("以下为", notes)
        git.assert_not_called()

    @patch("tools.release_notes.subprocess.check_output", return_value="修复播放\0abc123\n")
    def test_blank_notes_fall_back_to_original_commits(self, _git):
        notes = make_notes("HEAD", "", " \n ")
        self.assertIn("首次发布", notes)
        self.assertIn("- 修复播放 (`abc123`)", notes)

    @patch(
        "tools.release_notes.subprocess.check_output",
        return_value="Fix [player] and `pause` *state*\0abc123\n",
    )
    def test_original_subject_markdown_is_escaped(self, _git):
        notes = make_notes("HEAD", "")
        self.assertIn(r"- Fix \[player\] and \`pause\` \*state\* (`abc123`)", notes)


if __name__ == "__main__":
    unittest.main()
