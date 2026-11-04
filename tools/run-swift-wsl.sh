#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
swift_root="$(tr -d '\r\n' < "$project_root/.tools/swift-wsl-path.txt")"
if [[ ! -x "$swift_root/usr/bin/swift" ]]; then
  printf 'Swift toolchain is not available: %s\n' "$swift_root" >&2
  exit 1
fi
support_root="$(dirname "$swift_root")"
export PATH="$swift_root/usr/bin:$PATH"
export LD_LIBRARY_PATH="$support_root/deps/root/lib/x86_64-linux-gnu:$support_root/deps/root/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export BAHA_CORE_ONLY=1
cd "$project_root"
if [[ $# -eq 0 ]]; then set -- test; fi
if [[ "$1" == "test" ]]; then
  exec swift "$@" --scratch-path "$support_root/build"
fi
exec swift "$@"
