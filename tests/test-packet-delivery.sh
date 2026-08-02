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
[ ! -f "$REPO/lib/spine_packet_health.py" ] || cp "$REPO/lib/spine_packet_health.py" "$TOOLS/lib/spine_packet_health.py"
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

cp "$VAULT/_index/packet-alpha.md" "$TMP/packet-alpha.saved"
empty_before=$(cat "$marker")
: > "$VAULT/_index/packet-alpha.md"
set +e
run_packet > "$TMP/empty.out" 2> "$TMP/empty.err"
empty_rc=$?
set -e
mv "$TMP/packet-alpha.saved" "$VAULT/_index/packet-alpha.md"
[ "$empty_rc" -ne 0 ] || fail "empty packet returned success"
[ ! -s "$TMP/empty.out" ] || fail "empty packet emitted bytes"
[ "$(cat "$marker")" = "$empty_before" ] || fail "empty packet advanced the delivery cursor"
grep -Fq "packet for 'alpha' is empty" "$TMP/empty.err" \
  || fail "empty packet did not produce a fail-closed diagnostic"

# Hook delivery is two-phase: packet rendering stages a cursor, and only the
# caller that successfully writes to the real session sink may publish it.
pending_marker="$LOGS/markers/.pending-contract"
initial_marker=$(cat "$marker")
run_packet --defer-marker "$pending_marker" > "$TMP/deferred.out" 2> "$TMP/deferred.err"
[ -f "$pending_marker" ] || fail "deferred delivery did not stage its cursor"
[ "$(cat "$marker")" = "$initial_marker" ] || fail "deferred delivery advanced the live cursor early"
mv "$pending_marker" "$marker"
[ "$(cat "$marker")" != "$initial_marker" ] || fail "published deferred cursor did not advance"

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
os.utime(sys.argv[1],(marker+0.001,marker+0.001))
PY
before=$(cat "$marker")
run_packet > "$TMP/delta.out" 2> "$TMP/delta.err"
delta_bytes=$(wc -c < "$TMP/delta.out" | tr -d ' ')
[ "$delta_bytes" -le 4000 ] || fail "base packet plus delta exceeded configured 4,000-byte cap"
grep -Fq 'Delivery cap delta sentinel' "$TMP/delta.out" || fail "small delta did not use the reserved delivery budget"
after=$(cat "$marker")
[ "$after" != "$before" ] || fail "marker did not advance after a delivered delta"

# Byte trimming must retain an honest omission count before the cursor advances.
python3 - "$VAULT/alpha/facts" "$marker" <<'PY'
from pathlib import Path
import os,sys
root=Path(sys.argv[1])
marker=float(Path(sys.argv[2]).read_text(encoding='utf-8'))
for i in range(20):
    path=root / f"overflow-{i:02d}.md"
    path.write_text(
        "---\n"
        "type: fact\n"
        f"title: Overflow delta {i:02d} " + ("x" * 220) + "\n"
        "summary: Synthetic overflow delta.\n"
        "status: active\n"
        "sensitivity: normal\n"
        "confidence: verified\n"
        "created: 2026-08-01T00:00:00Z\n"
        "agent: user\n"
        "---\nSynthetic overflow.\n",
        encoding="utf-8",
    )
    os.utime(path, (marker + 0.001, marker + 0.001))
PY
run_packet > "$TMP/overflow.out" 2> "$TMP/overflow.err"
grep -Eq '\(\.\.\.[0-9]+ more updated\)' "$TMP/overflow.out" \
  || fail "byte-trimmed delta lost its omission count"
run_packet > "$TMP/overflow-repeat.out" 2> "$TMP/overflow-repeat.err"
grep -Fq -- "--- DELTA for scope 'alpha'" "$TMP/overflow-repeat.out" \
  && fail "represented overflow delta replayed after marker advance"

# A closed stdout sink must not consume the delta marker.
python3 - "$VAULT/alpha/facts/broken-pipe.md" "$marker" <<'PY'
from pathlib import Path
import os,sys
path=Path(sys.argv[1]); marker=float(Path(sys.argv[2]).read_text(encoding='utf-8'))
path.write_text(
    "---\ntype: fact\ntitle: Broken pipe delta sentinel\n"
    "summary: Must replay after a failed stdout flush.\nstatus: active\n"
    "sensitivity: normal\nconfidence: verified\ncreated: 2026-08-01T00:00:00Z\n"
    "agent: user\n---\nSynthetic broken-pipe delta.\n",
    encoding="utf-8",
)
os.utime(path, (marker + 0.001, marker + 0.001))
PY
before_broken=$(cat "$marker")
python3 - "$TOOLS/bin/spine-packet" "$marker" "$VAULT" "$TOOLS" "$LOGS" <<'PY'
import os,subprocess,sys
packet,marker,vault,tools,logs=sys.argv[1:]
read_fd,write_fd=os.pipe(); os.close(read_fd)
env=os.environ.copy()
env.update({"SPINE_ROOT":vault,"SPINE_TOOLS_DIR":tools,"SPINE_CONFIG_DIR":tools+"/config",
            "SPINE_LOG_DIR":logs,"SPINE_NO_GATE":"1"})
proc=subprocess.run([packet,"--project","alpha","--agent","contract"],
                    env=env,stdout=write_fd,stderr=subprocess.PIPE,text=True,check=False)
os.close(write_fd)
if proc.returncode == 0:
    raise SystemExit("FAIL: closed stdout sink returned success")
PY
[ "$(cat "$marker")" = "$before_broken" ] || fail "broken stdout advanced the delta marker"
run_packet > "$TMP/broken-replay.out" 2> "$TMP/broken-replay.err"
grep -Fq 'Broken pipe delta sentinel' "$TMP/broken-replay.out" \
  || fail "delta lost after broken stdout instead of replaying"

# Exercise the recovery path independently of delta and assert real content.
cat > "$VAULT/alpha/facts/recent.md" <<'EOF'
---
type: fact
title: Recent recovery sentinel
summary: A newest record for the explicit recent-record path.
status: active
sensitivity: normal
confidence: verified
created: 2099-01-01T00:00:00Z
agent: user
---
Synthetic recent record.
EOF
run_packet --no-delta --recent 1 > "$TMP/recent.out" 2> "$TMP/recent.err"
recent_bytes=$(wc -c < "$TMP/recent.out" | tr -d ' ')
[ "$recent_bytes" -le 4000 ] || fail "base packet plus recent records exceeded configured cap"
grep -Fq -- "--- RECENT RECORDS of scope 'alpha'" "$TMP/recent.out" \
  || fail "recent path did not emit its section"
grep -Fq 'Recent recovery sentinel' "$TMP/recent.out" \
  || fail "recent path did not emit the newest record"

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
