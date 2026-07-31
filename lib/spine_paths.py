"""Platform-aware state paths shared by Memory Spine Python tools."""
from __future__ import annotations

import os
import platform
from pathlib import Path


def _platform(name: str | None = None) -> str:
    return name or platform.system()


def default_state_root(platform_name: str | None = None) -> Path:
    home = Path.home()
    if _platform(platform_name) == "Darwin":
        return home / "Library" / "AgentMemory"
    return Path(os.environ.get("XDG_DATA_HOME", home / ".local" / "share")) / "AgentMemory"


def default_log_root(platform_name: str | None = None) -> Path:
    if _platform(platform_name) == "Darwin":
        return Path.home() / "Library" / "Logs" / "AgentMemory"
    return default_state_root(platform_name) / "logs"


def default_remote_root(platform_name: str | None = None) -> Path:
    return default_state_root(platform_name) / "Remotes"


def default_ledger(platform_name: str | None = None) -> Path:
    if _platform(platform_name) == "Darwin":
        return Path.home() / "Library" / "Application Support" / "AgentMemory" / "ledger.tsv"
    return default_state_root(platform_name) / "ledger.tsv"
