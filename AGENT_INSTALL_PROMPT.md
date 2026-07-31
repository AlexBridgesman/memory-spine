# Prompt for any agent

Copy this prompt into Claude, Codex, Hermes, Cursor, Aider, or another shell-capable coding agent while the current directory is this repository.

```text
You are installing a local-first Agent Memory Spine template.

Goal: create a working local memory vault and CLI tools. Do not push anything to GitHub or any remote. Do not add cloud services. Do not store secrets.

Steps:
1. Read README.md, SECURITY.md, and templates/AgentMemory/README.md.
2. Run:
   ./install.sh --yes
3. If the user wants different project names, rerun install with:
   ./install.sh --yes --projects "personal,work,ai-infra,research"
4. Verify the install with real commands:
   ~/dev/memory-spine/bin/spine-health
   ~/dev/memory-spine/bin/spine-selftest
5. Create one safe test record only if the user approves. Use non-secret synthetic text.
6. Run ~/dev/memory-spine/bin/spine-sync and report whether the local git commit succeeded.
7. Report exact paths created and any blockers.

After the self-test passes, wire the OWNER'S CHANNEL — memory that cannot
reach its owner is a diary nobody reads (see "The owner's channel" in
README.md): copy config/notify.conf.example to config/notify.conf, ask the
owner whether they prefer Telegram (chat_id + a token_cmd reading their
secret manager) or ntfy (a long random topic, no bot), then prove delivery
with `spine-notify "Memory Spine is installed and can reach you"`.

Rules:
- Do not push.
- Do not configure a remote.
- Do not copy private project data into AgentMemory.
- Do not paste secret values into memory.
- Never write a token value into any file — token_cmd only.
- Prefer concrete verification output over explanations.
```
