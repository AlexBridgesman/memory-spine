#!/usr/bin/env python3
"""Classify packet coverage statistics for spine-health."""
from __future__ import annotations

import re
import sys
from collections.abc import Callable, Iterable
from pathlib import Path

MIN_ELIGIBLE_RECORDS = 20
MIN_COVERAGE_PERCENT = 35
MIN_SHIPPED_RECORDS = 55
SCOPE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")


def classify(rows: Iterable[str], warn: Callable[[str], None]) -> list[str]:
    """Return starved-scope labels; malformed rows are skipped with safe warnings."""
    starved: list[str] = []
    for line_no, row in enumerate(rows, 1):
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
    return starved


def _decode_rows(data: bytes) -> list[str]:
    rows: list[str] = []
    for raw in data.splitlines():
        try:
            rows.append(raw.decode("utf-8"))
        except UnicodeDecodeError:
            rows.append("\ufffd")
    return rows


def main(argv: list[str]) -> int:
    strict = False
    args = argv[1:]
    if args[:1] == ["--strict"]:
        strict = True
        args = args[1:]
    if len(args) != 1:
        print("usage: spine_packet_health.py [--strict] PACKET_STATS", file=sys.stderr)
        return 2
    try:
        data = Path(args[0]).read_bytes()
    except OSError:
        print("spine-packet-health: cannot read packet statistics", file=sys.stderr)
        return 2

    warnings: list[str] = []
    starved = classify(_decode_rows(data), warnings.append)
    for warning in warnings:
        print(f"spine-packet-health: {warning}", file=sys.stderr)
    print("; ".join(starved))
    if strict and warnings:
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
