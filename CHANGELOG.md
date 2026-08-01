# Changelog

## v0.3.0 — 2026-08-01

- Optional per-scope packet byte caps from `config/packet-limits.conf`; missing
  configuration preserves the 14,000-byte default, and malformed entries warn
  by line number without repeating owner-controlled values into logs.
- Packet-starvation classification now combines relative coverage with a
  55-record absolute window while preserving the zero-facts invariant.
- Dedicated packet-limit and health-boundary contracts run in the macOS/Linux
  CI matrix, and the opt-in example is covered by installer verification.
- README, architecture, technical reference, and machine-readable mirrors use
  the same packet-limit and starvation semantics.

## v0.2.1 — 2026-07-31

- Qualified the durability wording across README, technical/whitepaper routes,
  and machine-readable docs; a regression contract rejects the previous
  absolute wording.

## v0.2.0 — 2026-07-31

- Made installation preview-first and explicit with `--apply`, preserving owner
  configuration across upgrades and keeping uninstall reversible.
- Added macOS/Linux CI, isolated selftest and cross-agent verification,
  deterministic exact-ref release archives, immutable action pins, and the
  repository-owned bilingual website plus machine-readable docs.

## v0.1.1 — 2026-07-31

- **`spine-promote`: a confidence NOOP no longer swallows `--reviewed-by-owner`**
  (caught during live use: the early return exited before the reviewed_by
  insertion branch, so the flag was lost silently). When the level is already
  at the target and reviewed_by is absent, the review fields are still set
  with an honest Status-history line; the output distinguishes a full NOOP
  from "confidence unchanged, +reviewed_by: owner". The candidate/legacy
  promotion gate is untouched.
- **Remote dead-letter drain** (`drain_remote_host` in `config/notify.conf`) —
  a machine that must hold no notification secrets relays through another
  machine of yours: its queue is pulled over ssh every sync cycle, crash-safe
  (a stable `.draining` rename, removal only after the local append — interrupted
  transfers are designed to retain a retryable copy, at the cost of duplicates). The README promised
  this pattern; now the code ships it.
- **Inbox state is measured by honest signals only** (docs/AGENT_RULES.md) —
  never by counting files in the inbox directory: no-delete keeps archived
  records in place forever, so file counts raise false "N waiting" alarms.
- Self-test grows to **18** (T16: a promote NOOP keeps reviewed_by — dry-run
  intent, real write, full-NOOP repeat, all verified live on a transient).

Everything below ships as **v0.1.0** — the first tagged point of reference
for installs and forks.

## 2026-07-30 — review round 2 (community feedback, same day)

- **Secret scan moved to stdin** — content is scanned before a single byte
  reaches the vault directory; the previous `.scanning` temp file lived inside
  the vault and a crash could leave plaintext behind.
- **Missing scanner is fail-closed** (mirrors the access gate); `SPINE_NO_SCAN=1`
  is the explicit escape.
- **Bypasses emit distinct best-effort audit events** — with the gate module
  missing, `SPINE_NO_GATE=1` / `SPINE_NO_SCAN=1` attempt their own access-log
  lines (`ALLOW-NOGATE` / `ALLOW-NOSCAN`); filesystem failures can still block logging.
- **Recall language packs** (`config/recall-lang.conf`) — stop words and
  stemming suffixes are configurable per language and merge with the built-in
  English lists; Ukrainian and Russian ship enabled out of the box.
- Self-test grows to **17** (T15: missing-scanner refusal + escape).

## 2026-07-30 — review round 1 (first external review, hours after publishing)

- **`spine-new` now delivers what the README promised**: inline secret scan on
  every write and a real dedup gate (probable-duplicate refusal with
  `--supersedes` / `--allow-duplicate` escapes). The scanner also learned bare
  high-confidence token shapes (GitHub/GitLab/Slack/Anthropic/OpenAI/AWS/
  Google/Matrix/PEM) — a pasted PAT is caught with no keyword context.
- **Consistent custom paths**: every tool honors `SPINE_ROOT` and resolves its
  tools dir from its own location (`SPINE_TOOLS_DIR` to override).
- **Fail-closed access gate**: an unimportable gate refuses instead of warning.
- **Superseded records leave the current view**: the packet drops them with an
  honest `superseded hidden: N` counter; the INDEX labels them `[superseded]`.
- Self-test grows from 13 to **16**.

## 2026-07-30 — initial public release

- Full toolchain (25 CLI tools + the process-ancestry access gate), installer,
  launchd templates, Claude Code hooks, ntfy/Telegram notifications with a
  dead-letter queue, CI (gitleaks full history + selftest on macOS), MIT.
