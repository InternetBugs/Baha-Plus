#!/usr/bin/env bash
set -euo pipefail

# Project-scoped toolchain. No system packages, shell profiles or global
# Swift installation are changed.
project_root="$(cd "$(dirname "$0")/.." && pwd)"
archive="$project_root/.tools/swift-debian12.tar.gz"
toolchain_root="$(mktemp -d /tmp/baha-plus-swift.XXXXXX)"
mkdir -p "$toolchain_root/gnupg"
chmod 700 "$toolchain_root/gnupg"

gpg --homedir "$toolchain_root/gnupg" --batch --import \
  "$project_root/.tools/swift-release-keys.asc"
gpg --homedir "$toolchain_root/gnupg" --batch --verify \
  "$archive.sig" "$archive"

mkdir -p "$toolchain_root/toolchain"
tar -xzf "$archive" --strip-components=1 -C "$toolchain_root/toolchain"
if ldd "$toolchain_root/toolchain/usr/bin/swift" | grep -q 'libncurses.so.6 => not found'; then
  mkdir -p "$toolchain_root/deps"
  (
    cd "$toolchain_root/deps"
    apt-get download libncurses6
    dpkg-deb -x ./libncurses6_*.deb ./root
  )
fi
export LD_LIBRARY_PATH="$toolchain_root/deps/root/lib/x86_64-linux-gnu:$toolchain_root/deps/root/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
"$toolchain_root/toolchain/usr/bin/swift" --version
printf '%s\n' "$toolchain_root/toolchain" > "$project_root/.tools/swift-wsl-path.txt"
printf 'Project Swift toolchain ready: %s\n' "$toolchain_root/toolchain"
