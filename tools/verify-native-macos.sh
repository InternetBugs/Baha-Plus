#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'Native app verification needs macOS, Xcode 26+, Skip and the Android SDK.\n' >&2
  printf 'Linux/WSL can run the BahaCore Swift tests, but cannot verify SwiftUI app builds.\n' >&2
  exit 3
fi
for tool in xcodebuild xcrun swift skip unzip; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Required tool is missing: %s\n' "$tool" >&2
    exit 3
  fi
done
sdk_version="$(xcrun --sdk iphonesimulator --show-sdk-version)"
sdk_major="${sdk_version%%.*}"
if [[ "$sdk_major" -lt 26 ]]; then
  printf 'The selected iPhone Simulator SDK is %s; Liquid Glass requires SDK 26+.\n' "$sdk_version" >&2
  exit 3
fi

cd "$project_root"
output="$project_root/artifacts/native-macos"
derived="$output/DerivedData"
mkdir -p "$output"
skip doctor 2>&1 | tee "$output/doctor.log"
skip verify 2>&1 | tee "$output/project.log"
BAHA_CORE_ONLY=1 swift test --scratch-path "$output/CoreBuild" 2>&1 | tee "$output/core-tests.log"

# The template skips Android whenever SKIP_ZERO is nonempty, including "0".
# Unset both variables so the full native product, rather than only BahaCore,
# is compiled and the Xcode Android build phase actually executes.
unset BAHA_CORE_ONLY SKIP_ZERO
xcodebuild \
  -workspace "$project_root/Project.xcworkspace" \
  -scheme 'BahaPlus App' \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$derived" \
  CODE_SIGNING_ALLOWED=NO \
  SKIP_ACTION=build \
  build 2>&1 | tee "$output/native-build.log"

ios_app="$derived/Build/Products/Debug-iphonesimulator/BahaPlus.app"
if [[ ! -f "$ios_app/Info.plist" ]]; then
  printf 'The iOS simulator app was not produced.\n' >&2
  exit 1
fi
executable="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$ios_app/Info.plist")"
if [[ ! -f "$ios_app/$executable" ]]; then
  printf 'The iOS app bundle does not contain its executable.\n' >&2
  exit 1
fi
tar -czf "$output/BahaPlus-ios-simulator.tar.gz" -C "$(dirname "$ios_app")" "$(basename "$ios_app")"

roots=("$derived" "$project_root/Android")
if [[ -d "$project_root/.build" ]]; then roots+=("$project_root/.build"); fi
find "${roots[@]}" -type f -name '*-debug.apk' -print > "$output/apk-candidates.txt"
apk="$(head -n 1 "$output/apk-candidates.txt")"
if [[ -z "$apk" ]]; then
  printf 'No Android debug APK was produced. The dual-platform build has not passed.\n' >&2
  exit 1
fi
unzip -Z1 "$apk" > "$output/apk-contents.txt"
grep -q '^AndroidManifest.xml$' "$output/apk-contents.txt"
grep -Eq '^classes[0-9]*\.dex$' "$output/apk-contents.txt"
cp "$apk" "$output/BahaPlus-debug.apk"
printf 'iOS simulator app: %s\nAndroid APK: %s\n' \
  "$ios_app" "$output/BahaPlus-debug.apk" | tee "$output/products.txt"
printf 'Both native builds produced artifacts. Account/playback/device visual acceptance is still required.\n'
