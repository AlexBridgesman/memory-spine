#!/usr/bin/env bash
set -euo pipefail

# Contract: per-scope packet caps from config/packet-limits.conf.
#   1. a capped scope ships a packet no larger than its configured cap;
#   2. a scope absent from the config keeps the built-in default;
#   3. a cap below the floor is clamped to 4000, never taken literally;
#   4. a malformed line warns on stderr and never aborts generation.
# Everything runs against an isolated vault -- the live one is never touched.

REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/memory-spine-packet-limits-test.XXXXXX")"
TMP="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$TMP")"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

export SPINE_ROOT="$TMP/vault"
export SPINE_CONFIG_DIR="$TMP/config"
mkdir -p "$SPINE_CONFIG_DIR" "$SPINE_ROOT/_index"

printf '%s\n' capped floored default > "$SPINE_CONFIG_DIR/projects.txt"
printf '%s\n' user > "$SPINE_CONFIG_DIR/agents.txt"
cat > "$SPINE_CONFIG_DIR/packet-limits.conf" <<'CONF'
# scope<TAB>bytes
capped	6000
floored	100
this line is malformed
CONF

# Synthetic records, written directly: this exercises spine-gen, not the write
# path. Long titles + summaries make every scope outgrow the smallest cap.
make_records() {
  local scope="$1" count="$2" i
  mkdir -p "$SPINE_ROOT/$scope/facts"
  for i in $(seq 1 "$count"); do
    cat > "$SPINE_ROOT/$scope/facts/2026-01-01--rec-$i--01J0000000000000000000$(printf '%04d' "$i").md" <<REC
---
type: fact
project: $scope
agent: user
title: "Synthetic record $i with a deliberately long descriptive title for sizing"
summary: "A long synthetic summary line number $i that pads the packet body with enough bytes to make the per-scope cap the binding constraint rather than the record count."
status: active
created: 2026-01-01T00:00:0${i:0:1}Z
sources:
  - session:synthetic-packet-limits
sensitivity: normal
confidence: verified
---

Synthetic body $i. [[$scope]]
REC
  done
}

make_records capped 60
make_records floored 40
make_records default 60

GEN_ERR="$TMP/gen.err"
"$REPO/bin/spine-gen" >/dev/null 2>"$GEN_ERR" || fail "spine-gen aborted with a malformed limits line present"
grep -q "malformed line" "$GEN_ERR" || fail "malformed limits line produced no stderr warning"

psize() { wc -c < "$SPINE_ROOT/_index/packet-$1.md" | tr -d ' '; }

CAPPED=$(psize capped)
FLOORED=$(psize floored)
DEFAULT=$(psize default)

[ "$CAPPED" -le 6000 ] || fail "capped scope shipped $CAPPED bytes, cap is 6000"
[ "$DEFAULT" -gt 6000 ] || fail "default scope shipped only $DEFAULT bytes -- the cap leaked onto an unlisted scope"
[ "$DEFAULT" -le 14000 ] || fail "default scope shipped $DEFAULT bytes, built-in default is 14000"
[ "$FLOORED" -le 4000 ] || fail "floored scope shipped $FLOORED bytes, clamped floor is 4000"
[ "$FLOORED" -gt 1000 ] || fail "floored scope shipped $FLOORED bytes -- a 100-byte cap was taken literally"

echo "PASS: packet limits (capped=$CAPPED default=$DEFAULT floored=$FLOORED)"
