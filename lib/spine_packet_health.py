#!/usr/bin/env python3
"""Classify packet coverage statistics for spine-health."""
from __future__ import annotations

import re
import sys
from typing import Callable, Iterable, Optional
from pathlib import Path

MIN_ELIGIBLE_RECORDS = 20
MIN_COVERAGE_PERCENT = 35
MIN_SHIPPED_RECORDS = 55
SCOPE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")


def classify(
    rows: Iterable[str],
    warn: Callable[[str], None],
    expected_scopes: Optional[Iterable[str]] = None,
) -> list[str]:
    """Return starved-scope labels; malformed rows are skipped with safe warnings."""
    starved: list[str] = []
    expected = set(expected_scopes) if expected_scopes is not None else None
    seen: set[str] = set()
    row_count = 0
    for line_no, row in enumerate(rows, 1):
        row_count += 1
        if "\ufffd" in row:
            warn(f"line {line_no}: invalid UTF-8; ignored")
            continue
        columns = row.rstrip("\r\n").split("\t")
        if len(columns) != 4:
            warn(f"line {line_no}: expected four columns; ignored")
            continue
        project, passed_text, shipped_text, facts_text = columns
        if not SCOPE_RE.fullmatch(project):
            warn(f"line {line_no}: invalid scope; ignored")
            continue
        if project in seen:
            warn(f"line {line_no}: duplicate scope; ignored")
            continue
        if expected is not None and project not in expected:
            warn(f"line {line_no}: unexpected scope; ignored")
            continue
        seen.add(project)
        try:
            passed = int(passed_text)
            shipped = int(shipped_text)
        except ValueError:
            warn(f"line {line_no}: non-integer count; ignored")
            continue
        if passed < 0 or shipped < 0 or shipped > passed:
            warn(f"line {line_no}: inconsistent counts; ignored")
            continue
        if facts_text not in ("0", "1"):
            warn(f"line {line_no}: invalid facts flag; ignored")
            continue
        if passed < MIN_ELIGIBLE_RECORDS:
            continue
        coverage = 100 * shipped // max(1, passed)
        has_facts = facts_text == "1"
        if ((coverage < MIN_COVERAGE_PERCENT and shipped < MIN_SHIPPED_RECORDS)
                or not has_facts):
            starved.append(f"{project} {coverage}%{'' if has_facts else ' NO FACTS'}")
    if row_count == 0:
        warn("empty packet statistics")
    if expected is not None:
        for _ in sorted(expected - seen):
            warn("missing configured scope row")
    return starved


def _decode_rows(data: bytes) -> list[str]:
    rows: list[str] = []
    for raw in data.splitlines():
        try:
            rows.append(raw.decode("utf-8"))
        except UnicodeDecodeError:
            rows.append("\ufffd")
    return rows


def _project_scopes(path: str, warnings: list[str]) -> Optional[list[str]]:
    try:
        data = Path(path).read_bytes()
    except OSError:
        print("spine-packet-health: cannot read project dictionary", file=sys.stderr)
        return None
    scopes: list[str] = []
    for line_no, raw in enumerate(data.splitlines(), 1):
        try:
            text = raw.decode("utf-8").strip()
        except UnicodeDecodeError:
            warnings.append(f"project dictionary line {line_no}: invalid UTF-8; ignored")
            continue
        if not text or text.startswith("#"):
            continue
        if not SCOPE_RE.fullmatch(text):
            warnings.append(f"project dictionary line {line_no}: invalid scope; ignored")
            continue
        if text in scopes:
            warnings.append(f"project dictionary line {line_no}: duplicate scope; ignored")
            continue
        scopes.append(text)
    if not scopes:
        warnings.append("project dictionary is empty")
    return scopes


def main(argv: list[str]) -> int:
    strict = False
    projects_path = None
    args = argv[1:]
    positional: list[str] = []
    while args:
        if args[0] == "--strict":
            strict = True
            args = args[1:]
        elif args[0] == "--projects" and len(args) >= 2:
            projects_path = args[1]
            args = args[2:]
        else:
            positional.append(args[0])
            args = args[1:]
    if len(positional) != 1:
        print("usage: spine_packet_health.py [--strict] [--projects FILE] PACKET_STATS", file=sys.stderr)
        return 2
    try:
        data = Path(positional[0]).read_bytes()
    except OSError:
        print("spine-packet-health: cannot read packet statistics", file=sys.stderr)
        return 2

    warnings: list[str] = []
    expected_scopes = _project_scopes(projects_path, warnings) if projects_path else None
    if projects_path and expected_scopes is None:
        return 2
    starved = classify(_decode_rows(data), warnings.append, expected_scopes=expected_scopes)
    for warning in warnings:
        print(f"spine-packet-health: {warning}", file=sys.stderr)
    print("; ".join(starved))
    if strict and warnings:
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
