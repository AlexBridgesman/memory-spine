#!/usr/bin/env python3
"""Policy checks for immutable and least-privilege CI dependencies."""
from __future__ import annotations

import re
import sys
from pathlib import Path

repo = Path(__file__).resolve().parents[1]
workflows = sorted((repo / ".github" / "workflows").glob("*.y*ml"))
errors: list[str] = []
uses_re = re.compile(r"^\s*-?\s*uses:\s*([^\s#]+)", re.M)
image_re = re.compile(r"(?:docker\s+run[^\n]*\n(?:[^\n]*\n)*?\s+)([\w./-]+(?:@sha256:[0-9a-f]{64}|:[\w.-]+))")

for workflow in workflows:
    text = workflow.read_text(encoding="utf-8")
    for ref in uses_re.findall(text):
        if ref.startswith("./"):
            continue
        if not re.fullmatch(r"[^@]+@[0-9a-f]{40}", ref):
            errors.append(f"{workflow.name}: mutable action reference {ref}")
    for line_no, line in enumerate(text.splitlines(), 1):
        if re.search(r"(?:ghcr\.io|docker\.io|quay\.io)/", line):
            image = line.strip().split()[0]
            if not re.search(r"@sha256:[0-9a-f]{64}(?:\s|$)", line):
                errors.append(f"{workflow.name}:{line_no}: mutable container reference {image}")

ci = (repo / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
if "on:\n  push:\n  pull_request:" not in ci:
    errors.append("ci.yml: push checks do not cover exact candidate branches")
if "persist-credentials: false" not in ci:
    errors.append("ci.yml: checkout credentials are persisted")
if "--network none" not in ci or ':/repo:ro' not in ci:
    errors.append("ci.yml: gitleaks container is not read-only/network-isolated")
for command in (
    "tests/test-installer.sh", "tests/test-paths.sh", "tests/test-selftest-isolation.sh",
    "tests/test-cross-agent-e2e.sh", "tests/test-recall-synonyms.py",
    "tests/test-packet-limits.sh", "tests/test-packet-health.py",
    "tests/test-website.py", "benchmarks/recall/run.py",
):
    if command not in ci:
        errors.append(f"ci.yml: missing required check {command}")

release = (repo / ".github" / "workflows" / "release-integrity.yml").read_text(encoding="utf-8")
for contract in ("pull_request:", "push:", "github.event.pull_request.head.sha"):
    if contract not in release:
        errors.append(f"release-integrity.yml: missing exact-candidate contract {contract}")
if "cd dist && sha256sum --check SHA256SUMS" not in release:
    errors.append("release-integrity.yml: manifest is not verified from its archive directory")

if errors:
    for error in errors:
        print(f"FAIL: {error}", file=sys.stderr)
    raise SystemExit(1)
print(f"supply-chain-test: PASS ({len(workflows)} workflows)")
