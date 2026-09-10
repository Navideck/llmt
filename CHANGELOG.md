## 0.1.0

- Initial release.
- LLM-powered translation pipeline producing ARB files for Flutter `gen-l10n`.
- Works with any OpenAI-compatible endpoint (OpenAI, LM Studio, Ollama, local models).
- Multi-layered configuration (CLI flags > env/.env files > `trconfig.yaml`).
- Git diff based detection of changed/new translation keys.
- `--force` full retranslation and `--verify` QA pass.