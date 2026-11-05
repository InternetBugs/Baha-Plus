#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:-$project_root/artifacts/native-macos}"
previews="$output/previews"
app="$output/DerivedData/Build/Products/Debug-iphonesimulator/BahaPlus.app"
mkdir -p "$previews"
xcrun simctl list devices available --json > "$output/simulators.json"
device="$(python3 "$project_root/tools/select-ios-simulator.py" < "$output/simulators.json")"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")"

# An already booted device is allowed; bootstatus still validates readiness.
xcrun simctl boot "$device" 2>/dev/null || true
xcrun simctl bootstatus "$device" -b
xcrun simctl status_bar "$device" override --time '9:41' --batteryState charged --batteryLevel 100
xcrun simctl install "$device" "$app"
# Fresh iOS runtimes can deliver first-boot system notifications after SpringBoard
# is ready. Let those transient banners finish before recording app layouts.
sleep 25

capture() {
  local screen="$1" language="$2" appearance="$3"
  xcrun simctl ui "$device" appearance "$appearance"
  SIMCTL_CHILD_BAHA_UI_PREVIEW=1 \
  SIMCTL_CHILD_BAHA_PREVIEW_SCREEN="$screen" \
  SIMCTL_CHILD_BAHA_PREVIEW_LANGUAGE="$language" \
  SIMCTL_CHILD_BAHA_PREVIEW_APPEARANCE="$appearance" \
    xcrun simctl launch --terminate-running-process "$device" "$bundle_id"
  # Initial system banners can be delayed until an app becomes active.
  # Capture the settled screen instead of recording a notification over it.
  sleep 20
  xcrun simctl io "$device" screenshot "$previews/$screen-$language-$appearance.png"
}
capture home zh-Hans light
capture search zh-Hans light
capture account zh-Hans light
capture home zh-Hant dark
printf 'Captured native SwiftUI previews in %s\n' "$previews"
