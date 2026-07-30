# Changelog

## 2026-07-30 — review round 2 (community feedback, same day)

- **Secret scan moved to stdin** — content is scanned before a single byte
  reaches the vault directory; the previous `.scanning` temp file lived inside
  the vault and a crash could leave plaintext behind.
- **Missing scanner is fail-closed** (mirrors the access gate); `SPINE_NO_SCAN=1`
  is the explicit escape.
- **Bypasses are always audited** — with the gate module missing,
  `SPINE_NO_GATE=1` / `SPINE_NO_SCAN=1` write their own access-log lines
  (`ALLOW-NOGATE` / `ALLOW-NOSCAN`).
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
