#!/usr/bin/env bash
set -euo pipefail

REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/memory-spine-packet-delivery.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP
HOME_DIR="$TMP/home"
TOOLS="$HOME_DIR/dev/memory-spine"
VAULT="$HOME_DIR/AgentMemory"
LOGS="$TMP/logs"
mkdir -p "$TOOLS/bin" "$TOOLS/lib" "$TOOLS/config" "$VAULT/_index" "$LOGS"
cp "$REPO/bin/spine-gen" "$TOOLS/bin/spine-gen"
cp "$REPO/bin/spine-packet" "$TOOLS/bin/spine-packet"
cp "$REPO/lib/spine_paths.py" "$TOOLS/lib/spine_paths.py"
[ ! -f "$REPO/lib/spine_packet_limits.py" ] || cp "$REPO/lib/spine_packet_limits.py" "$TOOLS/lib/spine_packet_limits.py"
chmod +x "$TOOLS/bin/spine-gen" "$TOOLS/bin/spine-packet"
printf 'alpha\n' > "$TOOLS/config/projects.txt"
printf 'user\n' > "$TOOLS/config/agents.txt"
printf 'alpha=4000\n' > "$TOOLS/config/packet-limits.conf"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

filler=$(python3 -c 'print("x" * 220)')
mkdir -p "$VAULT/alpha/decisions" "$VAULT/alpha/facts"
i=1
while [ "$i" -le 50 ]; do
  cat > "$VAULT/alpha/decisions/decision-$i.md" <<EOF
---
type: decision
title: Baseline decision $i
summary: $filler
status: active
sensitivity: normal
confidence: verified
created: 2026-08-01T00:00:00Z
agent: user
---
Synthetic baseline.
EOF
  i=$((i + 1))
done
SPINE_ROOT="$VAULT" SPINE_TOOLS_DIR="$TOOLS" "$TOOLS/bin/spine-gen" >/dev/null

run_packet() {
  SPINE_ROOT="$VAULT" SPINE_TOOLS_DIR="$TOOLS" SPINE_LOG_DIR="$LOGS" SPINE_NO_GATE=1 \
    "$TOOLS/bin/spine-packet" --project alpha --agent contract "$@"
}

run_packet > "$TMP/initial.out" 2> "$TMP/initial.err"
initial_bytes=$(wc -c < "$TMP/initial.out" | tr -d ' ')
[ "$initial_bytes" -le 4000 ] || fail "initial delivered packet exceeded configured 4,000-byte cap"
marker="$LOGS/markers/last-fire-alpha-contract"
[ -f "$marker" ] || fail "initial delivery did not establish the per-agent marker"

cat > "$VAULT/alpha/facts/delta.md" <<'EOF'
---
type: fact
title: Delivery cap delta sentinel
summary: A short delta that should fit the reserved delivery budget.
status: active
sensitivity: normal
confidence: verified
created: 2026-08-01T00:00:00Z
agent: user
---
Synthetic delta.
EOF
python3 - "$VAULT/alpha/facts/delta.md" "$marker" <<'PY'
import os,sys
marker=float(open(sys.argv[2],encoding='utf-8').read())
os.utime(sys.argv[1],(marker+2,marker+2))
PY
before=$(cat "$marker")
run_packet > "$TMP/delta.out" 2> "$TMP/delta.err"
delta_bytes=$(wc -c < "$TMP/delta.out" | tr -d ' ')
[ "$delta_bytes" -le 4000 ] || fail "base packet plus delta exceeded configured 4,000-byte cap"
grep -Fq 'Delivery cap delta sentinel' "$TMP/delta.out" || fail "small delta did not use the reserved delivery budget"
after=$(cat "$marker")
[ "$after" != "$before" ] || fail "marker did not advance after a delivered delta"

run_packet --recent 100 > "$TMP/recent.out" 2> "$TMP/recent.err"
recent_bytes=$(wc -c < "$TMP/recent.out" | tr -d ' ')
[ "$recent_bytes" -le 4000 ] || fail "base packet plus recent records exceeded configured cap"

# Without the scope dictionary, a configured per-scope limit cannot be
# validated. Delivery must stop instead of falling back to the larger default.
mv "$TOOLS/config/projects.txt" "$TOOLS/config/projects.saved"
SPINE_ROOT="$VAULT" SPINE_TOOLS_DIR="$TOOLS" SPINE_LOG_DIR="$LOGS" SPINE_NO_GATE=1 \
  "$TOOLS/bin/spine-packet" --project alpha --agent test > "$TMP/no-projects.out" 2> "$TMP/no-projects.err"
[ ! -s "$TMP/no-projects.out" ] || fail "packet was delivered without a readable project dictionary"
grep -q 'cannot validate the configured delivery cap' "$TMP/no-projects.err" \
  || fail "missing project dictionary did not produce a safe diagnostic"
mv "$TOOLS/config/projects.saved" "$TOOLS/config/projects.txt"

base_bytes=$(wc -c < "$VAULT/_index/packet-alpha.md" | tr -d ' ')
[ "$base_bytes" -lt 4000 ] || fail "base packet left no delivery budget"

echo "packet-delivery-test: PASS (base=$base_bytes initial=$initial_bytes delta=$delta_bytes recent=$recent_bytes)"
