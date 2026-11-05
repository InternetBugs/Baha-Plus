"""Install the actual APK and exercise guest UI on a fresh CI Android emulator."""
import argparse
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

APP_ID = "app.bahaplus.mobile"


def run(*args, timeout=45, check=True):
    return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          timeout=timeout, check=check)


def adb(*args, **options):
    return run("adb", *args, **options)


def text(result):
    return result.stdout.decode("utf-8", errors="replace").strip()


def values(root):
    return [node.get(key, "") for node in root.iter("node")
            for key in ("text", "content-desc", "resource-id")]


def contains(root, *expected):
    return any(value in values(root) for value in expected)


def bounds(node):
    numbers = re.findall(r"\d+", node.get("bounds", ""))
    return tuple(map(int, numbers)) if len(numbers) == 4 else None


class Smoke:
    def __init__(self, output):
        self.output = output
        self.root = None
        self.sequence = 0
        self.width = 0
        self.height = 0

    def measure_display(self):
        sizes = re.findall(r"(\d+)x(\d+)", text(adb("shell", "wm", "size")))
        if not sizes:
            raise AssertionError("Cannot read the emulator display size.")
        self.width, self.height = map(int, sizes[-1])

    def observe(self):
        self.sequence += 1
        adb("shell", "uiautomator", "dump", "/sdcard/baha-smoke.xml", timeout=25)
        raw = adb("exec-out", "cat", "/sdcard/baha-smoke.xml").stdout
        (self.output / f"state-{self.sequence:02d}.xml").write_bytes(raw)
        self.root = ET.fromstring(raw)
        return self.root

    def wait(self, label, predicate):
        error = None
        for _ in range(12):
            if not text(adb("shell", "pidof", APP_ID, check=False)):
                raise AssertionError(f"The app process exited while waiting for {label}.")
            try:
                root = self.observe()
                if predicate(root):
                    print(f"Verified {label}", flush=True)
                    return
            except (ET.ParseError, subprocess.SubprocessError) as caught:
                error = caught
            time.sleep(2)
        visible = "\n".join(value for value in values(self.root) if value) if self.root is not None else ""
        raise AssertionError(f"Missing {label}. Last observation error: {error}\n{visible}")

    def tap(self, expected, bottom_only=False):
        if isinstance(expected, str):
            expected = [expected]
        candidates = []
        for node in self.root.iter("node"):
            rectangle = bounds(node)
            if not rectangle:
                continue
            x1, y1, x2, y2 = rectangle
            if x2 <= x1 or y2 <= y1:
                continue
            if not any(node.get(key, "") == value or node.get(key, "").endswith(":id/" + value)
                       for key in ("text", "content-desc", "resource-id") for value in expected):
                continue
            if bottom_only and y1 < self.height * 0.70:
                continue
            candidates.append(((x2 - x1) * (y2 - y1), rectangle))
        if not candidates:
            raise AssertionError(f"No visible accessible target: {expected}")
        _, (x1, y1, x2, y2) = min(candidates)
        adb("shell", "input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2))
        time.sleep(1)

    def screenshot(self, name):
        (self.output / f"{name}.png").write_bytes(adb("exec-out", "screencap", "-p").stdout)

    def scroll_settings(self):
        adb("shell", "input", "swipe",
            str(self.width // 2), str(round(self.height * 0.75)),
            str(self.width // 2), str(round(self.height * 0.35)), "350")
        time.sleep(1)
        self.observe()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--apk", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    options = parser.parse_args()
    options.output.mkdir(parents=True, exist_ok=True)
    smoke = Smoke(options.output)
    try:
        adb("wait-for-device", timeout=120)
        installation = adb("install", "-r", str(options.apk), timeout=120, check=False)
        (options.output / "install.txt").write_bytes(installation.stdout + installation.stderr)
        if installation.returncode:
            raise AssertionError(f"APK installation failed: {text(installation)} "
                                 f"{installation.stderr.decode('utf-8', errors='replace')}")
        smoke.measure_display()
        adb("logcat", "-c")
        activity = text(adb("shell", "cmd", "package", "resolve-activity", "--brief",
                            "-a", "android.intent.action.MAIN",
                            "-c", "android.intent.category.LAUNCHER", APP_ID))
        component = activity.splitlines()[-1]
        if "/" not in component:
            raise AssertionError(f"No Android launcher activity: {activity}")
        launch = adb("shell", "am", "start", "-W", "-n", component)
        (options.output / "launch.txt").write_bytes(launch.stdout + launch.stderr)
        smoke.wait("home and native tab bar", lambda root:
                   contains(root, "探索") and contains(root, "搜尋", "搜索") and
                   contains(root, "片庫", "片库"))
        smoke.screenshot("home")
        smoke.tap(["搜尋", "搜索"], bottom_only=True)
        smoke.wait("search recommendations", lambda root: contains(root, "為你推薦", "为你推荐"))
        smoke.screenshot("search")
        smoke.tap(["account-button", "我的"])
        smoke.wait("account sheet", lambda root: contains(root, "巴哈姆特帳號", "巴哈姆特账号"))
        smoke.screenshot("account")

        # Validate the actual device setting rather than injecting preview data.
        for _ in range(5):
            if contains(smoke.root, "介面語言", "界面语言"):
                break
            smoke.scroll_settings()
        smoke.tap(["介面語言", "界面语言"])
        smoke.wait("language choices", lambda root: contains(root, "简体中文"))
        smoke.tap("简体中文")
        smoke.wait("simplified Chinese settings", lambda root: contains(root, "界面语言"))
        smoke.screenshot("account-zh-Hans")
        smoke.tap("关闭")
        smoke.wait("simplified Chinese search", lambda root: contains(root, "为你推荐"))
        smoke.screenshot("search-zh-Hans")
        print("Android guest UI smoke passed: install, launch, search, account, language switch.", flush=True)
    finally:
        # Preserve the original failure if the emulator itself disappeared.
        try:
            smoke.screenshot("final-state")
        except (OSError, subprocess.SubprocessError) as error:
            print(f"Could not capture final screenshot: {error}", file=sys.stderr)
        try:
            (options.output / "logcat.txt").write_bytes(
                adb("logcat", "-d", "-v", "threadtime", check=False).stdout)
        except (OSError, subprocess.SubprocessError) as error:
            print(f"Could not capture Android logs: {error}", file=sys.stderr)


if __name__ == "__main__":
    main()
