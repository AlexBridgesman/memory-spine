#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
MEMORY_ROOT="${SPINE_ROOT:-$HOME/AgentMemory}"
TOOLS_DIR="${SPINE_TOOLS_DIR:-$HOME/dev/memory-spine}"
if [ "${SPINE_PROJECTS+x}" = x ]; then
  PROJECTS="$SPINE_PROJECTS"
  PROJECTS_EXPLICIT=1
else
  PROJECTS="personal,work,ai-infra"
  PROJECTS_EXPLICIT=0
fi
if [ "${SPINE_AGENTS+x}" = x ]; then
  AGENTS="$SPINE_AGENTS"
  AGENTS_EXPLICIT=1
else
  AGENTS="claude-code,codex,hermes,cursor,aider,windsurf,opencode,user,other-agent"
  AGENTS_EXPLICIT=0
fi
APPLY=0
ASSUME_YES=0
GIT_INIT=1
MIRROR=1
case "$(uname -s 2>/dev/null || echo unknown)" in
  Darwin)
    DEFAULT_STATE_ROOT="$HOME/Library/AgentMemory"
    DEFAULT_LOG_ROOT="$HOME/Library/Logs/AgentMemory"
    ;;
  *)
    DEFAULT_STATE_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/AgentMemory"
    DEFAULT_LOG_ROOT="$DEFAULT_STATE_ROOT/logs"
    ;;
esac
REMOTE_ROOT="${SPINE_REMOTE_ROOT:-$DEFAULT_STATE_ROOT/Remotes}"
LOG_ROOT="${SPINE_LOG_DIR:-$DEFAULT_LOG_ROOT}"

usage() {
  cat <<'USAGE'
Usage: ./install.sh [--apply] [--yes] [--memory-root PATH] [--tools-dir PATH]
                    [--projects a,b,c] [--agents a,b,c]
                    [--no-git-init] [--no-mirror]

Installs a local Agent Memory Spine vault and CLI tools.
Everything stays on this machine: the only remote created is a local bare
mirror (--no-mirror to skip it). Nothing is pushed anywhere else.

The default is a read-only plan. Pass --apply to make the listed changes.
On upgrade, owner-maintained project and agent dictionaries are preserved;
explicit --projects/--agents values are added without removing old entries.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --memory-root) MEMORY_ROOT="$2"; shift 2 ;;
    --tools-dir) TOOLS_DIR="$2"; shift 2 ;;
    --projects) PROJECTS="$2"; PROJECTS_EXPLICIT=1; shift 2 ;;
    --agents) AGENTS="$2"; AGENTS_EXPLICIT=1; shift 2 ;;
    --no-git-init) GIT_INIT=0; shift ;;
    --no-mirror) MIRROR=0; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "git is required" >&2; exit 1; }
GITLEAKS="${SPINE_GITLEAKS:-$(command -v gitleaks 2>/dev/null || true)}"

MEMORY_ROOT="$(python3 -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$MEMORY_ROOT")"
TOOLS_DIR="$(python3 -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$TOOLS_DIR")"
REMOTE_ROOT="$(python3 -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$REMOTE_ROOT")"
LOG_ROOT="$(python3 -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$LOG_ROOT")"

case "$MEMORY_ROOT" in
  /|"$HOME") echo "Refusing unsafe memory root: $MEMORY_ROOT" >&2; exit 2 ;;
esac
case "$TOOLS_DIR" in
  /|"$HOME") echo "Refusing unsafe tools directory: $TOOLS_DIR" >&2; exit 2 ;;
esac
if [ "$MEMORY_ROOT" = "$TOOLS_DIR" ]; then
  echo "Memory root and tools directory must be different" >&2
  exit 2
fi

# Validate every user-controlled boundary before the first mkdir/copy. This
# preflight reads existing config/git metadata but writes nothing.
python3 - "$MEMORY_ROOT" "$TOOLS_DIR" "$REMOTE_ROOT" "$PROJECTS" "$AGENTS" \
  "$PROJECTS_EXPLICIT" "$AGENTS_EXPLICIT" "$MIRROR" <<'PY'
from pathlib import Path
from urllib.parse import unquote, urlparse
import re
import subprocess
import sys

root, tools, remote = (Path(arg) for arg in sys.argv[1:4])
requested_projects = [v.strip() for v in sys.argv[4].split(',') if v.strip()]
requested_agents = [v.strip() for v in sys.argv[5].split(',') if v.strip()]
projects_explicit, agents_explicit = sys.argv[6] == '1', sys.argv[7] == '1'
mirror_enabled = sys.argv[8] == '1'
slug = re.compile(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$')

def fail(message):
    raise SystemExit(f"Installer preflight failed: {message}")

for label, path in (("memory root", root), ("tools directory", tools), ("remote root", remote)):
    for candidate in (path, *path.parents):
        if candidate.exists() and candidate.is_symlink():
            # macOS exposes stable system aliases (/var -> /private/var, etc.).
            # Reject caller-controlled symlinks, not those platform aliases.
            aliases = {Path('/var'): Path('/private/var'),
                       Path('/tmp'): Path('/private/tmp'),
                       Path('/etc'): Path('/private/etc')}
            if candidate in aliases and candidate.resolve() == aliases[candidate]:
                continue
            fail(f"{label} traverses symlink: {candidate}")

resolved = {"memory root": root.resolve(), "tools directory": tools.resolve(),
            "remote root": remote.resolve()}
items = list(resolved.items())
for i, (left_name, left) in enumerate(items):
    for right_name, right in items[i + 1:]:
        if left == right or left in right.parents or right in left.parents:
            fail(f"{left_name} overlaps {right_name}")

def values_from(raw):
    return [line.strip() for line in raw.splitlines()
            if line.strip() and not line.lstrip().startswith('#')]

def effective_dictionary(name, requested, explicit, required):
    paths = (tools / 'config' / name, root / 'config' / name)
    existing = [path for path in paths if path.is_file()]
    if len(existing) == 2 and existing[0].read_bytes() != existing[1].read_bytes():
        fail(f"owner dictionaries differ: {existing[0]} != {existing[1]}")
    current = values_from(existing[0].read_text(encoding='utf-8')) if existing else []
    values = list(current or requested)
    if explicit and current:
        values.extend(v for v in requested if v not in values)
    values.extend(v for v in required if v not in values)
    if not values:
        fail(f"{name} would be empty")
    for value in values:
        if not slug.fullmatch(value):
            fail(f"invalid value in {name}: {value!r}")

effective_dictionary('projects.txt', requested_projects, projects_explicit, ('inbox',))
effective_dictionary('agents.txt', requested_agents, agents_explicit, ('user',))

if mirror_enabled and (root / '.git').is_dir():
    get = subprocess.run(['git', '-C', str(root), 'remote', 'get-url', 'origin'],
                         text=True, capture_output=True)
    if get.returncode == 0:
        origin = get.stdout.strip()
        if origin.startswith('file://'):
            parsed = urlparse(origin)
            origin_path = Path(unquote(parsed.path))
        elif origin.startswith(('/', './', '../', '~')):
            origin_path = Path(origin).expanduser()
            if not origin_path.is_absolute():
                origin_path = root / origin_path
        else:
            fail("existing origin is not a local filesystem path")
        expected = (remote / 'AgentMemory.git').resolve()
        if origin_path.resolve() != expected:
            fail(f"existing origin is unrelated to selected local mirror: {origin_path}")
PY

CONFIG_ACTION="fresh defaults"
if [ -f "$TOOLS_DIR/config/projects.txt" ] || [ -f "$MEMORY_ROOT/config/projects.txt" ]; then
  CONFIG_ACTION="preserve existing dictionaries"
  if [ "$PROJECTS_EXPLICIT" = 1 ] || [ "$AGENTS_EXPLICIT" = 1 ]; then
    CONFIG_ACTION="preserve existing dictionaries and add explicit entries"
  fi
fi

echo "Memory Spine install plan"
echo "  Memory root: $MEMORY_ROOT"
echo "  Tools dir:   $TOOLS_DIR"
if [ "$MIRROR" = 1 ]; then
  echo "  Mirror:      $REMOTE_ROOT/AgentMemory.git"
else
  echo "  Mirror:      disabled"
fi
echo "  Logs:        $LOG_ROOT"
echo "  Config:      $CONFIG_ACTION"
echo "  Projects:    $PROJECTS"
echo "  Agents:      $AGENTS"

if [ "$APPLY" != "1" ]; then
  echo
  echo "DRY RUN — no files were changed. Re-run with --apply to install."
  exit 0
fi

if [ -z "$GITLEAKS" ] || [ ! -x "$GITLEAKS" ]; then
  echo "gitleaks is required because commits fail closed without it: ${GITLEAKS:-not found}" >&2
  exit 1
fi
export SPINE_GITLEAKS="$GITLEAKS"

if [ "$ASSUME_YES" != "1" ]; then
  printf "Continue? [y/N] "
  read -r reply
  case "$reply" in y|Y|yes|YES) ;; *) echo "Cancelled."; exit 1 ;; esac
fi

mkdir -p "$TOOLS_DIR/bin" "$TOOLS_DIR/lib" "$TOOLS_DIR/hooks" "$TOOLS_DIR/docs" "$TOOLS_DIR/config" \
         "$MEMORY_ROOT/config" "$MEMORY_ROOT/entities" "$MEMORY_ROOT/_index"
for f in "$SCRIPT_DIR/bin"/*; do
  [ -f "$f" ] && cp "$f" "$TOOLS_DIR/bin/"
done
for f in "$SCRIPT_DIR/lib"/*; do
  [ -f "$f" ] && cp "$f" "$TOOLS_DIR/lib/"
done
# config/ lives in the tools dir — that is where every tool looks first
# (see _config_dir() in spine-gen and friends). Existing files are never
# overwritten: the allowlist and notify settings are the owner's, not ours.
for f in "$SCRIPT_DIR/config"/*; do
  [ -f "$f" ] || continue
  base="$(basename "$f")"
  case "$base" in projects.txt|agents.txt) continue ;; esac
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
chmod +x "$TOOLS_DIR/lib/"*.sh 2>/dev/null || true

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

python3 - "$MEMORY_ROOT" "$PROJECTS" "$AGENTS" "$TOOLS_DIR" \
  "$PROJECTS_EXPLICIT" "$AGENTS_EXPLICIT" <<'PY'
from pathlib import Path
import re
import sys
root = Path(sys.argv[1])
requested_projects = [p.strip() for p in sys.argv[2].split(',') if p.strip()]
requested_agents = [a.strip() for a in sys.argv[3].split(',') if a.strip()]
tools = Path(sys.argv[4])
projects_explicit = sys.argv[5] == '1'
agents_explicit = sys.argv[6] == '1'
slug = re.compile(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$')

def dictionary(name, requested, explicit, required=()):
    existing_path = next((p for p in (tools / 'config' / name,
                                      root / 'config' / name) if p.is_file()), None)
    raw = existing_path.read_text(encoding='utf-8') if existing_path else ''
    lines = raw.splitlines()
    values = [line.strip() for line in lines
              if line.strip() and not line.lstrip().startswith('#')]
    if not existing_path:
        values = list(requested)
        lines = list(values)
    elif explicit:
        for value in requested:
            if value not in values:
                lines.append(value)
                values.append(value)
    for value in required:
        if value not in values:
            lines.append(value)
            values.append(value)
    text = '\n'.join(lines) + '\n'
    return values, text

projects, projects_text = dictionary('projects.txt', requested_projects,
                                     projects_explicit, required=('inbox',))
agents, agents_text = dictionary('agents.txt', requested_agents, agents_explicit,
                                 required=('user',))

for label, values in [('project', projects), ('agent', agents)]:
    for value in values:
        if not slug.match(value):
            raise SystemExit(f"Invalid {label} slug: {value}")
# Dictionaries are written to BOTH config dirs: the tools dir is what every tool
# resolves first, the vault copy keeps the vault self-describing when shared.
for cfg in (tools / 'config', root / 'config'):
    cfg.mkdir(parents=True, exist_ok=True)
    (cfg / 'projects.txt').write_text(projects_text, encoding='utf-8')
    (cfg / 'agents.txt').write_text(agents_text, encoding='utf-8')
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
SRC_COMMIT="$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
SRC_TREE="$(git -C "$SCRIPT_DIR" rev-parse 'HEAD^{tree}' 2>/dev/null || echo unknown)"
SRC_VERSION="$(git -C "$SCRIPT_DIR" describe --tags --always 2>/dev/null || echo unknown)"
if [ -n "$(git -C "$SCRIPT_DIR" status --porcelain 2>/dev/null || true)" ]; then
  SRC_DIRTY=true
else
  SRC_DIRTY=false
fi
INSTALL_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FIRST_SCOPE="$(grep -v '^[[:space:]]*#' "$TOOLS_DIR/config/projects.txt" | grep -v '^inbox$' | grep . | head -1)"
[ -n "$FIRST_SCOPE" ] || { echo "No non-inbox project is available for the genesis record" >&2; exit 1; }
if [ ! -f "$MEMORY_ROOT/PROVENANCE.md" ]; then
  cat > "$MEMORY_ROOT/PROVENANCE.md" <<PROV
# Provenance

- installed: $INSTALL_DATE
- template_commit: $SRC_COMMIT
- template_tree: $SRC_TREE
- template_version: $SRC_VERSION
- source_dirty: $SRC_DIRTY
- upstream: https://github.com/AlexBridgesman/memory-spine
PROV
  if ! SPINE_NO_GATE=1 SPINE_ROOT="$MEMORY_ROOT" SPINE_TOOLS_DIR="$TOOLS_DIR" \
    "$TOOLS_DIR/bin/spine-new" --type fact --project "$FIRST_SCOPE" --agent user \
    --title "Memory Spine installed — genesis record" --confidence verified \
    --summary "This memory started on $INSTALL_DATE from template commit $SRC_COMMIT." \
    --body "Lineage of this vault: installed $INSTALL_DATE, template commit $SRC_COMMIT, tree $SRC_TREE, version $SRC_VERSION, dirty $SRC_DIRTY, upstream https://github.com/AlexBridgesman/memory-spine. Statistics of this memory count from this record. [[$FIRST_SCOPE]]" \
    >/dev/null 2>&1; then
    rm -f "$MEMORY_ROOT/PROVENANCE.md"
    echo "Failed to create the genesis record; provenance rolled back" >&2
    exit 1
  fi
fi

# Provenance and the genesis record are generated after the first scan, so scan
# the complete final Markdown set before any commit.
find "$MEMORY_ROOT" -name '*.md' -not -path '*/.git/*' -print0 | xargs -0 "$TOOLS_DIR/bin/spine-secrets-lint"


if [ "$GIT_INIT" = "1" ]; then
  FRESH_GIT=0
  if [ ! -d "$MEMORY_ROOT/.git" ]; then
    git -C "$MEMORY_ROOT" init -b main >/dev/null 2>&1 || git -C "$MEMORY_ROOT" init >/dev/null
    FRESH_GIT=1
  fi
  if [ -d "$MEMORY_ROOT/.git" ] && [ -f "$TOOLS_DIR/hooks/pre-commit" ]; then
    cp "$TOOLS_DIR/hooks/pre-commit" "$MEMORY_ROOT/.git/hooks/pre-commit"
    chmod +x "$MEMORY_ROOT/.git/hooks/pre-commit"
  fi
  if [ "$FRESH_GIT" = 1 ]; then
    git -C "$MEMORY_ROOT" add --all
    if ! git -C "$MEMORY_ROOT" diff --cached --quiet; then
      git -C "$MEMORY_ROOT" -c user.name="Memory Spine" -c user.email="memory-spine@example.local" \
        commit -m "Initialize AgentMemory" >/dev/null
    fi
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
    git -C "$MEMORY_ROOT" push -u origin "$BRANCH" >/dev/null
  fi
fi

cat <<EOF

Agent Memory Spine installed locally.

Memory root: $MEMORY_ROOT
Tools dir:   $TOOLS_DIR

Next commands:
  export SPINE_ROOT="$MEMORY_ROOT"
  $TOOLS_DIR/bin/spine-health
  $TOOLS_DIR/bin/spine-new --type fact --project $FIRST_SCOPE --title "Example fact" --agent user --body "Non-secret durable fact."
  $TOOLS_DIR/bin/spine-sync

Everything is local.
EOF
if [ "$MIRROR" = 1 ]; then
  echo "The only remote is a bare mirror on this machine ($REMOTE_ROOT/AgentMemory.git)."
else
  echo "The installer did not configure or push a mirror (--no-mirror)."
fi
echo "Nothing was pushed to a network or cloud remote."
