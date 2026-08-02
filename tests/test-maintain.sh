#!/usr/bin/env bash
set -euo pipefail

REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/memory-spine-maintain-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP
HOME_DIR="$TMP/home"
TOOLS="$TMP/tools"
ROOT="$TMP/vault"
LOGS="$TMP/logs"
FAKEBIN="$TMP/fakebin"
SNAPS="$TMP/snapshots"
mkdir -p "$TOOLS/bin" "$TOOLS/lib" "$TOOLS/config" "$ROOT" "$LOGS" "$FAKEBIN" \
  "$SNAPS/SNAP-2026-99-99"
cp "$REPO/bin/spine-maintain" "$TOOLS/bin/spine-maintain"
cp "$REPO/lib/spine_paths.sh" "$TOOLS/lib/spine_paths.sh"
chmod +x "$TOOLS/bin/spine-maintain"
printf 'EXTERNAL_VOLUME=synthetic\n' > "$TOOLS/config/backup.conf"
printf 'alpha\n' > "$TOOLS/config/projects.txt"
printf 'user\n' > "$TOOLS/config/agents.txt"

REAL_PYTHON=$(command -v python3)
cat > "$TOOLS/resolved-python" <<EOF
#!/bin/sh
printf 'resolved\n' >> "$TMP/resolved-python.used"
exec "$REAL_PYTHON" "\$@"
EOF
chmod +x "$TOOLS/resolved-python"
cat > "$TOOLS/bin/spine-gen" <<EOF
from pathlib import Path
Path("$TMP/spine-gen.used").write_text("used\n")
EOF
chmod 644 "$TOOLS/bin/spine-gen"
for stub in spine-selftest spine-notify spine-secrets-lint; do
  printf '#!/bin/sh\nexit 0\n' > "$TOOLS/bin/$stub"
  chmod +x "$TOOLS/bin/$stub"
done
cat > "$FAKEBIN/python3" <<EOF
#!/bin/sh
printf 'hostile\n' >> "$TMP/hostile-python.used"
exit 97
EOF
chmod +x "$FAKEBIN/python3"
cat > "$FAKEBIN/gitleaks" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$FAKEBIN/gitleaks"
cat > "$FAKEBIN/stat" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -f ]; then
  printf 'simulated noisy GNU filesystem report\n'
  exit 1
fi
if [ "${1:-}" = -c ]; then
  exec "$SPINE_TEST_REAL_PYTHON" -c 'import os,sys
+s=os.stat(sys.argv[2]); print(int(s.st_mtime) if sys.argv[1] == "%Y" else s.st_size)' "$2" "$3"
fi
exit 2
EOF
chmod +x "$FAKEBIN/stat"

git -C "$ROOT" init -q
printf 'mounted\n' > "$TMP/.mounted"
HOME="$HOME_DIR" PATH="$FAKEBIN:/usr/bin:/bin" \
  SPINE_ROOT="$ROOT" SPINE_TOOLS_DIR="$TOOLS" SPINE_LOG_DIR="$LOGS" \
  SPINE_PYTHON="$TOOLS/resolved-python" SPINE_GITLEAKS="$FAKEBIN/gitleaks" \
  SPINE_BACKUP_MARKER="$TMP/.mounted" SPINE_BACKUP_SNAPSHOT_ROOT="$SNAPS" \
  SPINE_TEST_REAL_PYTHON="$REAL_PYTHON" \
  "$TOOLS/bin/spine-maintain"

[ -f "$TMP/spine-gen.used" ] || { echo "FAIL: maintain bypassed resolved Python for spine-gen" >&2; exit 1; }
[ ! -e "$TMP/hostile-python.used" ] || { echo "FAIL: maintain invoked hostile PATH python3" >&2; exit 1; }
REPORT="$LOGS/maintain-$(date +%F).log"
[ -s "$REPORT" ] || { echo "FAIL: maintain produced no report" >&2; exit 1; }
grep -Fq 'snapshot older than 2 days' "$REPORT" \
  || { echo "FAIL: noisy stat fallback skipped snapshot classification" >&2; exit 1; }
grep -Fq '=== summary:' "$REPORT" || { echo "FAIL: maintain omitted its summary" >&2; exit 1; }

echo "maintain-test: PASS"
