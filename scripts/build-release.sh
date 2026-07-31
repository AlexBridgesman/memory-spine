#!/usr/bin/env bash
# Build a deterministic source archive and SHA-256 manifest from an exact git ref.
set -euo pipefail

REF="${1:-HEAD}"
OUT="${2:-dist}"
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
command -v git >/dev/null 2>&1 || { echo "git is required" >&2; exit 1; }
COMMIT=$(git -C "$ROOT" rev-parse --verify "${REF}^{commit}")
VERSION=$(git -C "$ROOT" describe --tags --always "$COMMIT")
SAFE_VERSION=$(printf '%s' "$VERSION" | tr -c 'A-Za-z0-9._-' '-')
ARCHIVE="memory-spine-${SAFE_VERSION}.tar.gz"
mkdir -p "$OUT"
OUT=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$OUT")

git -C "$ROOT" archive --format=tar.gz --prefix="memory-spine-${SAFE_VERSION}/" \
  --output="$OUT/$ARCHIVE" "$COMMIT"
DIGEST=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$OUT/$ARCHIVE")
printf '%s  %s\n' "$DIGEST" "$ARCHIVE" > "$OUT/SHA256SUMS"
printf 'commit=%s\nref=%s\narchive=%s\nsha256=%s\n' \
  "$COMMIT" "$REF" "$ARCHIVE" "$DIGEST" > "$OUT/PROVENANCE.txt"
printf 'Built %s from %s\n' "$OUT/$ARCHIVE" "$COMMIT"
