#!/usr/bin/env bash
set -euo pipefail

REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/memory-spine-cross-agent.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP
HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR"

HOME="$HOME_DIR" "$REPO/install.sh" --apply --yes \
  --projects handoff --agents agent-a,agent-b,user >/dev/null
TOOLS="$HOME_DIR/dev/memory-spine"
ROOT="$HOME_DIR/AgentMemory"
LOGS="$TMP/logs"
COMMON=(env HOME="$HOME_DIR" SPINE_ROOT="$ROOT" SPINE_TOOLS_DIR="$TOOLS" \
  SPINE_CONFIG_DIR="$TOOLS/config" SPINE_LOG_DIR="$LOGS" SPINE_NO_GATE=1)

# Both agents receive an initial packet, establishing independent delta markers.
"${COMMON[@]}" "$TOOLS/bin/spine-packet" --project handoff --agent agent-a >/dev/null
"${COMMON[@]}" "$TOOLS/bin/spine-packet" --project handoff --agent agent-b >/dev/null

TITLE="Agent A checkpoint: catalog handoff ready"
"${COMMON[@]}" "$TOOLS/bin/spine-new" --type fact --project handoff \
  --agent agent-a --for-agent agent-b --confidence verified --title "$TITLE" \
  --summary "Agent B can continue from the recorded catalog checkpoint." \
  --body "Synthetic cross-agent handoff evidence. [[handoff]]" >/dev/null
"${COMMON[@]}" "$TOOLS/bin/spine-gen" >/dev/null

B_PACKET=$("${COMMON[@]}" "$TOOLS/bin/spine-packet" --project handoff --agent agent-b)
echo "$B_PACKET" | grep -Fq -- "--- DELTA for scope 'handoff'" || {
  echo "FAIL: Agent B did not receive a delta" >&2; exit 1;
}
echo "$B_PACKET" | grep -Fq "[fact] $TITLE (agent-a, verified, status:active)" || {
  echo "FAIL: Agent A checkpoint is absent from Agent B delta" >&2; exit 1;
}

# Reading Agent B's delta must not consume Agent A's independent marker.
A_PACKET=$("${COMMON[@]}" "$TOOLS/bin/spine-packet" --project handoff --agent agent-a)
echo "$A_PACKET" | grep -Fq "[fact] $TITLE (agent-a, verified, status:active)" || {
  echo "FAIL: Agent B consumed Agent A's delta marker" >&2; exit 1;
}

# A second Agent B read advances only its marker and must not replay the delta.
B_REPEAT=$("${COMMON[@]}" "$TOOLS/bin/spine-packet" --project handoff --agent agent-b)
if echo "$B_REPEAT" | grep -Fq -- "--- DELTA for scope 'handoff'"; then
  echo "FAIL: Agent B delta replayed after its marker advanced" >&2
  exit 1
fi

printf 'cross-agent-e2e: PASS (Agent A checkpoint -> packet/delta -> Agent B)\n'
