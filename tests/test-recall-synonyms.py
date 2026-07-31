#!/usr/bin/env python3
"""Regression probes for the documented tab/comma synonym grammar."""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

repo = Path(__file__).resolve().parents[1]
fixture = repo / "benchmarks" / "recall" / "fixture"
probes = [
    ("key rotation", "01J00000000000000000000006"),
    ("ship checksum verification", "01J00000000000000000000010"),
]
ulid_re = re.compile(r"[0-9A-HJKMNP-TV-Z]{26}")

with tempfile.TemporaryDirectory(prefix="memory-spine-synonyms-") as logs:
    config = Path(logs) / "config"
    shutil.copytree(fixture / "config", config)
    shutil.copy2(repo / "config" / "synonyms.tsv", config / "synonyms.tsv")
    env = os.environ.copy()
    env.update({
        "SPINE_ROOT": str(fixture),
        "SPINE_CONFIG_DIR": str(config),
        "SPINE_TOOLS_DIR": str(repo),
        "SPINE_LOG_DIR": logs,
        "SPINE_NO_GATE": "1",
    })
    failed = []
    for query, expected in probes:
        run = subprocess.run(
            [sys.executable, str(repo / "bin" / "spine-recall"), query,
             "--scope", "benchmark", "--limit", "1"],
            env=env, text=True, capture_output=True, timeout=10,
        )
        match = ulid_re.search(run.stdout)
        actual = match.group(0) if match else None
        degraded = ("no hits for the full query" in run.stdout or
                    "no exact match on all words" in run.stdout)
        if run.returncode != 0 or actual != expected or degraded:
            failed.append((query, expected, actual, run.returncode))

if failed:
    for query, expected, actual, rc in failed:
        print(f"FAIL: {query!r}: expected {expected}, got {actual}, rc={rc}", file=sys.stderr)
    raise SystemExit(1)
print(f"recall-synonyms: PASS ({len(probes)}/{len(probes)})")
