#!/usr/bin/env python3
"""Executable contracts for packet-starvation classification."""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

repo = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(repo / "lib"))

try:
    import spine_packet_health as health
except ImportError as exc:
    raise SystemExit(f"FAIL: packet-health module missing: {exc}")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"FAIL: {message}")


warnings: list[str] = []
rows = [
    "small\t19\t0\t0\n",                 # below the eligible-record gate
    "below-both\t200\t54\t1\n",         # 27% and below the 55-record window
    "absolute-window\t200\t55\t1\n",    # 27%, but enough records shipped
    "coverage-boundary\t100\t35\t1\n",  # exactly 35%
    "no-facts\t100\t80\t0\n",           # facts invariant always wins
]
starved = health.classify(rows, warnings.append)
require(starved == ["below-both 27%", "no-facts 80% NO FACTS"],
        f"threshold boundaries drifted: {starved!r}")
require(not warnings, f"valid rows emitted warnings: {warnings!r}")

warnings = []
malformed = [
    "too\tfew\tcolumns\n",
    "bad-integer\ttwenty\t4\t1\n",
    "shipped-too-many\t20\t21\t1\n",
    "bad-facts-flag\t20\t10\t2\n",
    "bad-encoding-\ufffd\t20\t10\t1\n",
    "bad scope\t20\t10\t1\n",
    "healthy\t20\t20\t1\n",
]
require(health.classify(malformed, warnings.append) == [], "malformed rows changed health state")
require(len(warnings) == 6, f"expected six sanitized warnings, got {warnings!r}")
for warning in warnings:
    require("line " in warning and "ignored" in warning, f"warning lacks location/action: {warning}")
for private_value in ("too", "bad-integer", "shipped-too-many", "bad-facts-flag", "bad-encoding", "bad scope"):
    require(all(private_value not in warning for warning in warnings),
            "warning leaked owner-controlled packet-stat content")

with tempfile.TemporaryDirectory(prefix="memory-spine-packet-health.") as tmp:
    tmp_path = Path(tmp)
    stats = tmp_path / "stats.tsv"
    stats.write_text("below-both\t200\t54\t1\nabsolute-window\t200\t55\t1\n", encoding="utf-8")
    proc = subprocess.run(
        [sys.executable, str(repo / "lib" / "spine_packet_health.py"), str(stats)],
        text=True,
        capture_output=True,
        check=False,
    )
    require(proc.returncode == 0, f"health CLI failed: {proc.stderr}")
    require(proc.stdout.strip() == "below-both 27%", f"health CLI output drifted: {proc.stdout!r}")
    require(proc.stderr == "", f"valid health CLI emitted warning: {proc.stderr!r}")

    stats.write_bytes(b"private-row-\xff\t20\t10\t1\nhealthy\t20\t20\t1\n")
    proc = subprocess.run(
        [sys.executable, str(repo / "lib" / "spine_packet_health.py"), str(stats)],
        text=True,
        capture_output=True,
        check=False,
    )
    require(proc.returncode == 0, "invalid UTF-8 aborted health classification")
    require("line 1: invalid UTF-8; ignored" in proc.stderr, "invalid UTF-8 warning missing")
    require("private-row" not in proc.stderr, "health warning leaked raw row content")
    require("Traceback" not in proc.stderr, "health CLI leaked a traceback")

    strict_proc = subprocess.run(
        [sys.executable, str(repo / "lib" / "spine_packet_health.py"), "--strict", str(stats)],
        text=True,
        capture_output=True,
        check=False,
    )
    require(strict_proc.returncode == 3, "strict health mode accepted malformed statistics")

    unreadable = tmp_path / "not-a-file"
    unreadable.mkdir()
    proc = subprocess.run(
        [sys.executable, str(repo / "lib" / "spine_packet_health.py"), str(unreadable)],
        text=True,
        capture_output=True,
        check=False,
    )
    require(proc.returncode == 2, f"stats read failure was not explicit: {proc.returncode}")
    require("cannot read packet statistics" in proc.stderr, "stats read failure warning missing")
    require("Traceback" not in proc.stderr, "stats read failure leaked a traceback")

health_script = (repo / "bin" / "spine-health").read_text(encoding="utf-8")
require("lib/spine_packet_health.py" in health_script, "spine-health does not invoke tested classifier")
require("--strict" in health_script, "spine-health does not fail visibly on malformed statistics")
require("config/packet-limits.conf" in health_script, "starvation remediation ignores per-scope config")

# Exercise the production shell wiring in an isolated install layout. Other
# health channels deliberately alert because this is not a live git vault; the
# assertions inspect only the packet-specific line. The notifier is a local
# stub, so this test cannot send messages or touch owner state.
with tempfile.TemporaryDirectory(prefix="memory-spine-health-integration.") as tmp:
    base = Path(tmp)
    home = base / "home"
    tools = home / "dev" / "memory-spine"
    root = home / "AgentMemory"
    logs = base / "logs"
    notify_log = base / "notify.log"
    for directory in (tools / "bin", tools / "lib", tools / "config",
                      root / "_index", root / "config", root / "alpha" / "facts", logs):
        directory.mkdir(parents=True, exist_ok=True)
    shutil.copy2(repo / "bin" / "spine-health", tools / "bin" / "spine-health")
    shutil.copy2(repo / "lib" / "spine_packet_health.py", tools / "lib" / "spine_packet_health.py")
    shutil.copy2(repo / "lib" / "spine_paths.sh", tools / "lib" / "spine_paths.sh")
    notifier = tools / "bin" / "spine-notify"
    notifier.write_text(
        '#!/bin/sh\nprintf "%s\\n" "$*" >> "${SPINE_TEST_NOTIFY_LOG:?}"\n',
        encoding="utf-8",
    )
    notifier.chmod(0o755)
    (root / "config" / "projects.txt").write_text("alpha\n", encoding="utf-8")
    (tools / "config" / "projects.txt").write_text("alpha\n", encoding="utf-8")
    stats = root / "_index" / ".packet-stats.tsv"
    env = os.environ.copy()
    env.update({
        "HOME": str(home),
        "SPINE_ROOT": str(root),
        "SPINE_TOOLS_DIR": str(tools),
        "SPINE_LOG_DIR": str(logs),
        "SPINE_TEST_NOTIFY_LOG": str(notify_log),
        "SPINE_GIT": shutil.which("git") or "git",
    })

    def run_health(stats_bytes: bytes) -> tuple[subprocess.CompletedProcess[str], str]:
        stats.write_bytes(stats_bytes)
        (logs / "sync.log").unlink(missing_ok=True)
        result = subprocess.run(
            ["/bin/bash", str(tools / "bin" / "spine-health")],
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        return result, (logs / "sync.log").read_text(encoding="utf-8")

    proc, health_log = run_health(b"alpha\t200\t54\t1\n")
    require(proc.returncode == 1, "isolated starving health run did not alert")
    require("packet starving: alpha 27%" in health_log, "starvation did not reach spine-health alert log")

    proc, health_log = run_health(b"alpha\t200\t55\t1\n")
    require(proc.returncode == 1, "isolated health fixture unexpectedly had no baseline alerts")
    require("packet starving:" not in health_log, "absolute 55-record window still alerted")

    proc, health_log = run_health(b"private-row-\xff\t20\t10\t1\n")
    require(proc.returncode == 1, "malformed strict health run did not alert")
    require("packet statistics invalid or unreadable" in health_log,
            "malformed packet statistics did not reach spine-health alert log")
    require("private-row" not in proc.stderr, "integration warning leaked raw packet-stat content")
print("packet-health-test: PASS")
