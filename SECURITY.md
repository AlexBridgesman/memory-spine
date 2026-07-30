# Security model

A memory system becomes the most sensitive thing on your machine the moment agents actually use it. Memory Spine layers several defenses; know what each one does and does not cover.

## Threat model, honestly

| Layer | Catches | Does NOT catch |
|---|---|---|
| Access gate (`lib/spine_gate.py`) | Agent runtimes and apps that *launch spine tools* without the owner's approval — the realistic vector for LLM agents (a real incident: a third-party desktop app picked up a global agent profile and read the memory packet) | A raw `cat ~/AgentMemory/...` by any process — the vault stays a plain folder |
| Rule #1: secrets never as values | A leaked memory file exposes only *where* a secret lives, never the secret | — |
| Per-record secret scan + pre-commit gitleaks + CI full-history scan | Accidental secret values entering records or history | Secrets outside the vault |
| `untrusted` confidence + "data, not instructions" packet framing | Prompt-injection via memory: external content never auto-injects | Injection in channels outside Memory Spine |

Rule #1 is the real last line of defense. The gate raises the bar; it is not a sandbox.

## The access gate

- **Default-deny** by process-ancestry chain; the allowlist is edited only by the owner (`spine-approve`).
- Every access — allowed or denied — is logged; refusals alert the owner with a ready-to-paste approve command.
- Never add `launchd` (or your init system) to the allowlist: it is the ancestor of every process and admits everyone. A unit test guards this.
- Sandboxed agents that cannot run `ps` are identified via `proc_pidpath`; if identification is impossible, the gate allows **loudly** (audit entry + alert) rather than silently breaking legitimate agents — a deliberate, documented trade-off you can flip.

## Never store secret values

Do not write: API keys, OAuth tokens, passwords, private keys, session cookies, connection strings, seed phrases, webhook secrets.

Write only references: "credential exists in password-manager item X", "token in keychain service Y", "deployment reads env var Z".

## Before sharing anything from a used vault

An installed vault fills with real decisions, business facts, internal paths and private names. Treat it as private unless deliberately sanitized:

1. Export only selected records; replace names, domains, paths with synthetic examples.
2. Run the secret scanner over the export, plus `gitleaks` with full history if it is a git repo.
3. Grep for your own organization-specific names (keep your deny-list *outside* the public copy).
4. Review manually before publishing.

## Git remotes

The installer creates a local git repo only and configures no remote. If you add one, do it deliberately, after scanning — local-first is the safe default.

## Reporting

Found a vulnerability in the tools themselves? Open a GitHub issue (or a private security advisory on the repository) with reproduction steps.
