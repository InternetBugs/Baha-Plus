"""Generate the AltStore/SideStore/Feather source file for a release.

The source describes the unsigned iOS IPA shipped with the same GitHub
release, so ``releases/latest/download/AltSource.json`` always resolves to the
newest published version without touching ``main``.
"""

import argparse
import json
import re
from datetime import date
from pathlib import Path

REPOSITORY = "InternetBugs/Baha-Plus"
BUNDLE_IDENTIFIER = "app.bahaplus.mobile"
MINIMUM_IOS_VERSION = "15.0"
IPA_NAME = "BahaPlus-iOS-unsigned.ipa"
SUBTITLE = "第三方巴哈姆特动画疯客户端"
DESCRIPTION = (
    "Baha Plus 是一个为巴哈姆特动画疯打造的第三方客户端。可以浏览本季新番、"
    "每周时间表、片库与搜索，登录后查看追番与观看记录，并在原生播放页调整弹幕。"
    "安装包未签名，AltStore、SideStore 或 Feather 会使用你自己的 Apple 证书完成签名。"
    "本应用与巴哈姆特动画疯官方无关。"
)
SCREENSHOTS = (
    "explore-device.jpg",
    "library-device.jpg",
    "history-device.jpg",
    "search-device.jpg",
    "player-device.jpg",
)


def build_source(
    version: str,
    build_number: int,
    ipa_size: int,
    released: str,
    repository: str = REPOSITORY,
) -> dict:
    """Return an AltStore source document describing one release."""
    raw_base = f"https://raw.githubusercontent.com/{repository}/main"
    download_url = (
        f"https://github.com/{repository}/releases/download/"
        f"v{version}/{IPA_NAME}"
    )
    return {
        "name": "Baha Plus",
        "identifier": f"{BUNDLE_IDENTIFIER}.altsource",
        "subtitle": SUBTITLE,
        "description": DESCRIPTION,
        "iconURL": f"{raw_base}/assets/icon.png",
        "website": f"https://github.com/{repository}",
        "tintColor": "#D85F3D",
        "featuredApps": [BUNDLE_IDENTIFIER],
        "apps": [
            {
                "name": "Baha Plus",
                "bundleIdentifier": BUNDLE_IDENTIFIER,
                "developerName": "InternetBugs",
                "subtitle": SUBTITLE,
                "localizedDescription": DESCRIPTION,
                "iconURL": f"{raw_base}/assets/icon.png",
                "tintColor": "#D85F3D",
                "category": "entertainment",
                "screenshots": [f"{raw_base}/assets/screenshots/{name}" for name in SCREENSHOTS],
                "versions": [
                    {
                        "version": version,
                        "buildVersion": str(build_number),
                        "date": released,
                        "downloadURL": download_url,
                        "size": ipa_size,
                        "minOSVersion": MINIMUM_IOS_VERSION,
                    }
                ],
                "appPermissions": {"entitlements": [], "privacy": {}},
            }
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="release version, e.g. 0.5.6")
    parser.add_argument("--build-number", required=True, type=int, help="iOS build number")
    parser.add_argument("--ipa", required=True, type=Path, help="unsigned IPA of this release")
    parser.add_argument("--date", default="", help="release date (YYYY-MM-DD), defaults to today")
    parser.add_argument("--repository", default=REPOSITORY, help="owner/name on GitHub")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    version = args.version.removeprefix("v")
    if not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", version):
        parser.error("version must be major.minor.patch")
    if args.build_number < 1:
        parser.error("build number must be positive")

    source = build_source(
        version=version,
        build_number=args.build_number,
        ipa_size=args.ipa.stat().st_size,
        released=args.date or date.today().isoformat(),
        repository=args.repository,
    )
    args.output.write_text(
        json.dumps(source, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    size = source["apps"][0]["versions"][0]["size"]
    print(f"Wrote {args.output} for v{source['apps'][0]['versions'][0]['version']} ({size} bytes)")


if __name__ == "__main__":
    main()
