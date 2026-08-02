#!/usr/bin/env bash
set -euo pipefail

REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/memory-spine-packet-limits.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP
HOME_DIR="$TMP/home"
TOOLS="$HOME_DIR/dev/memory-spine"
VAULT="$HOME_DIR/AgentMemory"
mkdir -p "$TOOLS/bin" "$TOOLS/lib" "$TOOLS/config" "$VAULT/_index"
cp "$REPO/bin/spine-gen" "$TOOLS/bin/spine-gen"
cp "$REPO/lib/"*.py "$TOOLS/lib/"
chmod +x "$TOOLS/bin/spine-gen"
printf 'capped-tab\ncapped-equals\ndefault\nfloored\nexplicit-floor\nblocked\npins\n' > "$TOOLS/config/projects.txt"
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

for scope in capped-tab capped-equals default floored explicit-floor; do
  make_records "$scope"
done

mkdir -p "$VAULT/blocked/facts" "$VAULT/pins/facts" "$VAULT/pins/decisions"
cat > "$VAULT/blocked/facts/blocked.md" <<'EOF'
---
type: fact
title: Blocked fact sentinel
summary: Must appear only once and count as one shipped identity.
status: blocked
sensitivity: normal
confidence: verified
created: 2026-08-01T00:00:00Z
agent: user
---
Synthetic blocked record.
EOF
cat > "$VAULT/blocked/facts/active.md" <<'EOF'
---
type: fact
title: Active fact sentinel
summary: Keeps the facts invariant healthy.
status: active
sensitivity: normal
confidence: verified
created: 2026-08-01T00:00:00Z
agent: user
---
Synthetic active record.
EOF
cat > "$VAULT/pins/decisions/blocker.md" <<'EOF'
---
type: decision
title: Ordinary blocker sentinel
summary: Must follow every pinned record.
status: blocked
sensitivity: normal
confidence: verified
created: 2026-08-01T00:00:00Z
agent: user
---
Synthetic blocker.
EOF
i=1
while [ "$i" -le 12 ]; do
  cat > "$VAULT/pins/facts/pin-$i.md" <<EOF
---
type: fact
title: Protected pin $i
summary: A pinned environment fact that must never be trimmed from a successful packet.
status: active
sensitivity: normal
confidence: verified
pinned: true
created: 2026-08-01T00:00:00Z
agent: user
---
Synthetic pin.
EOF
  i=$((i + 1))
done

# Missing optional config is quiet and keeps the default.
SPINE_ROOT="$VAULT" SPINE_TOOLS_DIR="$TOOLS" "$TOOLS/bin/spine-gen" default \
  >"$TMP/missing.out" 2>"$TMP/missing.err"
[ ! -s "$TMP/missing.err" ] || fail "missing optional config emitted a warning"
missing_bytes=$(wc -c < "$VAULT/_index/packet-default.md" | tr -d ' ')
[ "$missing_bytes" -le 14000 ] || fail "missing-config default exceeded 14,000 bytes"
[ "$missing_bytes" -gt 4000 ] || fail "missing-config fixture did not distinguish the default from the floor"

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
    b"explicit-floor=4000\n"
    b"blocked=8000\n"
    b"pins=4000\n"
    b"raw-private-setting\n"
    b"unknown-private-scope=8000\n"
    b"bad-encoding-\xff=9000\n"
    b"floored=private-not-an-integer\n"
)
PY
SPINE_ROOT="$VAULT" SPINE_TOOLS_DIR="$TOOLS" "$TOOLS/bin/spine-gen" \
  >"$TMP/configured.out" 2>"$TMP/configured.err" || fail "bad optional entries aborted generation"
for expected in \
  "packet-limits.conf:8: malformed entry; ignored" \
  "packet-limits.conf:9: unknown scope; ignored" \
  "packet-limits.conf:10: invalid UTF-8; ignored" \
  "packet-limits.conf:11: byte limit is not an integer; ignored"; do
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
explicit_floor_bytes=$(wc -c < "$VAULT/_index/packet-explicit-floor.md" | tr -d ' ')
[ "$tab_bytes" -le 6000 ] || fail "tab-configured packet exceeded 6,000 bytes"
[ "$tab_bytes" -gt 3500 ] || fail "tab fixture did not exercise its base budget"
[ "$equals_bytes" -le 7000 ] || fail "equals-configured packet exceeded 7,000 bytes"
[ "$equals_bytes" -gt 4000 ] || fail "equals fixture did not exercise its base budget"
[ "$default_bytes" -le 14000 ] || fail "unlisted packet exceeded 14,000 bytes"
[ "$default_bytes" -gt 4000 ] || fail "unlisted scope did not distinguish the default from the floor"
[ "$floor_bytes" -le 4000 ] || fail "minimum clamp exceeded 4,000 bytes"
[ "$floor_bytes" -gt 1800 ] || fail "minimum-clamp fixture did not exercise the 4,000-byte delivery floor"
[ "$explicit_floor_bytes" -le 4000 ] || fail "explicit 4,000-byte packet exceeded its cap"

stats="$VAULT/_index/.packet-stats.tsv"
python3 - "$stats" "$TOOLS/config/projects.txt" "$TOOLS/config" <<'PY'
from pathlib import Path
import sys
sys.path.insert(0, str(Path(sys.argv[3]).parent / "lib"))
from spine_packet_limits import load_limits
rows={}
for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    scope,passed,shipped,facts=line.split("\t")
    assert scope not in rows, f"duplicate stats row: {scope}"
    rows[scope]=(int(passed),int(shipped),int(facts))
projects=[x for x in Path(sys.argv[2]).read_text().splitlines() if x and not x.startswith("#")]
assert set(rows)==set(projects), (rows.keys(),projects)
assert rows["blocked"]==(2,2,1), rows["blocked"]
assert rows["pins"]==(13,13,1), rows["pins"]
limits=load_limits(sys.argv[3], projects, lambda _message: None)
assert limits["floored"]==limits["explicit-floor"]==4000, limits
PY
python3 "$REPO/lib/spine_packet_health.py" --strict --projects "$TOOLS/config/projects.txt" "$stats" \
  >/dev/null || fail "complete generated stats failed strict health validation"
[ "$(grep -c 'Protected pin ' "$VAULT/_index/packet-pins.md")" = 12 ] \
  || fail "a pinned record fell out of a successful packet"
first_pin=$(grep -n 'Protected pin ' "$VAULT/_index/packet-pins.md" | head -1 | cut -d: -f1)
blocker=$(grep -n 'Ordinary blocker sentinel' "$VAULT/_index/packet-pins.md" | cut -d: -f1)
[ "$first_pin" -lt "$blocker" ] || fail "ordinary blocker rendered before protected pins"

# A targeted invocation must still publish one complete statistics snapshot.
SPINE_ROOT="$VAULT" SPINE_TOOLS_DIR="$TOOLS" "$TOOLS/bin/spine-gen" capped-tab >/dev/null
python3 - "$stats" "$TOOLS/config/projects.txt" <<'PY'
from pathlib import Path
import sys
rows=[line.split("\t",1)[0] for line in Path(sys.argv[1]).read_text().splitlines()]
projects=[x for x in Path(sys.argv[2]).read_text().splitlines() if x and not x.startswith("#")]
assert sorted(rows)==sorted(projects), (rows,projects)
assert len(rows)==len(set(rows)), rows
PY

# A present but unreadable-as-a-file config falls back loudly and safely.
rm "$TOOLS/config/packet-limits.conf"
mkdir "$TOOLS/config/packet-limits.conf"
SPINE_ROOT="$VAULT" SPINE_TOOLS_DIR="$TOOLS" "$TOOLS/bin/spine-gen" default \
  >"$TMP/read-error.out" 2>"$TMP/read-error.err" || fail "config read failure aborted generation"
grep -Fq "packet-limits.conf: cannot read; using defaults" "$TMP/read-error.err" \
  || fail "config read failure was silent"
read_error_bytes=$(wc -c < "$VAULT/_index/packet-default.md" | tr -d ' ')
[ "$read_error_bytes" -le 14000 ] || fail "read-error fallback exceeded default cap"
[ "$read_error_bytes" -gt 4000 ] || fail "read-error fallback did not distinguish the default from the floor"

# Statistics publication errors are release-blocking, never swallowed.
rm -rf "$TOOLS/config/packet-limits.conf" "$stats"
mkdir "$stats"
set +e
SPINE_ROOT="$VAULT" SPINE_TOOLS_DIR="$TOOLS" "$TOOLS/bin/spine-gen" default \
  >"$TMP/stats-write.out" 2>"$TMP/stats-write.err"
stats_rc=$?
set -e
[ "$stats_rc" -ne 0 ] || fail "statistics write failure was silently accepted"
grep -Eq 'cannot (invalidate previous|publish) packet statistics' "$TMP/stats-write.err" \
  || fail "statistics write failure lacked an actionable diagnostic"

# Successful generation never drops pins. If pins alone cannot fit, fail before
# publishing a misleading partial packet.
OVER_TOOLS="$TMP/overflow-tools"
OVER_VAULT="$TMP/overflow-vault"
mkdir -p "$OVER_TOOLS/bin" "$OVER_TOOLS/lib" "$OVER_TOOLS/config" \
  "$OVER_VAULT/_index" "$OVER_VAULT/overflow/facts"
cp "$REPO/bin/spine-gen" "$OVER_TOOLS/bin/spine-gen"
cp "$REPO/bin/spine-packet" "$OVER_TOOLS/bin/spine-packet"
cp "$REPO/lib/"*.py "$OVER_TOOLS/lib/"
chmod +x "$OVER_TOOLS/bin/spine-gen" "$OVER_TOOLS/bin/spine-packet"
printf 'overflow\n' > "$OVER_TOOLS/config/projects.txt"
printf 'user\n' > "$OVER_TOOLS/config/agents.txt"
printf 'overflow=4000\n' > "$OVER_TOOLS/config/packet-limits.conf"
i=1
while [ "$i" -le 100 ]; do
  cat > "$OVER_VAULT/overflow/facts/pin-$i.md" <<EOF
---
type: fact
title: Overflow protected pin number $i with a deliberately long stable title
summary: This pin must not be silently dropped by the configured packet cap.
status: blocked
sensitivity: normal
confidence: verified
pinned: true
created: 2026-08-01T00:00:00Z
agent: user
---
Synthetic overflow pin.
EOF
  if [ "$i" -eq 1 ]; then
    SPINE_ROOT="$OVER_VAULT" SPINE_TOOLS_DIR="$OVER_TOOLS" "$OVER_TOOLS/bin/spine-gen" >/dev/null
    [ -f "$OVER_VAULT/_index/.packet-stats.tsv" ] || fail "good generation did not publish statistics"
    grep -Fq '📌 [BLOCKED] Overflow protected pin number 1' "$OVER_VAULT/_index/packet-overflow.md" \
      || fail "blocked pin lost its blocked state in packet rendering"
    cp "$OVER_VAULT/_index/packet-overflow.md" "$TMP/good-overflow-packet.md"
  fi
  i=$((i + 1))
done
set +e
SPINE_ROOT="$OVER_VAULT" SPINE_TOOLS_DIR="$OVER_TOOLS" "$OVER_TOOLS/bin/spine-gen" \
  >"$TMP/pin-overflow.out" 2>"$TMP/pin-overflow.err"
overflow_rc=$?
set -e
[ "$overflow_rc" -ne 0 ] || fail "pin overflow silently produced a partial packet"
grep -Fq 'pinned records do not fit' "$TMP/pin-overflow.err" \
  || fail "pin overflow lacked a clear diagnostic"
cmp -s "$TMP/good-overflow-packet.md" "$OVER_VAULT/_index/packet-overflow.md" \
  || fail "pin overflow replaced the previous complete packet"
[ ! -e "$OVER_VAULT/_index/.packet-stats.tsv" ] \
  || fail "failed generation left a health snapshot that could appear current"
set +e
SPINE_ROOT="$OVER_VAULT" SPINE_TOOLS_DIR="$OVER_TOOLS" SPINE_NO_GATE=1 \
  "$OVER_TOOLS/bin/spine-packet" --project overflow --agent contract \
  >"$TMP/stale-overflow-packet.out" 2>"$TMP/stale-overflow-packet.err"
stale_packet_rc=$?
set -e
[ "$stale_packet_rc" -ne 0 ] || fail "failed generation left the old packet deliverable"
[ ! -s "$TMP/stale-overflow-packet.out" ] || fail "failed generation served stale pin data"
grep -Fq 'packet snapshot unavailable' "$TMP/stale-overflow-packet.err" \
  || fail "stale packet refusal lacked an actionable diagnostic"

# An unpromoted replacement must not hide the promoted record it supersedes.
SUPER_TOOLS="$TMP/supersede-tools"
SUPER_VAULT="$TMP/supersede-vault"
mkdir -p "$SUPER_TOOLS/bin" "$SUPER_TOOLS/lib" "$SUPER_TOOLS/config" \
  "$SUPER_VAULT/alpha/facts"
cp "$REPO/bin/spine-gen" "$SUPER_TOOLS/bin/spine-gen"
cp "$REPO/lib/"*.py "$SUPER_TOOLS/lib/"
chmod +x "$SUPER_TOOLS/bin/spine-gen"
printf 'alpha\n' > "$SUPER_TOOLS/config/projects.txt"
printf 'user\n' > "$SUPER_TOOLS/config/agents.txt"
ORIGINAL_ULID=01J00000000000000000000001
REPLACEMENT="$SUPER_VAULT/alpha/facts/replacement--01J00000000000000000000002.md"
cat > "$SUPER_VAULT/alpha/facts/original--$ORIGINAL_ULID.md" <<'EOF'
---
type: fact
title: Promoted current knowledge
summary: This remains current until its replacement passes the packet gate.
status: active
sensitivity: normal
confidence: verified
created: 2026-08-01T00:00:00Z
agent: user
---
Synthetic promoted record.
EOF
cat > "$SUPER_VAULT/alpha/facts/untrusted-reviewed--01J00000000000000000000003.md" <<'EOF'
---
type: fact
title: Untrusted reviewed content
summary: Review metadata must not bypass the untrusted auto-injection boundary.
status: active
sensitivity: normal
confidence: untrusted
reviewed_by: owner
created: 2026-08-01T00:00:30Z
agent: user
---
Synthetic external content.
EOF
write_replacement() {
  confidence="$1"
  cat > "$REPLACEMENT" <<EOF
---
type: fact
title: Replacement knowledge
summary: Synthetic replacement at confidence $confidence.
status: active
sensitivity: normal
confidence: $confidence
supersedes: $ORIGINAL_ULID
created: 2026-08-01T00:01:00Z
agent: user
---
Synthetic replacement record.
EOF
}
write_replacement candidate
SPINE_ROOT="$SUPER_VAULT" SPINE_TOOLS_DIR="$SUPER_TOOLS" \
  "$SUPER_TOOLS/bin/spine-gen" >/dev/null
grep -Fq 'Promoted current knowledge' "$SUPER_VAULT/_index/packet-alpha.md" \
  || fail "candidate replacement hid promoted current knowledge"
if grep -Fq 'Untrusted reviewed content' "$SUPER_VAULT/_index/packet-alpha.md"; then
  fail "reviewed_by bypassed the untrusted packet boundary"
fi
if grep -Fq 'Replacement knowledge' "$SUPER_VAULT/_index/packet-alpha.md"; then
  fail "candidate replacement bypassed the packet promotion gate"
fi
grep -Fqx $'alpha\t1\t1\t1' "$SUPER_VAULT/_index/.packet-stats.tsv" \
  || fail "candidate replacement corrupted packet statistics"
write_replacement verified
SPINE_ROOT="$SUPER_VAULT" SPINE_TOOLS_DIR="$SUPER_TOOLS" \
  "$SUPER_TOOLS/bin/spine-gen" >/dev/null
grep -Fq 'Replacement knowledge' "$SUPER_VAULT/_index/packet-alpha.md" \
  || fail "promoted replacement was not shipped"
if grep -Fq 'Promoted current knowledge' "$SUPER_VAULT/_index/packet-alpha.md"; then
  fail "promoted replacement did not hide superseded knowledge"
fi
grep -Fqx $'alpha\t1\t1\t1' "$SUPER_VAULT/_index/.packet-stats.tsv" \
  || fail "promoted replacement corrupted packet statistics"

echo "packet-limits-test: PASS (tab=$tab_bytes equals=$equals_bytes default=$default_bytes floor=$floor_bytes)"
