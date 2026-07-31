#!/usr/bin/env bash
set -euo pipefail

REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/memory-spine-selftest-isolation.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP
HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR"
HOME="$HOME_DIR" "$REPO/install.sh" --apply --yes \
  --projects alpha --agents agent-one,user >/dev/null
TOOLS="$HOME_DIR/dev/memory-spine"
ROOT="$HOME_DIR/AgentMemory"
LEDGER=$(HOME="$HOME_DIR" bash -c '. "$1"; spine_default_ledger' _ \
  "$TOOLS/lib/spine_paths.sh")

snapshot() {
  local out="$1"
  {
    git -C "$ROOT" status --porcelain
    shasum -a 256 "$TOOLS/bin/spine-secrets-lint"
    [ ! -f "$LEDGER" ] || shasum -a 256 "$LEDGER"
    find "$ROOT" -name 'INDEX.md' -type f -print0 | sort -z | xargs -0 shasum -a 256
  } > "$out"
}

snapshot "$TMP/before"
HOME="$HOME_DIR" "$TOOLS/bin/spine-selftest" >/dev/null
snapshot "$TMP/after"
cmp -s "$TMP/before" "$TMP/after" || {
  echo "FAIL: selftest changed live vault/index/ledger/scanner state" >&2
  diff -u "$TMP/before" "$TMP/after" >&2 || true
  exit 1
}
printf 'selftest-isolation: PASS\n'
