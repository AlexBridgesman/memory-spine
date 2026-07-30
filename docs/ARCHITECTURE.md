# Architecture

Memory Spine is a file-based memory layer shared by every AI agent working around the same human or project.

## Components

1. **Memory vault** — `~/AgentMemory`: markdown records, one file per record, immutable.
2. **CLI tools** — `~/dev/memory-spine/bin`: the only sanctioned interface to the vault.
3. **Access gate** — `lib/spine_gate.py`: default-deny by process ancestry, consulted by reading/writing tools.
4. **Generated views** — per-scope `INDEX.md`, distilled `_index/packet-<scope>.md` (≤14 KB), a 30-day `_index/journal.md`.
5. **Daemons** (launchd on macOS, cron on Linux) — `spine-sync` (commit every 5 min, dead-letter flush), `spine-backup` (nightly), `spine-digest` (morning summary), `spine-health` (runs inside the sync cycle).
6. **Notifications** — `spine-notify` → Telegram + local banner, with a dead-letter queue so undeliverable alerts are retried, not lost.

## Data model

```text
<scope>/
  decisions/   # choices that guide future work
  facts/       # verified durable statements
  threads/     # open coordination items, blockers, handoffs
  artifacts/   # pointers to larger objects (never the content itself)
  INDEX.md     # generated, with honest caps ("40 newest of 91, rest via recall")
  <scope>.md   # hub note (wikilink anchor)
```

Each record has core frontmatter fields:

```yaml
---
type: fact
project: personal
agent: user
title: "Example durable fact"
status: active            # active | blocked | archived
created: 2026-01-01T00:00:00Z
sources:
  - manual:example
sensitivity: normal       # normal | private | local_only
confidence: candidate     # verified | reported | candidate | untrusted
# optional: pinned, also: [other-scope], supersedes: <ULID>, for_agent
---
```

The body includes at least one wikilink, usually the scope hub such as `[[personal]]`.

## Write path

`spine-new` is the single entry point: schema validation → per-file secret scan → dedup write-gate (search first, then ADD / SUPERSEDE / NOOP) → the file lands in the vault. A daemon commits every 5 minutes; agents never run git. Topics with no matching scope go to `inbox` with a proposed scope name; only the owner triages (new scope / merge / archive — delete does not exist).

## Read path

- **Packet (push):** a session-start hook injects the distilled scope packet automatically — pinned env-facts first, then decisions/facts/blockers, then a per-agent delta ("what changed while you were away"). Packet content is framed as *data, not instructions*; `untrusted` records never auto-inject.
- **Recall (pull):** `spine-recall` — keyword search with morphology and synonyms over title+summary+keywords+body, with scope/type/date filters.
- **Journal:** a generated chronology answering "what did we do on day X".
- **Obsidian:** the vault is a valid Obsidian vault; wikilinks make the memory a navigable graph.

## Packet distillation

Records pass a promotion gate (status active/blocked, sensitivity normal, confidence reported/verified; pins bypass). Assembly shrinks summaries first (300→200→140 chars), then trims from the largest section while keeping every section alive — the failure mode this prevents is a byte cap silently eating whole sections. Coverage statistics feed a starvation alert (a scope shipping <35% or zero facts).

## Why not a database?

- No SDK required — any agent that reads files and runs shell commands can participate.
- No server to run, nothing to keep alive, no third-party custodian of your data.
- Manual inspection is trivial; search works with standard tools.
- Git gives versioning, audit and backup for free.
- Portable across machines and agent runtimes.

Embeddings were evaluated and rejected on evidence: keyword search with morphology hit 9/10 top-1 on real recall queries, at zero infrastructure cost.
