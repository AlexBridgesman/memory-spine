#!/usr/bin/env bash
set -euo pipefail

REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/memory-spine-paths-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP
mkdir -p "$TMP/fakebin" "$TMP/home"
printf '#!/bin/sh\necho Linux\n' > "$TMP/fakebin/uname"
chmod +x "$TMP/fakebin/uname"

EXPECTED="$TMP/xdg/AgentMemory"
ACTUAL=$(HOME="$TMP/home" XDG_DATA_HOME="$TMP/xdg" PATH="$TMP/fakebin:$PATH" bash -c \
  '. "$1/lib/spine_paths.sh"; printf "%s|%s|%s|%s" "$(spine_default_state_root)" "$(spine_default_log_root)" "$(spine_default_remote_root)" "$(spine_default_ledger)"' _ "$REPO")
[ "$ACTUAL" = "$EXPECTED|$EXPECTED/logs|$EXPECTED/Remotes|$EXPECTED/ledger.tsv" ] || {
  echo "FAIL: shell Linux paths: $ACTUAL" >&2
  exit 1
}

HOME="$TMP/home" XDG_DATA_HOME="$TMP/xdg" python3 - "$REPO" "$EXPECTED" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / "lib"))
from spine_paths import default_ledger, default_log_root, default_remote_root, default_state_root
expected = Path(sys.argv[2])
assert default_state_root("Linux") == expected
assert default_log_root("Linux") == expected / "logs"
assert default_remote_root("Linux") == expected / "Remotes"
assert default_ledger("Linux") == expected / "ledger.tsv"
PY

echo "paths-test: PASS"
