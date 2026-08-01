#!/usr/bin/env python3
"""Executable contracts for packet-starvation classification."""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import time
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
require(
    health.classify(["alpha\t20\t20\t1\n"], warnings.append,
                    expected_scopes=["alpha", "beta"]) == [],
    "scope-completeness validation changed health labels",
)
require(any("missing configured scope row" in warning for warning in warnings),
        f"missing expected scope was accepted: {warnings!r}")
warnings = []
health.classify(
    ["alpha\t20\t20\t1\n", "alpha\t20\t20\t1\n", "extra\t20\t20\t1\n"],
    warnings.append,
    expected_scopes=["alpha"],
)
require(any("duplicate scope" in warning for warning in warnings), "duplicate scope row was accepted")
require(any("unexpected scope" in warning for warning in warnings), "unexpected scope row was accepted")

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
    projects = tmp_path / "projects.txt"
    projects.write_text("below-both\nabsolute-window\n", encoding="utf-8")
    stats.write_text("below-both\t200\t54\t1\nabsolute-window\t200\t55\t1\n", encoding="utf-8")
    proc = subprocess.run(
        [sys.executable, str(repo / "lib" / "spine_packet_health.py"),
         "--projects", str(projects), str(stats)],
        text=True,
        capture_output=True,
        check=False,
    )
    require(proc.returncode == 0, f"health CLI failed: {proc.stderr}")
    require(proc.stdout.strip() == "below-both 27%", f"health CLI output drifted: {proc.stdout!r}")
    require(proc.stderr == "", f"valid health CLI emitted warning: {proc.stderr!r}")

    stats.write_bytes(b"")
    empty_proc = subprocess.run(
        [sys.executable, str(repo / "lib" / "spine_packet_health.py"), "--strict",
         "--projects", str(projects), str(stats)],
        text=True,
        capture_output=True,
        check=False,
    )
    require(empty_proc.returncode == 3, "strict health mode accepted empty statistics")
    require("empty packet statistics" in empty_proc.stderr, "empty statistics warning missing")

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

# A killed all-scope refresh must invalidate the previous snapshot before any
# packet is published. The child replaces generation with a deterministic
# first-packet write and pause, then the parent kills it in that exact window.
with tempfile.TemporaryDirectory(prefix="memory-spine-stats-kill.") as tmp:
    base = Path(tmp)
    root = base / "vault"
    tools = base / "tools"
    out = root / "_index"
    signal_path = base / "first-packet-published"
    for directory in (out, root / "config", tools / "config"):
        directory.mkdir(parents=True, exist_ok=True)
    (tools / "config" / "projects.txt").write_text("alpha\nbeta\n", encoding="utf-8")
    (tools / "config" / "types.txt").write_text("fact\n", encoding="utf-8")
    stats = out / ".packet-stats.tsv"
    stats.write_text("alpha\t20\t20\t1\nbeta\t20\t20\t1\n", encoding="utf-8")
    child_code = r'''
import runpy,sys,time
from pathlib import Path
script,output,signal=sys.argv[1:]
ns=runpy.run_path(script,run_name="spine_gen_kill_probe")
state=ns["main"].__globals__
state["PROJECTS"]=["alpha","beta"]
state["OUT"]=output
state["inbox_pending"]=lambda: 0
def fake_gen(project,_inbox):
    if project == "alpha":
        Path(output,"packet-alpha.md").write_text("partial packet\n",encoding="utf-8")
        Path(signal).write_text("ready\n",encoding="utf-8")
        time.sleep(60)
    return 1,20,20,1
state["gen_project"]=fake_gen
sys.argv=[script]
raise SystemExit(ns["main"]())
'''
    env = os.environ.copy()
    env.update({"SPINE_ROOT": str(root), "SPINE_TOOLS_DIR": str(repo),
                "SPINE_CONFIG_DIR": str(tools / "config")})
    proc = subprocess.Popen(
        [sys.executable, "-c", child_code, str(repo / "bin" / "spine-gen"),
         str(out), str(signal_path)],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    deadline = time.time() + 5
    while not signal_path.exists() and time.time() < deadline and proc.poll() is None:
        time.sleep(0.02)
    if not signal_path.exists():
        if proc.poll() is None:
            proc.kill()
        child_stdout, child_stderr = proc.communicate(timeout=5)
        require(False, "kill-window generation probe did not publish its first packet "
                f"(rc={proc.returncode}, stdout={child_stdout!r}, stderr={child_stderr!r})")
    proc.kill()
    proc.communicate(timeout=5)
    require((out / "packet-alpha.md").is_file(), "kill-window probe missed partial publication")
    require(not stats.exists(), "SIGKILL window left previous packet statistics looking valid")

health_script = (repo / "bin" / "spine-health").read_text(encoding="utf-8")
require("lib/spine_packet_health.py" in health_script, "spine-health does not invoke tested classifier")
require("--strict" in health_script, "spine-health does not fail visibly on malformed statistics")
require("config/packet-limits.conf" in health_script, "starvation remediation ignores per-scope config")
require("/usr/bin/python3" not in health_script, "spine-health still hard-codes /usr/bin/python3")

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
    fake_bin = base / "fake-bin"
    for directory in (tools / "bin", tools / "lib", tools / "config",
                      root / "_index", root / "config", root / "alpha" / "facts",
                      root / "beta" / "facts", logs, fake_bin):
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
    # GNU stat may print a filesystem report for the valid operand in
    # `stat -f %m FILE` before exiting non-zero for the missing `%m` operand.
    # Reproduce that noisy failed probe on both CI platforms so the fallback
    # cannot regress into a mixed, non-numeric mtime again.
    fake_stat = fake_bin / "stat"
    fake_stat.write_text(
        "#!/bin/sh\n"
        "if [ \"${1:-}\" = -f ]; then\n"
        "  printf 'simulated GNU filesystem report\\n'\n"
        "  exit 1\n"
        "fi\n"
        "if [ \"${1:-}\" = -c ]; then\n"
        "  if [ \"$(uname -s)\" = Darwin ]; then\n"
        "    exec \"${SPINE_TEST_REAL_STAT:?}\" -f %m \"$3\"\n"
        "  fi\n"
        "fi\n"
        "exec \"${SPINE_TEST_REAL_STAT:?}\" \"$@\"\n",
        encoding="utf-8",
    )
    fake_stat.chmod(0o755)
    (root / "config" / "projects.txt").write_text("alpha\nbeta\n", encoding="utf-8")
    (tools / "config" / "projects.txt").write_text("alpha\nbeta\n", encoding="utf-8")
    stats = root / "_index" / ".packet-stats.tsv"
    env = os.environ.copy()
    env.update({
        "HOME": str(home),
        "SPINE_ROOT": str(root),
        "SPINE_TOOLS_DIR": str(tools),
        "SPINE_LOG_DIR": str(logs),
        "SPINE_TEST_NOTIFY_LOG": str(notify_log),
        "SPINE_TEST_REAL_STAT": shutil.which("stat") or "/usr/bin/stat",
        "SPINE_GIT": shutil.which("git") or "git",
        "SPINE_PYTHON": sys.executable,
        "PATH": f"{fake_bin}{os.pathsep}{env.get('PATH', '')}",
    })

    source = root / "alpha" / "facts" / "packet-input.md"

    def run_health(stats_bytes: bytes | None, *, stale: bool = False,
                   source_newer: bool = False) -> tuple[subprocess.CompletedProcess[str], str]:
        source.unlink(missing_ok=True)
        if stats_bytes is None:
            stats.unlink(missing_ok=True)
        else:
            stats.write_bytes(stats_bytes)
            if stale:
                old = time.time() - 172800
                os.utime(stats, (old, old))
                for dictionary in (root / "config" / "projects.txt",
                                   tools / "config" / "projects.txt"):
                    os.utime(dictionary, (old - 10, old - 10))
                if source_newer:
                    source.write_text("synthetic packet input\n", encoding="utf-8")
                    os.utime(source, (old + 10, old + 10))
        (logs / "sync.log").unlink(missing_ok=True)
        (logs / ".health-alert-tg").unlink(missing_ok=True)
        result = subprocess.run(
            ["/bin/bash", str(tools / "bin" / "spine-health")],
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        return result, (logs / "sync.log").read_text(encoding="utf-8")

    proc, health_log = run_health(b"alpha\t200\t54\t1\nbeta\t20\t20\t1\n")
    require(proc.returncode == 1, "isolated starving health run did not alert")
    require(
        "packet starving: alpha 27%" in health_log,
        "starvation did not reach spine-health alert log "
        f"(log={health_log!r}, stderr={proc.stderr!r}, stdout={proc.stdout!r})",
    )

    proc, health_log = run_health(b"alpha\t200\t55\t1\nbeta\t20\t20\t1\n")
    require(proc.returncode == 1, "isolated health fixture unexpectedly had no baseline alerts")
    require("packet starving:" not in health_log, "absolute 55-record window still alerted")

    proc, health_log = run_health(b"private-row-\xff\t20\t10\t1\nbeta\t20\t20\t1\n")
    require(proc.returncode == 1, "malformed strict health run did not alert")
    require("packet statistics missing, stale, incomplete, or unreadable" in health_log,
            "malformed packet statistics did not reach spine-health alert log")
    require("private-row" not in proc.stderr, "integration warning leaked raw packet-stat content")

    proc, health_log = run_health(b"alpha\t20\t20\t1\n")
    require("packet statistics missing, stale, incomplete, or unreadable" in health_log,
            "partial scope snapshot did not alert")

    proc, health_log = run_health(None)
    require("packet statistics missing, stale, incomplete, or unreadable" in health_log,
            "missing statistics did not alert")

    proc, health_log = run_health(b"alpha\t20\t20\t1\nbeta\t20\t20\t1\n", stale=True)
    require("packet statistics missing, stale, incomplete, or unreadable" not in health_log,
            "quiet unchanged vault rejected an old but current statistics snapshot")

    proc, health_log = run_health(
        b"alpha\t20\t20\t1\nbeta\t20\t20\t1\n", stale=True, source_newer=True
    )
    require("packet statistics missing, stale, incomplete, or unreadable" in health_log,
            "statistics older than a packet input did not alert")
print("packet-health-test: PASS")
