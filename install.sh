#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
MEMORY_ROOT="${SPINE_ROOT:-$HOME/AgentMemory}"
TOOLS_DIR="${SPINE_TOOLS_DIR:-$HOME/dev/memory-spine}"
PROJECTS="${SPINE_PROJECTS:-personal,work,ai-infra}"
AGENTS="${SPINE_AGENTS:-claude-code,codex,hermes,cursor,aider,windsurf,opencode,user,other-agent}"
ASSUME_YES=0
GIT_INIT=1
MIRROR=1
REMOTE_ROOT="${SPINE_REMOTE_ROOT:-$HOME/Library/AgentMemory/Remotes}"

usage() {
  cat <<'USAGE'
Usage: ./install.sh [--yes] [--memory-root PATH] [--tools-dir PATH] [--projects a,b,c] [--agents a,b,c] [--no-git-init] [--no-mirror]

Installs a local Agent Memory Spine vault and CLI tools.
Everything stays on this machine: the only remote created is a local bare
mirror (--no-mirror to skip it). Nothing is pushed anywhere else.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --yes|-y) ASSUME_YES=1; shift ;;
    --memory-root) MEMORY_ROOT="$2"; shift 2 ;;
    --tools-dir) TOOLS_DIR="$2"; shift 2 ;;
    --projects) PROJECTS="$2"; shift 2 ;;
    --agents) AGENTS="$2"; shift 2 ;;
    --no-git-init) GIT_INIT=0; shift ;;
    --no-mirror) MIRROR=0; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

MEMORY_ROOT="$(python3 -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$MEMORY_ROOT")"
TOOLS_DIR="$(python3 -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$TOOLS_DIR")"

if [ "$ASSUME_YES" != "1" ]; then
  echo "This will install:"
  echo "  Memory root: $MEMORY_ROOT"
  echo "  Tools dir:   $TOOLS_DIR"
  echo "  Projects:    $PROJECTS"
  echo "  Agents:      $AGENTS"
  printf "Continue? [y/N] "
  read -r reply
  case "$reply" in y|Y|yes|YES) ;; *) echo "Cancelled."; exit 1 ;; esac
fi

command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "git is required" >&2; exit 1; }

mkdir -p "$TOOLS_DIR/bin" "$TOOLS_DIR/lib" "$TOOLS_DIR/hooks" "$TOOLS_DIR/docs" "$TOOLS_DIR/config" \
         "$MEMORY_ROOT/config" "$MEMORY_ROOT/entities" "$MEMORY_ROOT/_index"
for f in "$SCRIPT_DIR/bin"/*; do
  [ -f "$f" ] && cp "$f" "$TOOLS_DIR/bin/"
done
for f in "$SCRIPT_DIR/lib"/*.py; do
  [ -f "$f" ] && cp "$f" "$TOOLS_DIR/lib/"
done
# config/ lives in the tools dir — that is where every tool looks first
# (see _config_dir() in spine-gen and friends). Existing files are never
# overwritten: the allowlist and notify settings are the owner's, not ours.
for f in "$SCRIPT_DIR/config"/*; do
  [ -f "$f" ] || continue
  base="$(basename "$f")"
  [ -e "$TOOLS_DIR/config/$base" ] || cp "$f" "$TOOLS_DIR/config/$base"
done
for f in "$SCRIPT_DIR/hooks"/*; do
  [ -f "$f" ] && cp "$f" "$TOOLS_DIR/hooks/"
done
for f in "$SCRIPT_DIR/docs"/*.md; do
  [ -f "$f" ] && cp "$f" "$TOOLS_DIR/docs/"
done
chmod +x "$TOOLS_DIR/bin/"* 2>/dev/null || true
chmod +x "$TOOLS_DIR/hooks/"* 2>/dev/null || true

if [ ! -f "$MEMORY_ROOT/README.md" ]; then
  cp "$SCRIPT_DIR/templates/AgentMemory/README.md" "$MEMORY_ROOT/README.md"
fi
if [ ! -f "$MEMORY_ROOT/RUNBOOK.md" ]; then
  cp "$SCRIPT_DIR/templates/AgentMemory/RUNBOOK.md" "$MEMORY_ROOT/RUNBOOK.md"
fi
if [ ! -f "$MEMORY_ROOT/.gitignore" ]; then
  cp "$SCRIPT_DIR/templates/AgentMemory/.gitignore" "$MEMORY_ROOT/.gitignore"
fi
if [ ! -f "$MEMORY_ROOT/.gitleaks.toml" ]; then
  cp "$SCRIPT_DIR/templates/AgentMemory/.gitleaks.toml" "$MEMORY_ROOT/.gitleaks.toml"
fi

python3 - "$MEMORY_ROOT" "$PROJECTS" "$AGENTS" "$TOOLS_DIR" <<'PY'
from pathlib import Path
import re
import sys
root = Path(sys.argv[1])
projects = [p.strip() for p in sys.argv[2].split(',') if p.strip()]
agents = [a.strip() for a in sys.argv[3].split(',') if a.strip()]
tools = Path(sys.argv[4])
slug = re.compile(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$')
for label, values in [('project', projects), ('agent', agents)]:
    for value in values:
        if not slug.match(value):
            raise SystemExit(f"Invalid {label} slug: {value}")
# 'inbox' always exists: topics that fit no scope must have a home, otherwise
# agents are forced to file them under a wrong scope (or stay silent).
if 'inbox' not in projects:
    projects.append('inbox')
# Dictionaries are written to BOTH config dirs: the tools dir is what every tool
# resolves first, the vault copy keeps the vault self-describing when shared.
for cfg in (tools / 'config', root / 'config'):
    cfg.mkdir(parents=True, exist_ok=True)
    (cfg / 'projects.txt').write_text('\n'.join(projects) + '\n', encoding='utf-8')
    (cfg / 'agents.txt').write_text('\n'.join(agents) + '\n', encoding='utf-8')
for project in projects:
    for type_dir in ['decisions', 'facts', 'threads', 'artifacts']:
        (root / project / type_dir).mkdir(parents=True, exist_ok=True)
    hub = root / project / f'{project}.md'
    if not hub.exists():
        hub.write_text(f'# {project}\n\nProject hub for [[{project}]].\n', encoding='utf-8')
    index = root / project / 'INDEX.md'
    if not index.exists():
        index.write_text(f'# INDEX — {project}\n\nGenerated by spine-gen.\n', encoding='utf-8')
PY

export SPINE_ROOT="$MEMORY_ROOT"
"$TOOLS_DIR/bin/spine-gen" >/dev/null
find "$MEMORY_ROOT" -name '*.md' -not -path '*/.git/*' -print0 | xargs -0 "$TOOLS_DIR/bin/spine-secrets-lint"

# GENESIS RECORD — the vault's own birth certificate. Installs and forks keep
# their lineage forever: the date the memory started, which template commit it
# came from and where that clone originated. Written as a normal record (so it
# rides journal/history like everything else) + a machine-readable
# PROVENANCE.md at the vault root. No network, no phone-home: provenance
# lives with the OWNER of the data, not with us.
SRC_COMMIT="$(git -C "$SCRIPT_DIR" describe --tags --always 2>/dev/null || echo unknown)"
SRC_URL="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || echo unknown)"
INSTALL_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FIRST_SCOPE="$(echo "$PROJECTS" | cut -d, -f1)"
if [ ! -f "$MEMORY_ROOT/PROVENANCE.md" ]; then
  cat > "$MEMORY_ROOT/PROVENANCE.md" <<PROV
# Provenance

- installed: $INSTALL_DATE
- template_commit: $SRC_COMMIT
- template_source: $SRC_URL
- upstream: https://github.com/AlexBridgesman/memory-spine
PROV
  SPINE_NO_GATE=1 SPINE_ROOT="$MEMORY_ROOT" SPINE_TOOLS_DIR="$TOOLS_DIR" \
    "$TOOLS_DIR/bin/spine-new" --type fact --project "$FIRST_SCOPE" --agent user \
    --title "Memory Spine installed — genesis record" --confidence verified \
    --summary "This memory started on $INSTALL_DATE from template commit $SRC_COMMIT ($SRC_URL)." \
    --body "Lineage of this vault: installed $INSTALL_DATE, template commit $SRC_COMMIT, cloned from $SRC_URL, upstream https://github.com/AlexBridgesman/memory-spine. Statistics of this memory count from this record. [[$FIRST_SCOPE]]" \
    >/dev/null 2>&1 || true
fi


if [ "$GIT_INIT" = "1" ]; then
  if [ ! -d "$MEMORY_ROOT/.git" ]; then
    git -C "$MEMORY_ROOT" init -b main >/dev/null 2>&1 || git -C "$MEMORY_ROOT" init >/dev/null
  fi
  if [ -d "$MEMORY_ROOT/.git" ] && [ -f "$TOOLS_DIR/hooks/pre-commit" ]; then
    cp "$TOOLS_DIR/hooks/pre-commit" "$MEMORY_ROOT/.git/hooks/pre-commit"
    chmod +x "$MEMORY_ROOT/.git/hooks/pre-commit"
  fi
  git -C "$MEMORY_ROOT" add --all
  if ! git -C "$MEMORY_ROOT" diff --cached --quiet; then
    git -C "$MEMORY_ROOT" -c user.name="Memory Spine" -c user.email="memory-spine@example.local" commit -m "Initialize AgentMemory" >/dev/null || true
  fi

  # Local bare mirror. sync, backup and the self-test all expect it: it is the
  # second copy of the vault on this machine and the push target of the sync
  # daemon. It never leaves the machine.
  # The branch matters: a bare created without -b main keeps HEAD on 'master'
  # while the vault is on 'main', and every mirror comparison then reports a
  # phantom mismatch. Old git without -b gets an explicit symbolic-ref.
  if [ "$MIRROR" = "1" ]; then
    BARE="$REMOTE_ROOT/AgentMemory.git"
    BRANCH="$(git -C "$MEMORY_ROOT" branch --show-current 2>/dev/null || echo main)"
    BRANCH="${BRANCH:-main}"
    if [ ! -d "$BARE" ]; then
      mkdir -p "$REMOTE_ROOT"
      git init --bare -b "$BRANCH" "$BARE" >/dev/null 2>&1 || {
        git init --bare "$BARE" >/dev/null
        git -C "$BARE" symbolic-ref HEAD "refs/heads/$BRANCH"
      }
    fi
    if ! git -C "$MEMORY_ROOT" remote get-url origin >/dev/null 2>&1; then
      git -C "$MEMORY_ROOT" remote add origin "$BARE"
    fi
    git -C "$MEMORY_ROOT" push -u origin "$BRANCH" >/dev/null 2>&1 || true
  fi
fi

cat <<EOF

Agent Memory Spine installed locally.

Memory root: $MEMORY_ROOT
Tools dir:   $TOOLS_DIR

Next commands:
  export SPINE_ROOT="$MEMORY_ROOT"
  $TOOLS_DIR/bin/spine-health
  $TOOLS_DIR/bin/spine-new --type fact --project personal --title "Example fact" --agent user --body "Non-secret durable fact."
  $TOOLS_DIR/bin/spine-sync

Everything is local. The only remote is a bare mirror on this machine
($REMOTE_ROOT/AgentMemory.git); nothing was pushed anywhere else.
EOF
