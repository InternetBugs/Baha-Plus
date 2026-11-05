#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'The iPhone device build requires macOS and Xcode 26+.\n' >&2
  exit 3
fi
sdk_version="$(xcrun --sdk iphoneos --show-sdk-version)"
if [[ "${sdk_version%%.*}" -lt 26 ]]; then
  printf 'Liquid Glass requires iPhoneOS SDK 26+; selected SDK is %s.\n' "$sdk_version" >&2
  exit 3
fi

output="$project_root/artifacts/native-macos"
derived="$output/DeviceDerivedData"
mkdir -p "$output"
cd "$project_root"

# The Android APK is built separately. This stage compiles native SwiftUI for
# the physical iPhone architecture and never requires an Apple account in CI.
SKIP_ZERO=1 xcodebuild \
  -workspace "$project_root/Project.xcworkspace" \
  -scheme 'BahaPlus App' \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$derived" \
  -clonedSourcePackagesDirPath "$output/DerivedData/SourcePackages" \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  SKIP_ACTION=none \
  build 2>&1 | tee "$output/ios-device-build.log"

app="$derived/Build/Products/Release-iphoneos/BahaPlus.app"
platform="$(/usr/libexec/PlistBuddy -c 'Print DTPlatformName' "$app/Info.plist")"
if [[ "$platform" != "iphoneos" ]]; then
  printf 'The device package has the wrong platform: %s.\n' "$platform" >&2
  exit 1
fi
executable="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$app/Info.plist")"
test -s "$app/$executable"
file "$app/$executable" | tee "$output/ios-device-executable.txt"
grep -q 'arm64' "$output/ios-device-executable.txt"

payload="$output/device-package/Payload"
mkdir -p "$payload"
ditto "$app" "$payload/BahaPlus.app"
ditto -c -k --keepParent "$payload" "$output/BahaPlus-unsigned.ipa"
unzip -Z1 "$output/BahaPlus-unsigned.ipa" > "$output/ios-device-contents.txt"
grep -q '^Payload/BahaPlus.app/Info.plist$' "$output/ios-device-contents.txt"
grep -Fq "Payload/BahaPlus.app/$executable" "$output/ios-device-contents.txt"
printf 'Created an unsigned arm64 iPhone IPA. Personal signing and device acceptance are still required.\n'
