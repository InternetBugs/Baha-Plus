"""Translate commit subjects into Simplified Chinese for a release."""

import html
import json
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen


def translate(subject: str) -> str:
    # Preserve titles that already contain Chinese and no English words.
    if re.search(r"[\u3400-\u9fff]", subject) and not re.search(r"[A-Za-z]{2,}", subject):
        return subject
    if len(subject.encode("utf-8")) > 500:
        raise ValueError("a commit subject exceeds the translation service's 500-byte limit")
    query = urlencode({"q": subject, "langpair": "en|zh-CN"})
    request = Request(
        f"https://api.mymemory.translated.net/get?{query}",
        headers={"User-Agent": "Baha-Plus-release-notes/1.0"},
    )
    with urlopen(request, timeout=30) as response:
        data = json.load(response)
    if data.get("responseStatus") != 200:
        raise RuntimeError(f"translation service failed: {data.get('responseDetails', 'unknown error')}")
    translated = html.unescape(data["responseData"]["translatedText"]).strip()
    if not translated:
        raise RuntimeError("translation service returned an empty result")
    return " ".join(translated.splitlines())


def make_notes(commit_range: str, previous_tag: str) -> str:
    output = subprocess.check_output(
        ["git", "log", "--no-merges", "--format=%s%x00%h", commit_range],
        text=True,
        encoding="utf-8",
    )
    notes = [
        "## 下载说明",
        "",
        "- Android：已签名的正式版 APK。",
        "- iOS：未签名的 IPA，安装前需使用合适的 Apple 证书和描述文件签名；尚未经过真机验证。",
        "- SHA256SUMS.txt 包含两个文件的 SHA-256 校验值。",
        "",
        "## 更新内容",
        "",
        f"以下为自 {previous_tag} 以来的提交（机器翻译）："
        if previous_tag else "首次发布，以下为截至此版本的提交（机器翻译）：",
        "",
    ]
    for line in output.splitlines():
        subject, sha = line.rsplit("\0", 1)
        translated = translate(subject)
        # Escape Markdown formatting without changing the translated words.
        translated = re.sub(r"([\\`*_{}\[\]<>])", r"\\\1", translated)
        notes.append(f"- {translated} (`{sha}`)")
    return "\n".join(notes) + "\n"


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("usage: release_notes.py COMMIT_RANGE PREVIOUS_TAG OUTPUT")
    Path(sys.argv[3]).write_text(make_notes(sys.argv[1], sys.argv[2]), encoding="utf-8")
