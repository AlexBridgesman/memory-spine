#!/usr/bin/env python3
"""Deterministic structural/trust checks for the canonical static website."""
from __future__ import annotations

import json
import re
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlparse

repo = Path(__file__).resolve().parents[1]
root = repo / "website"
errors: list[str] = []
VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}


class Audit(HTMLParser):
    def __init__(self, name: str) -> None:
        super().__init__(convert_charrefs=True)
        self.name = name
        self.stack: list[str] = []
        self.refs: list[str] = []
        self.attrs: list[tuple[str, dict[str, str | None]]] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        names = [name for name, _ in attrs]
        if len(names) != len(set(names)):
            errors.append(f"{self.name}: duplicate attribute on <{tag}>")
        values = dict(attrs)
        self.attrs.append((tag, values))
        for key in ("href", "src"):
            value = values.get(key)
            if value:
                self.refs.append(value)
        if tag not in VOID:
            self.stack.append(tag)

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.handle_starttag(tag, attrs)
        if tag not in VOID:
            self.stack.pop()

    def handle_endtag(self, tag: str) -> None:
        if not self.stack or self.stack[-1] != tag:
            errors.append(f"{self.name}: mismatched </{tag}>; stack tail={self.stack[-3:]}")
            if tag in self.stack:
                while self.stack and self.stack[-1] != tag:
                    self.stack.pop()
                if self.stack:
                    self.stack.pop()
            return
        self.stack.pop()


def require(condition: bool, message: str) -> None:
    if not condition:
        errors.append(message)


def local_target(ref: str) -> Path | None:
    parsed = urlparse(ref)
    if parsed.scheme or parsed.netloc or ref.startswith(("#", "mailto:")):
        return None
    path = parsed.path
    if not path or path == "/":
        return None
    if path == "/technical":
        return root / "technical.html"
    if path == "/whitepaper":
        return None  # Vercel redirect, asserted below.
    candidate = root / path.lstrip("/")
    return candidate


html_files = [root / "index.html", root / "technical.html", root / "404.html"]
for path in html_files:
    text = path.read_text(encoding="utf-8")
    parser = Audit(path.name)
    parser.feed(text)
    parser.close()
    if parser.stack:
        errors.append(f"{path.name}: unclosed tags {parser.stack[-5:]}")
    for ref in parser.refs:
        target = local_target(ref)
        if target is not None and not target.is_file():
            errors.append(f"{path.name}: missing local target {ref}")

index = (root / "index.html").read_text(encoding="utf-8")
technical = (root / "technical.html").read_text(encoding="utf-8")
not_found = (root / "404.html").read_text(encoding="utf-8")
machine_docs = (root / "agents.md").read_text(encoding="utf-8")
readme = (repo / "README.md").read_text(encoding="utf-8")
architecture = (repo / "docs" / "ARCHITECTURE.md").read_text(encoding="utf-8")
changelog = (repo / "CHANGELOG.md").read_text(encoding="utf-8")
spine_gen = (repo / "bin" / "spine-gen").read_text(encoding="utf-8")
claim_text = "\n".join((index, technical, machine_docs))
require(len(index.encode("utf-8")) <= 100_000, "index.html exceeds 100 KB")
require("data:image/png;base64" not in index, "index embeds a base64 PNG")
require('src="/assets/memory-graph.jpg"' in index, "external graph asset missing")
require('width="1000"' in index and 'height="947"' in index, "graph dimensions missing")
require((root / "assets" / "memory-graph.jpg").stat().st_size <= 150_000,
        "graph asset exceeds 150 KB")
require('loading="lazy"' in index and 'decoding="async"' in index, "graph loading hints missing")
require('hreflang="en"' in index and 'hreflang="uk"' in index and 'hreflang="x-default"' in index,
        "hreflang set incomplete")
require('property="og:locale" content="en_US"' in index and "uk_UA" in index, "OG locale metadata incomplete")
require('<caption class="sr-only"' in index, "comparison table has no caption")
require("--link: #0369A1" in index and "--focus: #0369A1" in index, "accessible light-theme tokens missing")
require("<main" in index and "</main>" in index and "<main" in technical and "</main>" in technical,
        "main landmark missing")
require("Technical Reference" in technical and "whitepaper" not in technical.casefold(),
        "technical page still presents itself as a whitepaper")
require('name="robots" content="noindex"' in not_found, "404 is indexable")

for banned in (
    "9/10 top-1", "13-test", "Zero infrastructure", "Guaranteed context",
    "automatically receives", "every AI agent on your machine",
    "Every access — allowed or denied", "immutable records", "never a loss",
    "never fails silently", "Ops-grade reliability", "survived production",
    "Every tool hoards", "Everything on the machine is trusted",
    "Any agent that can read files and run shell commands participates",
    "never an edit", "Git keeps everything",
    "Each scope compiles into a ≤14 KB packet", "Кожен scope збирається в packet ≤14 КБ",
    "Packet ≤14 KB + per-agent delta", "packet</b> (≤14 KB",
):
    require(banned.casefold() not in claim_text.casefold(), f"stale public claim remains: {banned}")
qualified_durability = "Committed history remains available unless history is explicitly rewritten."
require(all(qualified_durability in text for text in (readme, technical, machine_docs)),
        "qualified durability wording drifted across README, technical, and machine docs")
packet_limits_contract = (
    "Optional per-scope packet caps are read from config/packet-limits.conf; unlisted scopes keep "
    "the 14,000-byte default, and configured values below 4,000 bytes are clamped."
)
packet_limits_opt_in = "Copy config/packet-limits.conf.example to that path to opt in."
starvation_contract = (
    "For scopes with at least 20 eligible records, packet starvation requires both coverage below "
    "35% and fewer than 55 shipped records; shipping zero facts always alerts."
)
for surface_name, surface in (
    ("README", readme), ("architecture", architecture),
    ("technical", technical), ("machine docs", machine_docs),
):
    require(packet_limits_contract in surface, f"{surface_name}: packet-limit contract missing")
    require(packet_limits_opt_in in surface, f"{surface_name}: packet-limit opt-in instruction missing")
    require(starvation_contract in surface, f"{surface_name}: starvation contract missing")
public_release_text = "\n".join((claim_text, readme, architecture, changelog, spine_gen))
for banned in ("Born in production", "author's production vault", "164-record", "four scopes capped"):
    require(banned.casefold() not in public_release_text.casefold(),
            f"private or unsupported production claim remains: {banned}")
require("Backup behavior is opt-in" in index, "backup scheduling is not clearly opt-in")
require("documented fail-open branches" in machine_docs, "access-gate fail-open behavior is missing")

# Every translated element must have a Ukrainian dictionary key.
data_keys = set(re.findall(r'data-i18n="([A-Za-z0-9_]+)"', index))
match = re.search(r"const I18N = \{ ua: \{(.*?)\}\};", index, re.S)
require(match is not None, "Ukrainian dictionary missing")
if match:
    ua_keys = set(re.findall(r"(?:^|,)\s*([A-Za-z0-9_]+)\s*:", match.group(1)))
    missing = sorted(data_keys - ua_keys)
    require(not missing, f"missing Ukrainian keys: {', '.join(missing)}")
require("requestedLang" in index and 'searchParams.set("lang", "ua")' in index,
        "shareable Ukrainian URL behavior missing")

# Structured data and deployment config must parse without third-party tools.
ld = re.search(r'<script type="application/ld\+json">(.*?)</script>', index, re.S)
require(ld is not None, "JSON-LD missing")
if ld:
    try:
        json.loads(ld.group(1))
    except json.JSONDecodeError as exc:
        errors.append(f"invalid JSON-LD: {exc}")
try:
    vercel = json.loads((root / "vercel.json").read_text(encoding="utf-8"))
except json.JSONDecodeError as exc:
    errors.append(f"invalid vercel.json: {exc}")
    vercel = {}
redirects = {(item.get("source"), item.get("destination")) for item in vercel.get("redirects", [])}
require(("/whitepaper", "/technical") in redirects, "legacy /whitepaper redirect missing")
require(("/whitepaper.html", "/technical") in redirects, "legacy /whitepaper.html redirect missing")
require(any(header.get("key") == "Content-Security-Policy"
            for block in vercel.get("headers", []) for header in block.get("headers", [])),
        "Content-Security-Policy header missing")

require((root / "robots.txt").is_file(), "robots.txt missing")
require((root / "sitemap.xml").is_file(), "sitemap.xml missing")
require((root / ".well-known" / "security.txt").is_file(), "security.txt missing")
require((root / "agents.md").read_bytes() == (root / "llms.txt").read_bytes(),
        "agents.md and llms.txt drifted")

if errors:
    for error in errors:
        print(f"FAIL: {error}", file=sys.stderr)
    raise SystemExit(1)
print(f"website-test: PASS ({len(html_files)} HTML files, {len(data_keys)} translated keys)")
