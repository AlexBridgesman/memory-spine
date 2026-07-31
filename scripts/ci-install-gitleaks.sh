#!/usr/bin/env bash
# Install the exact gitleaks release used by CI into a caller-owned directory.
set -euo pipefail

VERSION="8.24.3"
DEST="${1:?usage: ci-install-gitleaks.sh DEST_DIR}"
OS=$(uname -s)
ARCH=$(uname -m)
case "$OS/$ARCH" in
  Linux/x86_64) asset="gitleaks_${VERSION}_linux_x64.tar.gz"; expected="9991e0b2903da4c8f6122b5c3186448b927a5da4deef1fe45271c3793f4ee29c" ;;
  Linux/aarch64|Linux/arm64) asset="gitleaks_${VERSION}_linux_arm64.tar.gz"; expected="5f2edbe1f49f7b920f9e06e90759947d3c5dfc16f752fb93aaafc17e9d14cf07" ;;
  Darwin/x86_64) asset="gitleaks_${VERSION}_darwin_x64.tar.gz"; expected="41c44ae8ad1d6eef57d4526ad0fd67d8129eee9a856f55c2b3b9395fd3d9ec0f" ;;
  Darwin/arm64) asset="gitleaks_${VERSION}_darwin_arm64.tar.gz"; expected="b90f13bb8c90ab72083d9b0c842e39dafb82c0e5c3f872f407366b7a58909013" ;;
  *) echo "Unsupported CI platform: $OS/$ARCH" >&2; exit 2 ;;
esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/gitleaks-install.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM HUP
url="https://github.com/gitleaks/gitleaks/releases/download/v${VERSION}/${asset}"
curl --fail --silent --show-error --location "$url" --output "$tmp/$asset"
actual=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$tmp/$asset")
[ "$actual" = "$expected" ] || { echo "Checksum mismatch for $asset" >&2; exit 1; }
tar -xzf "$tmp/$asset" -C "$tmp" gitleaks
mkdir -p "$DEST"
install -m 0755 "$tmp/gitleaks" "$DEST/gitleaks"
"$DEST/gitleaks" version
