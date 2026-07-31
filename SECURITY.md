# Security model

A memory system becomes the most sensitive thing on your machine the moment agents actually use it. Memory Spine layers several defenses; know what each one does and does not cover.

## Threat model, honestly

| Layer | Catches | Does NOT catch |
|---|---|---|
| Access gate (`lib/spine_gate.py`) | Identified runtimes and apps that launch Spine tools while absent from the configured allowlist | Direct filesystem reads, allowlist-file modification, or any process with equivalent OS permissions |
| Secret-reference policy | Reduces impact when users and agents keep only a secret's name and location | Violations of the policy or scanner misses |
| Per-record secret scan + pre-commit gitleaks + CI full-history scan | Many common accidental secret patterns entering records or history | Unknown patterns, secrets outside the vault, or a guarantee of absence |
| `untrusted` confidence + "data, not instructions" packet framing | Reduces automatic exposure of untrusted records through generated packets | Prompt injection in other channels or direct reads |

Rule #1 is the real last line of defense. The gate raises the bar; it is not a sandbox.

## The access gate

- **Default-deny for identified callers** by process-ancestry chain; the allowlist is intended to be owner-managed through `spine-approve`.
- `spine-approve` is a policy tool, not an operating-system authentication boundary. Protect the tools/config directory with filesystem permissions.
- Spine-mediated access decisions are logged; configured notifications can alert the owner about refusals.
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

The installer creates a local git repo and, by default, a local bare mirror. It does not configure a network remote. If you add one, do it deliberately after scanning.

## Reporting

For suspected privacy/security exposure, use a private repository security advisory and redact local paths, identities, and secret-shaped values. Use a public issue only for a sanitized generic report.
