"""Prepare release notes from supplied text or original commit subjects."""

import os
import re
import subprocess
import sys
from pathlib import Path


def make_notes(commit_range: str, previous_tag: str, release_notes: str = "") -> str:
    notes = [
        "## 下载说明",
        "",
        "- Android：已签名的正式版 APK。",
        "- iOS：未签名的 IPA，安装前需使用合适的 Apple 证书和描述文件签名。",
        "- SHA256SUMS.txt 包含两个文件的 SHA-256 校验值。",
        "",
        "## 更新内容",
        "",
    ]
    if release_notes.strip():
        notes.append(release_notes.strip())
        return "\n".join(notes) + "\n"

    output = subprocess.check_output(
        ["git", "log", "--no-merges", "--format=%s%x00%h", commit_range],
        text=True,
        encoding="utf-8",
    )
    notes.extend([
        f"以下为自 {previous_tag} 以来的提交："
        if previous_tag else "首次发布，以下为截至此版本的提交：",
        "",
    ])
    for line in output.splitlines():
        subject, sha = line.rsplit("\0", 1)
        # Escape Markdown formatting without changing the original words.
        subject = re.sub(r"([\\`*_{}\[\]<>])", r"\\\1", subject)
        notes.append(f"- {subject} (`{sha}`)")
    return "\n".join(notes) + "\n"


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("usage: release_notes.py COMMIT_RANGE PREVIOUS_TAG OUTPUT")
    Path(sys.argv[3]).write_text(
        make_notes(sys.argv[1], sys.argv[2], os.environ.get("RELEASE_NOTES", "")),
        encoding="utf-8",
    )
