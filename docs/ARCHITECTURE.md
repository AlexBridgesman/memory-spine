# Architecture

Memory Spine is a file-based memory layer shared by CLI agents that explicitly integrate with the same local vault.

## Components

1. **Memory vault** — `~/AgentMemory`: Markdown records, one file per record, append-oriented by protocol.
2. **CLI tools** — `~/dev/memory-spine/bin`: the only sanctioned interface to the vault.
3. **Access gate** — `lib/spine_gate.py`: a process-ancestry guardrail consulted by Spine read/write tools; it has documented fail-open branches and is not a filesystem sandbox.
4. **Generated views** — per-scope `INDEX.md`, a distilled `_index/packet-<scope>.md` (14,000-byte default with optional per-scope caps), and a 30-day `_index/journal.md`.
5. **Optional scheduled jobs** (launchd templates on macOS; user-configured cron/systemd on Linux) — `spine-sync`, `spine-backup`, `spine-digest`, and `spine-health`.
6. **Optional notifications** — `spine-notify` can use Telegram or a local banner; failed deliveries can remain in a local dead-letter queue for retry.

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

`spine-new` is the single entry point: schema validation → per-file secret scan → dedup write-gate (search first, then ADD / SUPERSEDE / NOOP) → the file lands in the vault. When the owner configures scheduling, `spine-sync` commits on that schedule; agents should not run git directly. Topics with no matching scope go to `inbox` with a proposed scope name; only the owner triages (new scope / merge / archive — delete does not exist).

## Read path

- **Packet:** a configured Claude Code hook can inject the distilled scope packet; other runtimes call `spine-packet` explicitly. `untrusted` records are excluded.
- **Recall (pull):** `spine-recall` — keyword search with morphology and synonyms over title+summary+keywords+body, with scope/type/date filters.
- **Journal:** a generated chronology answering "what did we do on day X".
- **Obsidian:** the vault is a valid Obsidian vault; wikilinks make the memory a navigable graph.

## Packet distillation

Records pass a promotion gate (status active/blocked, sensitivity normal, confidence reported/verified; pins bypass). Assembly shrinks summaries first (300→200→140 chars), then trims from the largest section while keeping every section alive — the failure mode this prevents is a byte cap silently eating whole sections. Optional per-scope packet caps are read from config/packet-limits.conf; unlisted scopes keep the 14,000-byte default, and configured values below 4,000 bytes are clamped. Copy config/packet-limits.conf.example to that path to opt in. For scopes with at least 20 eligible records, packet starvation requires both coverage below 35% and fewer than 55 shipped records; shipping zero facts always alerts.

## Why not a database?

- No SDK required — shell-capable agents can participate after explicit integration.
- The core requires no database or hosted memory service; optional local schedulers still need configuration.
- Manual inspection is trivial; search works with standard tools.
- Git gives local versioning and audit; backup is separate and must be verified.
- The installer and core selftest run in a macOS + Linux CI matrix.

The public synthetic recall regression set currently reports 12/12 top-1 for
its own fixture. It documents current behavior; it is not an independent
comparison with embeddings or external workloads.
