# AgentMemory contract

This directory is the canonical local memory vault for AI agents.

## Read order

When using memory for a project:

1. Read this file.
2. Read `<project>/INDEX.md`.
3. Search `<project>/` for relevant records.
4. Read source records before relying on details.

## Write rules

1. Create records only with `spine-new`.
2. Search for duplicates first.
3. Do not store secret values.
4. Do not manually edit generated `INDEX.md` or `_index/packet-*.md`.
5. Do not delete or rewrite historical records. Correct them with a new record and `supersedes:`.
6. Commit through `spine-sync`.
7. Keep remotes optional; local-only is the default.

## Record types

- `decision`: durable choice and consequence.
- `fact`: verified durable statement.
- `thread`: open coordination, handoff, blocker, or follow-up.
- `artifact`: pointer to a larger file or external object.

## Required record frontmatter

```yaml
---
type: fact
project: personal
agent: user
title: "Short searchable title"
status: active
created: 2026-01-01T00:00:00Z
sources:
  - manual:example
sensitivity: normal
confidence: candidate
---
```

Allowed `status` values:

- `active`
- `blocked`
- `resolved`
- `superseded`
- `archived`

Allowed `sensitivity` values:

- `normal`
- `private`
- `local_only`

Allowed `confidence` values:

- `candidate`
- `reported`
- `verified`
- `legacy`
- `untrusted`

Each record body should include at least one wikilink, usually `[[<project>]]`.

## Secret handling

Never store secret values. Store only locations, for example:

- “Credential is in the password manager item named `<item>`.”
- “Token is available through environment variable `<NAME>`.”
- “Private key is stored in the local keychain service `<service>`.”
