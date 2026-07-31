#!/usr/bin/env python3
"""Run the public, synthetic recall regression set against the real CLI."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ULID_RE = re.compile(r"[0-9A-HJKMNP-TV-Z]{26}")


def tree_digest(base: Path, paths: list[Path]) -> str:
    """Hash relative names plus bytes so the reported fixture is reproducible."""
    digest = hashlib.sha256()
    for path in sorted(paths):
        digest.update(str(path.relative_to(base)).encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true", help="emit machine-readable results")
    args = parser.parse_args()

    here = Path(__file__).resolve().parent
    repo = here.parents[1]
    cases = json.loads((here / "cases.json").read_text(encoding="utf-8"))
    fixture_files = [here / "cases.json", *(
        path for path in (here / "fixture").rglob("*") if path.is_file()
    )]
    fixture_sha256 = tree_digest(here, fixture_files)
    implementation_sha256 = hashlib.sha256((repo / "bin" / "spine-recall").read_bytes()).hexdigest()
    commit = subprocess.run(
        ["git", "-C", str(repo), "rev-parse", "HEAD"], text=True,
        capture_output=True, check=False,
    ).stdout.strip() or "unknown"
    dirty = bool(subprocess.run(
        ["git", "-C", str(repo), "status", "--porcelain", "--",
         "bin/spine-recall", "benchmarks/recall"], text=True,
        capture_output=True, check=False,
    ).stdout.strip())
    results = []

    with tempfile.TemporaryDirectory(prefix="memory-spine-recall-benchmark-") as log_dir:
        env = os.environ.copy()
        env.update({
            "SPINE_ROOT": str(here / "fixture"),
            "SPINE_CONFIG_DIR": str(here / "fixture" / "config"),
            "SPINE_TOOLS_DIR": str(repo),
            "SPINE_LOG_DIR": log_dir,
            "SPINE_NO_GATE": "1",
        })
        for case in cases:
            proc = subprocess.run(
                [sys.executable, str(repo / "bin" / "spine-recall"), case["query"],
                 "--scope", case["scope"], "--limit", "3"],
                env=env,
                text=True,
                capture_output=True,
                timeout=10,
            )
            match = ULID_RE.search(proc.stdout)
            actual = match.group(0) if match else None
            results.append({
                "query": case["query"],
                "expected_top_ulid": case["expected_top_ulid"],
                "actual_top_ulid": actual,
                "passed": proc.returncode == 0 and actual == case["expected_top_ulid"],
                "returncode": proc.returncode,
            })

    passed = sum(result["passed"] for result in results)
    report = {
        "kind": "synthetic recall regression set",
        "limitations": "Not an independent benchmark and not evidence of production recall quality.",
        "fixture_sha256": fixture_sha256,
        "implementation_sha256": implementation_sha256,
        "source_commit": commit,
        "source_dirty": dirty,
        "passed": passed,
        "total": len(results),
        "results": results,
    }
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print("Synthetic recall regression set (not an independent benchmark)")
        print(f"fixture-sha256: {fixture_sha256}")
        print(f"implementation-sha256: {implementation_sha256}")
        print(f"source: {commit}{' (dirty)' if dirty else ''}")
        for result in results:
            mark = "PASS" if result["passed"] else "FAIL"
            print(f"{mark}: {result['query']} -> {result['actual_top_ulid'] or '(none)'}")
        print(f"recall-benchmark: {passed}/{len(results)}")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
