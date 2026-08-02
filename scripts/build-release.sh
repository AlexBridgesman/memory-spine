#!/usr/bin/env bash
# Build a deterministic source archive and SHA-256 manifest from an exact git ref.
set -euo pipefail

REF="${1:-HEAD}"
OUT="${2:-dist}"
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
command -v git >/dev/null 2>&1 || { echo "git is required" >&2; exit 1; }
COMMIT=$(git -C "$ROOT" rev-parse --verify "${REF}^{commit}")
TREE=$(git -C "$ROOT" rev-parse --verify "${COMMIT}^{tree}")
# Archive identity is a pure function of tracked commit content, not refs added
# later or repository-specific abbreviation settings.
VERSION=$(git -C "$ROOT" show "$COMMIT:VERSION" 2>/dev/null | tr -d '\r\n')
printf '%s' "$VERSION" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$' \
  || { echo "invalid or missing VERSION at $COMMIT" >&2; exit 1; }
SAFE_VERSION="$VERSION"
ARCHIVE="memory-spine-${SAFE_VERSION}.tar.gz"
PREFIX="memory-spine-${SAFE_VERSION}/"
mkdir -p "$OUT"
OUT=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$OUT")
TMP_TAR=$(mktemp "${TMPDIR:-/tmp}/memory-spine-release.XXXXXX.tar")
trap 'rm -f "$TMP_TAR"' EXIT INT TERM HUP

git -C "$ROOT" -c tar.umask=0022 archive --format=tar --prefix="$PREFIX" \
  --output="$TMP_TAR" "$COMMIT"
python3 - "$TMP_TAR" "$OUT/$ARCHIVE" "$PREFIX" "$COMMIT" "$TREE" "$VERSION" <<'PY'
import gzip
import io
import shutil
import sys
import tarfile

tar_path, archive, prefix, commit, tree, version = sys.argv[1:]
payload = f"commit={commit}\ntree={tree}\nversion={version}\n".encode()
info = tarfile.TarInfo(prefix + "RELEASE-METADATA")
info.size = len(payload)
info.mode = 0o644
info.mtime = 0
info.uid = info.gid = 0
info.uname = info.gname = "root"
with tarfile.open(tar_path, "a") as bundle:
    bundle.addfile(info, io.BytesIO(payload))
with open(tar_path, "rb") as source, open(archive, "wb") as raw:
    with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
        shutil.copyfileobj(source, compressed)
PY
DIGEST=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$OUT/$ARCHIVE")
printf '%s  %s\n' "$DIGEST" "$ARCHIVE" > "$OUT/SHA256SUMS"
printf 'commit=%s\nref=%s\narchive=%s\nsha256=%s\n' \
  "$COMMIT" "$REF" "$ARCHIVE" "$DIGEST" > "$OUT/PROVENANCE.txt"
printf 'Built %s from %s\n' "$OUT/$ARCHIVE" "$COMMIT"
