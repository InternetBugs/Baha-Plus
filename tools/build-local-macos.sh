#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'Local iOS builds require a Mac or a macOS VM hosted on Apple hardware.\n' >&2
  printf 'Windows/WSL can check resources and BahaCore; it cannot run Xcode.\n' >&2
  exit 3
fi
for tool in node npm java xcodebuild xcrun swift skip; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Required local build tool is missing: %s\n' "$tool" >&2
    exit 3
  fi
done
if [[ "$(node -p 'Number(process.versions.node.split(".")[0])')" -lt 24 ]]; then
  printf 'Node.js 24+ is required for the local validation tools.\n' >&2
  exit 3
fi

cd "$project_root"
npm ci
npm run resources:check
npm test
npm run typecheck
bash tools/verify-native-macos.sh
bash tools/build-ios-device.sh

printf '\nLocal build products:\n'
for name in BahaPlus-debug.apk BahaPlus-ios-simulator.tar.gz BahaPlus-unsigned.ipa; do
  test -s "$project_root/artifacts/native-macos/$name"
  printf '  %s\n' "$project_root/artifacts/native-macos/$name"
done
printf '\nThe iPhone IPA is unsigned; personal signing is required before installation.\n'
