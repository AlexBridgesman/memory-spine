#!/usr/bin/env bash
# Shared platform-aware paths for Memory Spine shell tools.

spine_default_state_root() {
  case "$(uname -s 2>/dev/null || echo unknown)" in
    Darwin) printf '%s\n' "$HOME/Library/AgentMemory" ;;
    *) printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/AgentMemory" ;;
  esac
}

spine_default_log_root() {
  case "$(uname -s 2>/dev/null || echo unknown)" in
    Darwin) printf '%s\n' "$HOME/Library/Logs/AgentMemory" ;;
    *) printf '%s\n' "$(spine_default_state_root)/logs" ;;
  esac
}

spine_default_remote_root() {
  printf '%s/Remotes\n' "$(spine_default_state_root)"
}

spine_default_ledger() {
  case "$(uname -s 2>/dev/null || echo unknown)" in
    Darwin) printf '%s\n' "$HOME/Library/Application Support/AgentMemory/ledger.tsv" ;;
    *) printf '%s/ledger.tsv\n' "$(spine_default_state_root)" ;;
  esac
}

spine_resolve_python() {
  local configured="${SPINE_PYTHON:-}" candidate
  if [ -n "$configured" ]; then
    case "$configured" in
      */*) [ -x "$configured" ] && { printf '%s\n' "$configured"; return 0; } ;;
      *) candidate="$(command -v "$configured" 2>/dev/null || true)"
         [ -n "$candidate" ] && { printf '%s\n' "$candidate"; return 0; } ;;
    esac
    return 1
  fi
  candidate="$(command -v python3 2>/dev/null || true)"
  [ -n "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

spine_stat_value() {
  local bsd_fmt="$1" gnu_fmt="$2" path="$3" value
  if value=$(stat -f "$bsd_fmt" "$path" 2>/dev/null); then
    case "$value" in ''|*[!0-9]*) ;;
      *) printf '%s\n' "$value"; return 0 ;;
    esac
  fi
  value=$(stat -c "$gnu_fmt" "$path" 2>/dev/null) || return 1
  case "$value" in ''|*[!0-9]*) return 1 ;;
    *) printf '%s\n' "$value" ;;
  esac
}

spine_file_mtime() { spine_stat_value %m %Y "$1"; }
spine_file_size() { spine_stat_value %z %s "$1"; }
