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
