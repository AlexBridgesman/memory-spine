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
    "tests/test-packet-limits.sh", "tests/test-packet-delivery.sh", "tests/test-hook-delivery.sh",
    "tests/test-packet-health.py",
    "tests/test-website.py", "tests/test-release-archive.sh", "benchmarks/recall/run.py",
):
    if command not in ci:
        errors.append(f"ci.yml: missing required check {command}")

release = (repo / ".github" / "workflows" / "release-integrity.yml").read_text(encoding="utf-8")
for contract in ("pull_request:", "push:", "github.event.pull_request.head.sha"):
    if contract not in release:
        errors.append(f"release-integrity.yml: missing exact-candidate contract {contract}")
if "cd dist && sha256sum --check SHA256SUMS" not in release:
    errors.append("release-integrity.yml: manifest is not verified from its archive directory")
if "default: v0.1.1" in release:
    errors.append("release-integrity.yml: manual packaging still defaults to a stale release ref")
if "description: Exact tag or full commit SHA to package" not in release:
    errors.append("release-integrity.yml: manual packaging does not require an explicit exact ref")
if "name: Test extracted archive" not in release:
    errors.append("release-integrity.yml: packaged archive is not exercised before upload")

builder = (repo / "scripts" / "build-release.sh").read_text(encoding="utf-8")
for contract in ("RELEASE-METADATA", 'mtime=0', 'gzip.GzipFile(filename=""',
                 "tar.umask=0022", 'show "$COMMIT:VERSION"'):
    if contract not in builder:
        errors.append(f"build-release.sh: deterministic embedded provenance missing {contract}")
installer = (repo / "install.sh").read_text(encoding="utf-8")
if '[ -e "$SCRIPT_DIR/.git" ]' not in installer:
    errors.append("install.sh: extracted archive can inherit provenance from an unrelated parent repository")
for contract in ('HOME="$RUNNER_TEMP/release-home" ./install.sh --apply --yes',
                 'template_commit: $RELEASE_REF'):
    if contract not in release:
        errors.append(f"release-integrity.yml: extracted install acceptance missing {contract}")

paths = (repo / "lib" / "spine_paths.sh").read_text(encoding="utf-8")
for contract in ("spine_resolve_python", "SPINE_PYTHON", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"):
    if contract not in paths:
        errors.append(f"spine_paths.sh: shared Python resolver missing {contract}")
python_consumers = (
    "spine-sync", "spine-health", "spine-selftest", "spine-preflight", "spine-uninstall",
    "spine-hook-sessionstart", "spine-hook-stop", "spine-digest", "spine-maintain",
    "spine-notify", "spine-tg-token",
)
for name in python_consumers:
    script = (repo / "bin" / name).read_text(encoding="utf-8")
    if "/usr/bin/python3" in script:
        errors.append(f"{name}: hard-coded system Python remains in the production path")
    if "spine_resolve_python" not in script:
        errors.append(f"{name}: shared Python resolver is not used")

session_hook = (repo / "bin" / "spine-hook-sessionstart").read_text(encoding="utf-8")
if '"$PYTHON" "$BINDIR/spine-packet"' not in session_hook:
    errors.append("spine-hook-sessionstart: resolved Python is not used for packet launch")
for name in ("spine-hook-sessionstart", "spine-hook-stop"):
    script = (repo / "bin" / name).read_text(encoding="utf-8")
    if "stat -f" in script:
        errors.append(f"{name}: direct noisy BSD/GNU stat probe remains")

sandbox = (repo / "bin" / "spine-agent-sandbox").read_text(encoding="utf-8")
if 'model = "gpt-5.6-sol"' in sandbox:
    errors.append("spine-agent-sandbox: generated config hard-codes an environment-specific model")
if "does not block direct filesystem reads" not in sandbox:
    errors.append("spine-agent-sandbox: direct-filesystem-read limitation is not explicit")
if "Spine command access" not in sandbox:
    errors.append("spine-agent-sandbox: gate scope is not described as Spine-mediated access")

# A failed BSD stat probe can print partial GNU output before its non-zero exit;
# a direct `probe || fallback` therefore contaminates numeric command output.
noisy_stat_fallback = re.compile(r"stat -f %[mz].*\|\|\s*stat -c %[Ys]")
for script in sorted((repo / "bin").glob("spine-*")):
    if noisy_stat_fallback.search(script.read_text(encoding="utf-8", errors="replace")):
        errors.append(f"{script.name}: noisy BSD/GNU stat fallback is not isolated")

# Public source comments explain generic rationale, not owner-specific incident
# history, exact private audit dates, or operational anecdotes.
private_anecdote = re.compile(
    r"past audit|past incident|found by an audit|audit (?:found|counted)|"
    r"exactly what happened|owner once|once (?:hung|took|started|received|lived)|"
    r"20 open|9 of them|over 3 weeks",
    re.I,
)
for directory in (repo / "bin", repo / "lib"):
    for source in sorted(path for path in directory.iterdir() if path.is_file()):
        text = source.read_text(encoding="utf-8", errors="replace")
        for line_no, line in enumerate(text.splitlines(), 1):
            if private_anecdote.search(line):
                errors.append(f"{source.relative_to(repo)}:{line_no}: private operational anecdote remains")

if errors:
    for error in errors:
        print(f"FAIL: {error}", file=sys.stderr)
    raise SystemExit(1)
print(f"supply-chain-test: PASS ({len(workflows)} workflows)")
