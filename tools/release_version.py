"""Choose the next release version from pubspec.yaml and remote Git tags."""

import os
import re
import subprocess
from pathlib import Path

VERSION = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
TAG = re.compile(r"^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
ANDROID_MAX_VERSION_CODE = 2_100_000_000


def choose_version(base_version: str, tags: list[str]) -> tuple[str, int]:
    match = VERSION.fullmatch(base_version)
    if not match:
        raise ValueError("pubspec.yaml must contain a numeric major.minor.patch version")
    base = tuple(map(int, match.groups()))
    existing = [tuple(map(int, m.groups())) for tag in tags if (m := TAG.fullmatch(tag))]
    latest = max(existing, default=None)
    if latest is not None and latest >= base:
        major, minor, patch = latest
        if minor >= 1000 or patch >= 1000:
            raise ValueError("existing release version components must be below 1000")
        patch += 1
        if patch == 1000:
            minor += 1
            patch = 0
        if minor == 1000:
            major += 1
            minor = 0
        selected = (major, minor, patch)
    else:
        selected = base
    major, minor, patch = selected
    if minor >= 1000 or patch >= 1000:
        raise ValueError("minor and patch versions must be below 1000")
    build_number = major * 1_000_000 + minor * 1_000 + patch
    if not 1 <= build_number <= ANDROID_MAX_VERSION_CODE:
        raise ValueError("version cannot be represented as an Android version code")
    return ".".join(map(str, selected)), build_number


def main() -> None:
    pubspec = Path("app/pubspec.yaml").read_text(encoding="utf-8")
    match = re.search(r"(?m)^version:\s*(\d+\.\d+\.\d+)\+\d+\s*$", pubspec)
    if not match:
        raise ValueError("pubspec.yaml version must include a numeric build number")
    output = subprocess.check_output(
        ["git", "ls-remote", "--refs", "--tags", "origin"], text=True
    )
    tags = [line.split("refs/tags/", 1)[1] for line in output.splitlines()]
    version, build_number = choose_version(match.group(1), tags)
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as result:
        result.write(f"version={version}\ntag=v{version}\nbuild_number={build_number}\n")
    print(f"Selected v{version} (build {build_number})")


if __name__ == "__main__":
    main()
