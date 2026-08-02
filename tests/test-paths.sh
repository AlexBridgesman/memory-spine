#!/usr/bin/env bash
set -euo pipefail

REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/memory-spine-paths-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP
mkdir -p "$TMP/fakebin" "$TMP/home"
printf '#!/bin/sh\necho Linux\n' > "$TMP/fakebin/uname"
chmod +x "$TMP/fakebin/uname"
printf '#!/bin/sh\nexit 0\n' > "$TMP/fakebin/python3"
chmod +x "$TMP/fakebin/python3"
REAL_PYTHON=$(command -v python3)
cat > "$TMP/fakebin/stat" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -f ]; then
  printf 'simulated noisy GNU stat output\n'
  exit 1
fi
if [ "${1:-}" = -c ]; then
  case "$2" in
    %Y|%s) exec "$SPINE_TEST_REAL_PYTHON" -c 'import os,sys
s=os.stat(sys.argv[2]); print(int(s.st_mtime) if sys.argv[1] == "%Y" else s.st_size)' "$2" "$3" ;;
  esac
fi
exit 2
EOF
chmod +x "$TMP/fakebin/stat"

EXPECTED="$TMP/xdg/AgentMemory"
ACTUAL=$(HOME="$TMP/home" XDG_DATA_HOME="$TMP/xdg" PATH="$TMP/fakebin:$PATH" bash -c \
  '. "$1/lib/spine_paths.sh"; printf "%s|%s|%s|%s" "$(spine_default_state_root)" "$(spine_default_log_root)" "$(spine_default_remote_root)" "$(spine_default_ledger)"' _ "$REPO")
[ "$ACTUAL" = "$EXPECTED|$EXPECTED/logs|$EXPECTED/Remotes|$EXPECTED/ledger.tsv" ] || {
  echo "FAIL: shell Linux paths: $ACTUAL" >&2
  exit 1
}

RESOLVED=$(HOME="$TMP/home" PATH="$TMP/fakebin:/bin:/usr/bin" bash -c \
  '. "$1/lib/spine_paths.sh"; spine_resolve_python' _ "$REPO")
[ "$RESOLVED" = "$TMP/fakebin/python3" ] || {
  echo "FAIL: PATH-only Python resolver: $RESOLVED" >&2
  exit 1
}
if HOME="$TMP/home" PATH="$TMP/fakebin:/bin:/usr/bin" SPINE_PYTHON="$TMP/missing-python" \
  bash -c '. "$1/lib/spine_paths.sh"; spine_resolve_python' _ "$REPO" >/dev/null 2>&1; then
  echo "FAIL: invalid explicit SPINE_PYTHON silently fell back" >&2
  exit 1
fi

STAT_VALUES=$(HOME="$TMP/home" PATH="$TMP/fakebin:$PATH" SPINE_TEST_REAL_PYTHON="$REAL_PYTHON" \
  bash -c '. "$1/lib/spine_paths.sh"; printf "%s|%s" "$(spine_file_mtime "$2")" "$(spine_file_size "$2")"' \
  _ "$REPO" "$REPO/README.md")
STAT_MTIME=${STAT_VALUES%%|*}
STAT_SIZE=${STAT_VALUES#*|}
case "$STAT_MTIME" in ''|*[!0-9]*) echo "FAIL: invalid shared mtime: $STAT_VALUES" >&2; exit 1;; esac
case "$STAT_SIZE" in ''|*[!0-9]*) echo "FAIL: invalid shared size: $STAT_VALUES" >&2; exit 1;; esac

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
