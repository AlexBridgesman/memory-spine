#!/usr/bin/env bash
set -euo pipefail

REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/memory-spine-hook-delivery.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP
TOOLS="$TMP/tools"
VAULT="$TMP/vault"
LOGS="$TMP/logs"
mkdir -p "$TOOLS/bin" "$TOOLS/lib" "$VAULT/_index" "$LOGS" "$TMP/work"
cp "$REPO/bin/spine-hook-sessionstart" "$TOOLS/bin/spine-hook-sessionstart"
cp "$REPO/lib/spine_paths.sh" "$TOOLS/lib/spine_paths.sh"
chmod +x "$TOOLS/bin/spine-hook-sessionstart"
printf 'placeholder\n' > "$VAULT/_index/packet-alpha.md"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

cat > "$TOOLS/bin/spine-packet" <<'EOF'
#!/bin/sh
case " $* " in
  *' --resolve '*) printf 'alpha\n'; exit 0 ;;
esac
if [ "${SPINE_PACKET_MODE:-refuse}" = deliver ]; then
  printf 'verified packet delivery\n'
fi
EOF
chmod +x "$TOOLS/bin/spine-packet"

run_hook() {
  mode="$1"
  printf '{"source":"startup"}\n' | (
    cd "$TMP/work"
    HOME="$TMP/home" SPINE_PACKET_MODE="$mode" SPINE_ROOT="$VAULT" \
      SPINE_TOOLS_DIR="$TOOLS" SPINE_LOG_DIR="$LOGS" \
      "$TOOLS/bin/spine-hook-sessionstart"
  )
}

run_hook refuse > "$TMP/refused.out"
[ ! -s "$TMP/refused.out" ] || fail "refused packet emitted session content"
[ ! -e "$LOGS/.hook-last-fire" ] || fail "zero-byte refusal updated delivery evidence"
if grep -Fq ' fire' "$LOGS/hook.log"; then
  fail "zero-byte refusal was logged as a packet fire"
fi

run_hook deliver > "$TMP/delivered.out"
grep -Fqx 'verified packet delivery' "$TMP/delivered.out" \
  || fail "verified packet bytes were not emitted"
[ -f "$LOGS/.hook-last-fire" ] || fail "verified delivery did not update evidence"
grep -Fq ' fire (startup): alpha' "$LOGS/hook.log" \
  || fail "verified delivery was not logged"

echo "hook-delivery-test: PASS"
