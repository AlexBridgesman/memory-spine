#!/usr/bin/env bash
set -euo pipefail

REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/memory-spine-release-archive.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP
CLONE="$TMP/repo"
git clone -q --no-hardlinks "$REPO" "$CLONE"
cp "$REPO/scripts/build-release.sh" "$CLONE/scripts/build-release.sh"
cp "$REPO/VERSION" "$CLONE/VERSION"
if ! git -C "$CLONE" diff --quiet -- VERSION || [ -n "$(git -C "$CLONE" status --short -- VERSION)" ]; then
  git -C "$CLONE" add VERSION
  git -C "$CLONE" -c user.name=ReleaseTest -c user.email=release-test@example.invalid \
    commit -q -m "test: overlay release version"
fi
SHA=$(git -C "$CLONE" rev-parse HEAD)

build_with_umask() {
  value="$1" out="$2"
  git -C "$CLONE" config tar.umask "$value"
  "$CLONE/scripts/build-release.sh" "$SHA" "$out" >/dev/null
}

build_with_umask 0000 "$TMP/a"
build_with_umask 0077 "$TMP/b"
set -- "$TMP/a"/*.tar.gz; A="$1"
set -- "$TMP/b"/*.tar.gz; B="$1"
cmp -s "$A" "$B" || { echo "FAIL: archive inherited ambient tar.umask" >&2; exit 1; }

# Adding a ref later must not change the bytes produced from the same exact SHA.
git -C "$CLONE" tag adversarial-late-tag "$SHA"
build_with_umask 0022 "$TMP/tagged"
set -- "$TMP/tagged"/*.tar.gz; TAGGED="$1"
[ "$(basename "$A")" = "$(basename "$TAGGED")" ] \
  || { echo "FAIL: exact-SHA archive name changed after adding a tag" >&2; exit 1; }
cmp -s "$A" "$TAGGED" \
  || { echo "FAIL: exact-SHA archive bytes changed after adding a tag" >&2; exit 1; }

python3 - "$A" "$SHA" <<'PY'
import sys, tarfile
archive, sha = sys.argv[1:]
with tarfile.open(archive, "r:gz") as bundle:
    members = bundle.getmembers()
    metadata = bundle.extractfile(next(m for m in members if m.name.endswith("/RELEASE-METADATA"))).read().decode()
    assert f"commit={sha}\n" in metadata
    for member in members:
        mode = member.mode & 0o777
        if member.isdir():
            assert mode == 0o755, (member.name, oct(mode))
        elif member.isfile():
            expected = 0o755 if mode & 0o111 else 0o644
            assert mode == expected, (member.name, oct(mode), oct(expected))
PY

echo "release-archive-test: PASS"
