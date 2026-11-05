#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
output="$project_root/artifacts/ios-preview"
mkdir -p "$output"
if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'SwiftUI simulator previews require macOS and Xcode.\n' >&2
  exit 3
fi

# This job verifies Apple's native rendering independently. The other workflow
# job still requires the full Skip/Android build and both native products.
unset BAHA_CORE_ONLY
export SKIP_ZERO=1
xcodebuild \
  -workspace "$project_root/Project.xcworkspace" \
  -scheme 'BahaPlus App' \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -skipPackagePluginValidation \
  -derivedDataPath "$output/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  SKIP_ACTION=none \
  build 2>&1 | tee "$output/build.log"
bash "$project_root/tools/capture-ios-previews.sh" "$output" 2>&1 | tee "$output/previews.log"
