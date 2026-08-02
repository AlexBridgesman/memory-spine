#!/usr/bin/env bash
set -euo pipefail

REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/memory-spine-installer-test.XXXXXX")"
TMP="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$TMP")"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_line() {
  local line="$1" file="$2"
  grep -Fqx "$line" "$file" || fail "missing '$line' in $file"
}

# Default execution, including --yes, must be a no-write plan.
PLAN_HOME="$TMP/plan-home"
mkdir -p "$PLAN_HOME"
PLAN_OUT=$(HOME="$PLAN_HOME" "$REPO/install.sh" --yes)
echo "$PLAN_OUT" | grep -Fq "DRY RUN" || fail "default run did not identify itself as dry-run"
[ ! -e "$PLAN_HOME/AgentMemory" ] || fail "default run created the vault"
[ ! -e "$PLAN_HOME/dev/memory-spine" ] || fail "default run created the tools directory"

# Explicit apply creates a working isolated install.
APPLY_HOME="$TMP/apply-home"
mkdir -p "$APPLY_HOME"
HOME="$APPLY_HOME" "$REPO/install.sh" --apply --yes \
  --projects "alpha,beta" --agents "agent-one,user" >/dev/null
TOOLS="$APPLY_HOME/dev/memory-spine"
VAULT="$APPLY_HOME/AgentMemory"
MIRROR=$(HOME="$APPLY_HOME" bash -c \
  '. "$1"; printf "%s/AgentMemory.git\n" "$(spine_default_remote_root)"' _ \
  "$TOOLS/lib/spine_paths.sh")
[ -x "$TOOLS/bin/spine-selftest" ] || fail "tools were not installed"
[ -f "$TOOLS/lib/spine_packet_limits.py" ] || fail "shared packet-limit module was not installed"
[ -f "$TOOLS/lib/spine_packet_health.py" ] || fail "packet-health module was not installed"
[ -d "$VAULT/.git" ] || fail "vault git repository was not initialized"
assert_line alpha "$TOOLS/config/projects.txt"
assert_line beta "$TOOLS/config/projects.txt"
assert_line inbox "$TOOLS/config/projects.txt"
assert_line agent-one "$TOOLS/config/agents.txt"
[ -f "$TOOLS/config/packet-limits.conf.example" ] || fail "packet-limit example was not installed"
[ ! -e "$TOOLS/config/packet-limits.conf" ] || fail "installer enabled packet limits without owner opt-in"
grep -Fq 'Memory Spine installed — genesis record' "$VAULT/_index/packet-alpha.md" \
  || fail "fresh install packet omitted the genesis record"
grep -Eq '^alpha[[:space:]]+[1-9][0-9]*[[:space:]]+[1-9][0-9]*[[:space:]]+1$' \
  "$VAULT/_index/.packet-stats.tsv" \
  || fail "fresh install statistics did not include the genesis fact"

# An upgrade without explicit list flags preserves owner-maintained dictionaries byte-for-byte.
printf 'alpha\nbeta\ninbox\nowner-scope\n' > "$TOOLS/config/projects.txt"
printf 'agent-one\nuser\nowner-agent\n' > "$TOOLS/config/agents.txt"
cp "$TOOLS/config/projects.txt" "$VAULT/config/projects.txt"
cp "$TOOLS/config/agents.txt" "$VAULT/config/agents.txt"
cp "$TOOLS/config/projects.txt" "$TMP/projects.expected"
cp "$TOOLS/config/agents.txt" "$TMP/agents.expected"
HOME="$APPLY_HOME" "$REPO/install.sh" --apply --yes >/dev/null
cmp -s "$TMP/projects.expected" "$TOOLS/config/projects.txt" || fail "upgrade overwrote projects.txt"
cmp -s "$TMP/agents.expected" "$TOOLS/config/agents.txt" || fail "upgrade overwrote agents.txt"
cmp -s "$TMP/projects.expected" "$VAULT/config/projects.txt" || fail "vault projects.txt diverged"
cmp -s "$TMP/agents.expected" "$VAULT/config/agents.txt" || fail "vault agents.txt diverged"

# Explicit list flags on upgrade are additive: they never remove owner entries.
HOME="$APPLY_HOME" "$REPO/install.sh" --apply --yes \
  --projects "research" --agents "new-agent" >/dev/null
for scope in alpha beta inbox owner-scope research; do
  assert_line "$scope" "$TOOLS/config/projects.txt"
done
for agent in agent-one user owner-agent new-agent; do
  assert_line "$agent" "$TOOLS/config/agents.txt"
done
cmp -s "$TOOLS/config/projects.txt" "$VAULT/config/projects.txt" || fail "project dictionaries differ"
cmp -s "$TOOLS/config/agents.txt" "$VAULT/config/agents.txt" || fail "agent dictionaries differ"
cp "$TOOLS/config/projects.txt" "$TMP/rollback-projects.expected"
cp "$TOOLS/config/agents.txt" "$TMP/rollback-agents.expected"
HOME="$APPLY_HOME" "$TOOLS/bin/spine-selftest" || fail "upgraded install failed selftest"

# Uninstall is also plan-first. A late archive failure must restore the hook,
# then a successful apply archives tools without deleting the vault or mirror.
UNINSTALL_PLAN=$(HOME="$APPLY_HOME" "$TOOLS/bin/spine-uninstall")
echo "$UNINSTALL_PLAN" | grep -Fq "DRY RUN" || fail "uninstall default is not dry-run"
[ -d "$TOOLS" ] || fail "uninstall dry-run moved tools"
[ -f "$VAULT/.git/hooks/pre-commit" ] || fail "canonical hook missing before uninstall"
chmod 500 "$APPLY_HOME/dev"
if HOME="$APPLY_HOME" "$TOOLS/bin/spine-uninstall" --apply --yes >/dev/null 2>&1; then
  chmod 700 "$APPLY_HOME/dev"
  fail "uninstall succeeded when the tools archive could not be created"
fi
chmod 700 "$APPLY_HOME/dev"
[ -d "$TOOLS" ] || fail "failed uninstall moved tools"
[ -f "$VAULT/.git/hooks/pre-commit" ] || fail "failed uninstall did not restore hook"
HOME="$APPLY_HOME" "$TOOLS/bin/spine-uninstall" --apply --yes >/dev/null
[ ! -e "$TOOLS" ] || fail "uninstall apply did not move tools"
[ -d "$VAULT" ] || fail "uninstall removed the vault"
[ -d "$MIRROR" ] || fail "uninstall removed the mirror"
[ ! -e "$VAULT/.git/hooks/pre-commit" ] || fail "uninstall left the canonical hook active"
archives=("$APPLY_HOME/dev/memory-spine.uninstalled-"*)
[ "${#archives[@]}" -eq 1 ] && [ -d "${archives[0]}" ] || fail "uninstall archive missing"

# The printed rollback contract is executable: restore the archived copy,
# re-apply from the reviewed source, and verify data/config plus the hook.
mv "${archives[0]}" "$TOOLS"
HOME="$APPLY_HOME" "$REPO/install.sh" --apply --yes >/dev/null
cmp -s "$TMP/rollback-projects.expected" "$TOOLS/config/projects.txt" || fail "rollback lost projects config"
cmp -s "$TMP/rollback-agents.expected" "$TOOLS/config/agents.txt" || fail "rollback lost agents config"
[ -f "$VAULT/.git/hooks/pre-commit" ] || fail "rollback did not restore canonical hook"
HOME="$APPLY_HOME" "$TOOLS/bin/spine-selftest" >/dev/null || fail "rollback install failed selftest"

# Linux defaults use XDG data directories rather than macOS Library paths.
FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
printf '#!/bin/sh\necho Linux\n' > "$FAKEBIN/uname"
chmod +x "$FAKEBIN/uname"
LINUX_HOME="$TMP/linux-home"
LINUX_DATA="$TMP/linux-data"
mkdir -p "$LINUX_HOME"
LINUX_OUT=$(HOME="$LINUX_HOME" XDG_DATA_HOME="$LINUX_DATA" PATH="$FAKEBIN:$PATH" "$REPO/install.sh")
echo "$LINUX_OUT" | grep -Fq "$LINUX_DATA/AgentMemory/Remotes" || fail "Linux mirror path is not XDG-aware"
echo "$LINUX_OUT" | grep -Fq "$LINUX_DATA/AgentMemory/logs" || fail "Linux log path is not XDG-aware"
[ ! -e "$LINUX_HOME/AgentMemory" ] || fail "Linux plan wrote files"

# Explicit apply refuses dangerous install roots before creating anything.
DANGER_HOME="$TMP/danger-home"
mkdir -p "$DANGER_HOME"
if HOME="$DANGER_HOME" "$REPO/install.sh" --apply --yes --tools-dir / >/dev/null 2>&1; then
  fail "installer accepted / as tools dir"
fi
[ ! -e "$DANGER_HOME/AgentMemory" ] || fail "dangerous-path refusal happened after writes"

# An explicit missing scanner is authoritative and fails before any write.
MISSING_HOME="$TMP/missing-scanner-home"
mkdir -p "$MISSING_HOME"
if HOME="$MISSING_HOME" SPINE_GITLEAKS="$TMP/does-not-exist" \
  "$REPO/install.sh" --apply --yes >/dev/null 2>&1; then
  fail "installer ignored an explicit missing gitleaks path"
fi
[ ! -e "$MISSING_HOME/AgentMemory" ] || fail "missing-scanner refusal happened after writes"

# Invalid dictionaries are rejected before creating either logical root.
INVALID_HOME="$TMP/invalid-home"
mkdir -p "$INVALID_HOME"
if HOME="$INVALID_HOME" "$REPO/install.sh" --apply --yes \
  --projects 'valid,bad scope' --agents user >/dev/null 2>&1; then
  fail "installer accepted an invalid project slug"
fi
[ ! -e "$INVALID_HOME/AgentMemory" ] || fail "invalid slug left a partial vault"
[ ! -e "$INVALID_HOME/dev/memory-spine" ] || fail "invalid slug left partial tools"

# Destination symlinks are refused rather than followed.
LINK_HOME="$TMP/link-home"
LINK_TARGET="$TMP/link-target"
mkdir -p "$LINK_HOME" "$LINK_TARGET"
ln -s "$LINK_TARGET" "$LINK_HOME/AgentMemory"
if HOME="$LINK_HOME" "$REPO/install.sh" --apply --yes \
  --projects alpha --agents agent-one,user >/dev/null 2>&1; then
  fail "installer followed a symlinked memory root"
fi
[ -z "$(find "$LINK_TARGET" -mindepth 1 -maxdepth 1 -print -quit)" ] || fail "symlink refusal wrote through to target"

# Divergent owner dictionaries are a conflict, never a choose-and-overwrite.
CONFLICT_HOME="$TMP/conflict-home"
mkdir -p "$CONFLICT_HOME/dev/memory-spine/config" "$CONFLICT_HOME/AgentMemory/config"
printf 'alpha\ninbox\n' > "$CONFLICT_HOME/dev/memory-spine/config/projects.txt"
printf 'beta\ninbox\n' > "$CONFLICT_HOME/AgentMemory/config/projects.txt"
printf 'user\n' > "$CONFLICT_HOME/dev/memory-spine/config/agents.txt"
printf 'user\n' > "$CONFLICT_HOME/AgentMemory/config/agents.txt"
if HOME="$CONFLICT_HOME" "$REPO/install.sh" --apply --yes >/dev/null 2>&1; then
  fail "installer silently chose between divergent dictionaries"
fi
grep -Fqx beta "$CONFLICT_HOME/AgentMemory/config/projects.txt" || fail "conflict refusal overwrote vault dictionary"
[ ! -e "$CONFLICT_HOME/dev/memory-spine/bin" ] || fail "dictionary conflict copied payload before refusal"

# A pre-existing unrelated origin must never receive installer commits.
ORIGIN_HOME="$TMP/origin-home"
OTHER_BARE="$TMP/unrelated.git"
mkdir -p "$ORIGIN_HOME/AgentMemory/config" "$ORIGIN_HOME/dev/memory-spine/config"
printf 'alpha\ninbox\n' | tee "$ORIGIN_HOME/AgentMemory/config/projects.txt" > "$ORIGIN_HOME/dev/memory-spine/config/projects.txt"
printf 'user\n' | tee "$ORIGIN_HOME/AgentMemory/config/agents.txt" > "$ORIGIN_HOME/dev/memory-spine/config/agents.txt"
git init -q -b main "$ORIGIN_HOME/AgentMemory"
git init -q --bare "$OTHER_BARE"
git -C "$ORIGIN_HOME/AgentMemory" remote add origin "$OTHER_BARE"
if HOME="$ORIGIN_HOME" "$REPO/install.sh" --apply --yes >/dev/null 2>&1; then
  fail "installer accepted an unrelated existing origin"
fi
[ ! -e "$ORIGIN_HOME/dev/memory-spine/bin" ] || fail "origin conflict copied payload before refusal"
[ -z "$(git -C "$OTHER_BARE" for-each-ref refs/heads/)" ] || fail "installer pushed to unrelated origin"

# --no-mirror is truthful: no remote and no local-mirror success claim.
NO_MIRROR_HOME="$TMP/no-mirror-home"
mkdir -p "$NO_MIRROR_HOME"
NO_MIRROR_OUT=$(HOME="$NO_MIRROR_HOME" "$REPO/install.sh" --apply --yes --no-mirror \
  --projects alpha --agents agent-one,user)
[ -z "$(git -C "$NO_MIRROR_HOME/AgentMemory" remote)" ] || fail "--no-mirror configured a remote"
echo "$NO_MIRROR_OUT" | grep -Fq "Mirror:      disabled" || fail "--no-mirror plan was not truthful"
if echo "$NO_MIRROR_OUT" | grep -Fq "only remote is a bare mirror"; then
  fail "--no-mirror printed a false mirror success claim"
fi
HOME="$NO_MIRROR_HOME" "$NO_MIRROR_HOME/dev/memory-spine/bin/spine-preflight" >/dev/null \
  || fail "--no-mirror install failed preflight"
HOME="$NO_MIRROR_HOME" "$NO_MIRROR_HOME/dev/memory-spine/bin/spine-sync" \
  || fail "--no-mirror local-only sync failed"

# --no-git-init is an explicit non-sync mode: preflight succeeds and sync is a
# truthful no-op instead of entering a broken Git chain.
NO_GIT_HOME="$TMP/no-git-home"
mkdir -p "$NO_GIT_HOME"
HOME="$NO_GIT_HOME" "$REPO/install.sh" --apply --yes --no-git-init --no-mirror \
  --projects alpha --agents agent-one,user >/dev/null
[ ! -e "$NO_GIT_HOME/AgentMemory/.git" ] || fail "--no-git-init created a Git repository"
HOME="$NO_GIT_HOME" "$NO_GIT_HOME/dev/memory-spine/bin/spine-preflight" >/dev/null \
  || fail "--no-git-init install failed preflight"
HOME="$NO_GIT_HOME" "$NO_GIT_HOME/dev/memory-spine/bin/spine-sync" \
  || fail "--no-git-init sync was not a clean no-op"

# The agent helper isolates configuration profiles, not OS filesystem access.
# Verify both the generated disclosure and the actual boundary in a synthetic HOME.
SANDBOX_HOME="$TMP/sandbox-home"
SANDBOX_VAULT="$SANDBOX_HOME/AgentMemory"
mkdir -p "$SANDBOX_VAULT"
printf 'synthetic readable sentinel\n' > "$SANDBOX_VAULT/direct-read-sentinel"
HOME="$SANDBOX_HOME" SPINE_ROOT="$SANDBOX_VAULT" \
  "$TOOLS/bin/spine-agent-sandbox" contract-agent >/dev/null
SANDBOX_BOX="$SANDBOX_HOME/agent-sandboxes/contract-agent"
grep -Fq 'Spine command access is denied' "$SANDBOX_BOX/LAUNCH.md" \
  || fail "agent helper did not disclose the Spine-mediated gate boundary"
grep -Fq 'does not block direct filesystem reads or writes' "$SANDBOX_BOX/LAUNCH.md" \
  || fail "agent helper did not disclose direct filesystem access"
if grep -Fq 'model = ' "$SANDBOX_BOX/codex-home/config.toml"; then
  fail "agent helper pinned an environment-specific model"
fi
CODEX_HOME="$SANDBOX_BOX/codex-home" CLAUDE_CONFIG_DIR="$SANDBOX_BOX/claude-home" \
  python3 - "$SANDBOX_VAULT/direct-read-sentinel" <<'PY'
from pathlib import Path
import sys
if Path(sys.argv[1]).read_text(encoding="utf-8") != "synthetic readable sentinel\n":
    raise SystemExit("FAIL: direct-read boundary probe did not reach its sentinel")
PY

echo "installer-test: PASS"
