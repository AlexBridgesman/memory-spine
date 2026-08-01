#!/usr/bin/env bash
set -euo pipefail

REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/memory-spine-packet-limits.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP
HOME_DIR="$TMP/home"
TOOLS="$HOME_DIR/dev/memory-spine"
VAULT="$HOME_DIR/AgentMemory"
mkdir -p "$TOOLS/bin" "$TOOLS/config" "$VAULT/_index"
cp "$REPO/bin/spine-gen" "$TOOLS/bin/spine-gen"
chmod +x "$TOOLS/bin/spine-gen"
printf 'capped-tab\ncapped-equals\ndefault\nfloored\n' > "$TOOLS/config/projects.txt"
printf 'user\n' > "$TOOLS/config/agents.txt"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

make_records() {
  scope="$1"
  filler=$(python3 -c 'print("x" * 220)')
  mkdir -p "$VAULT/$scope/decisions" "$VAULT/$scope/facts"
  i=1
  while [ "$i" -le 60 ]; do
    cat > "$VAULT/$scope/decisions/decision-$i.md" <<EOF
---
type: decision
title: Decision $i for $scope
summary: $filler
status: active
sensitivity: normal
confidence: verified
created: 2026-08-01T00:00:00Z
agent: user
---
Synthetic test record.
EOF
    cat > "$VAULT/$scope/facts/fact-$i.md" <<EOF
---
type: fact
title: Fact $i for $scope
summary: $filler
status: active
sensitivity: normal
confidence: verified
created: 2026-08-01T00:00:00Z
agent: user
---
Synthetic test record.
EOF
    i=$((i + 1))
  done
}

for scope in capped-tab capped-equals default floored; do
  make_records "$scope"
done

# Missing optional config is quiet and keeps the default.
SPINE_ROOT="$VAULT" SPINE_TOOLS_DIR="$TOOLS" "$TOOLS/bin/spine-gen" default \
  >"$TMP/missing.out" 2>"$TMP/missing.err"
[ ! -s "$TMP/missing.err" ] || fail "missing optional config emitted a warning"
missing_bytes=$(wc -c < "$VAULT/_index/packet-default.md" | tr -d ' ')
[ "$missing_bytes" -le 14000 ] || fail "missing-config default exceeded 14,000 bytes"
[ "$missing_bytes" -gt 7000 ] || fail "fixture did not exercise the default cap"

# Tabs and equals are both accepted. Bad entries warn by line number without
# echoing owner-controlled values; invalid UTF-8 cannot abort generation.
python3 - "$TOOLS/config/packet-limits.conf" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_bytes(
    b"# optional per-scope packet caps\n"
    b"capped-tab\t6000\n"
    b"capped-equals=7000\n"
    b"floored=1\n"
    b"raw-private-setting\n"
    b"unknown-private-scope=8000\n"
    b"bad-encoding-\xff=9000\n"
    b"floored=private-not-an-integer\n"
)
PY
SPINE_ROOT="$VAULT" SPINE_TOOLS_DIR="$TOOLS" "$TOOLS/bin/spine-gen" \
  >"$TMP/configured.out" 2>"$TMP/configured.err" || fail "bad optional entries aborted generation"
for expected in \
  "packet-limits.conf:5: malformed entry; ignored" \
  "packet-limits.conf:6: unknown scope; ignored" \
  "packet-limits.conf:7: invalid UTF-8; ignored" \
  "packet-limits.conf:8: byte limit is not an integer; ignored"; do
  grep -Fq "$expected" "$TMP/configured.err" || fail "missing sanitized warning: $expected"
done
for private_value in raw-private-setting unknown-private-scope bad-encoding private-not-an-integer; do
  if grep -Fq "$private_value" "$TMP/configured.err"; then
    fail "warning leaked owner-controlled config value"
  fi
done

tab_bytes=$(wc -c < "$VAULT/_index/packet-capped-tab.md" | tr -d ' ')
equals_bytes=$(wc -c < "$VAULT/_index/packet-capped-equals.md" | tr -d ' ')
default_bytes=$(wc -c < "$VAULT/_index/packet-default.md" | tr -d ' ')
floor_bytes=$(wc -c < "$VAULT/_index/packet-floored.md" | tr -d ' ')
[ "$tab_bytes" -le 6000 ] || fail "tab-configured packet exceeded 6,000 bytes"
[ "$equals_bytes" -le 7000 ] || fail "equals-configured packet exceeded 7,000 bytes"
[ "$default_bytes" -le 14000 ] || fail "unlisted packet exceeded 14,000 bytes"
[ "$default_bytes" -gt 7000 ] || fail "unlisted scope did not retain the default"
[ "$floor_bytes" -le 4000 ] || fail "minimum clamp exceeded 4,000 bytes"

# A present but unreadable-as-a-file config falls back loudly and safely.
rm "$TOOLS/config/packet-limits.conf"
mkdir "$TOOLS/config/packet-limits.conf"
SPINE_ROOT="$VAULT" SPINE_TOOLS_DIR="$TOOLS" "$TOOLS/bin/spine-gen" default \
  >"$TMP/read-error.out" 2>"$TMP/read-error.err" || fail "config read failure aborted generation"
grep -Fq "packet-limits.conf: cannot read; using defaults" "$TMP/read-error.err" \
  || fail "config read failure was silent"
read_error_bytes=$(wc -c < "$VAULT/_index/packet-default.md" | tr -d ' ')
[ "$read_error_bytes" -le 14000 ] || fail "read-error fallback exceeded default cap"
[ "$read_error_bytes" -gt 7000 ] || fail "read-error fallback did not use default cap"

echo "packet-limits-test: PASS (tab=$tab_bytes equals=$equals_bytes default=$default_bytes floor=$floor_bytes)"
