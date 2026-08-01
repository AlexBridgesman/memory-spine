#!/usr/bin/env python3
"""Shared packet-limit parsing and delivery-budget policy."""
from __future__ import annotations

from collections.abc import Callable, Collection
from pathlib import Path

DEFAULT_PACKET_BYTES = 14_000
MIN_PACKET_BYTES = 4_000
MIN_DYNAMIC_RESERVE_BYTES = 1_600
MAX_DYNAMIC_RESERVE_BYTES = 2_000


def load_limits(
    config_dir: str,
    projects: Collection[str],
    warn: Callable[[str], None],
) -> dict[str, int]:
    """Load optional per-scope delivery caps with value-blind diagnostics."""
    path = Path(config_dir) / "packet-limits.conf"
    try:
        handle = path.open("rb")
    except FileNotFoundError:
        return {}
    except OSError:
        warn("packet-limits.conf: cannot read; using defaults")
        return {}

    known = set(projects)
    limits: dict[str, int] = {}
    with handle:
        for line_no, raw in enumerate(handle, 1):
            try:
                text = raw.decode("utf-8")
            except UnicodeDecodeError:
                warn(f"packet-limits.conf:{line_no}: invalid UTF-8; ignored")
                continue
            entry = text.strip()
            if not entry or entry.startswith("#"):
                continue
            if "\t" in entry:
                scope, value = entry.split("\t", 1)
            elif "=" in entry:
                scope, value = entry.split("=", 1)
            else:
                warn(f"packet-limits.conf:{line_no}: malformed entry; ignored")
                continue
            scope = scope.strip()
            if scope not in known:
                warn(f"packet-limits.conf:{line_no}: unknown scope; ignored")
                continue
            try:
                byte_limit = int(value.strip())
            except ValueError:
                warn(f"packet-limits.conf:{line_no}: byte limit is not an integer; ignored")
                continue
            if scope in limits:
                warn(f"packet-limits.conf:{line_no}: duplicate scope; last value wins")
            limits[scope] = max(MIN_PACKET_BYTES, byte_limit)
    return limits


def delivery_limit(scope: str, limits: dict[str, int]) -> int:
    return limits.get(scope, DEFAULT_PACKET_BYTES)


def base_packet_budget(limit: int) -> int:
    """Reserve bounded room for dynamic delta/recent sections at delivery time."""
    reserve = min(MAX_DYNAMIC_RESERVE_BYTES, max(MIN_DYNAMIC_RESERVE_BYTES, limit // 4))
    return limit - reserve
