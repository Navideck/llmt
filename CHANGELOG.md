## 0.1.1

- Fix: keys removed from `strings.yaml` are now detected and pruned from every ARB file (values plus `@key` metadata). Previously a deletion-only diff returned "No changes detected" and left stale keys behind, because the early-exit ran before the deletion pass.
- ARB files are reconciled against `strings.yaml` on every run, so removals committed earlier (invisible to the HEAD diff) are cleaned too.
- `--force` runs prune stale keys as well.
- `--only <subtree>` now scopes pruning correctly (matching ARB camelCase keys, not dot keys).
- `git diff` is read once per run (`diffAgainstHead` returns changed + deleted keys); `fixed.*` keys no longer count as deletions.
- Deletion-only runs make no LLM calls.

## 0.1.0

- Initial release.
- LLM-powered translation pipeline producing ARB files for Flutter `gen-l10n`.
- Works with any OpenAI-compatible endpoint (OpenAI, LM Studio, Ollama, local models).
- Multi-layered configuration (CLI flags > env/.env files > `trconfig.yaml`).
- Git diff based detection of changed/new translation keys.
- `--force` full retranslation and `--verify` QA pass.
