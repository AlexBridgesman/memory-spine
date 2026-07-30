# AgentMemory runbook

## If validation fails

1. Read the error from `spine-validate` or `spine-sync`.
2. Fix only the newly created record if it has not been committed yet.
3. If a committed record is wrong, create a new record with `supersedes:` instead of rewriting history.

## If a secret was added before commit

1. Do not commit.
2. Remove the secret value from the new record.
3. Rotate the secret if it may have been exposed to logs or other tools.
4. Run `spine-secrets-lint` on the affected record and optional `gitleaks` again.

## If a secret was committed

1. Stop sharing the repository.
2. Rotate the secret first.
3. Rewrite git history only after rotation.
4. Rebuild any backups or exports that may contain the old value.

## If sync fails

1. Run `spine-health`.
2. Check `git -C ~/AgentMemory status --short --branch`.
3. Run `spine-gen` to regenerate indexes.
4. Run `spine-preflight`.
5. Run `spine-sync` again.

## If an agent cannot use the CLI

Ask it to return a proposed memory record as text. A trusted top-level agent or human can then create the record with `spine-new`.
