# llm_translate

An LLM-powered translation pipeline that produces ARB files for Flutter `gen-l10n`. Works with any OpenAI-compatible endpoint (OpenAI, LM Studio, Ollama, local models, etc.).

## Features

- Reads `trconfig.yaml` + `l10n.yaml` for config
- Multi-layered configuration strategy (CLI flags > `.env` files / Environment variables > `trconfig.yaml`)
- Automatic `.env` loading from working directory, parent folders up to git root, and `~/.env` / `~/.config/llm_translate/.env`
- Parses `strings.yaml` with `{{@:path}}` reference resolution
- Detects changed/new keys via git diff against HEAD (Git is source of truth)
- Batches English + one target locale per LLM call
- Generates ARB files with correct `@key` metadata for gen-l10n
- `--force` flag for full retranslation
- `--verify` flag for second-pass QA
- `fixed:` group keys skipped from ARB (for `Fixed.current` → strings.yaml migration)
- Error recovery: partial results saved, re-run picks up gaps

## Installation

Install `llmt` globally to use across any Flutter project:

```bash
# Global activation via Git HTTPS
dart pub global activate --source git https://github.com/Navideck/llm_translate.git

# Or via SSH
dart pub global activate --source git git@github.com:Navideck/llm_translate.git
```

Ensure `~/.pub-cache/bin` is in your `PATH` so you can run `llmt` directly, or invoke with `dart pub global run llmt`.

## Git as Source of Truth (Diff Mode)

Git is the **source of truth** for detecting changed translation keys:
- By default, `llm_translate` compares `strings.yaml` against `HEAD` in git (`git diff`).
- Only keys modified or added since the last git commit are translated.
- If no uncommitted changes exist in `strings.yaml`, `llm_translate` outputs: `No changes detected. Use --force to force re-translate.`
- Use `--force` to bypass git diff checks and retranslate existing keys (e.g. `dart run llmt --force --only plist`).

## Usage

```bash
# Show help and available options
llmt --help

# Diff mode — translate changed keys using trconfig.yaml or env defaults
llmt
# or (if installed in project)
dart run llmt

# Specify custom config
dart run llmt --config btcam/trconfig.yaml

# Full retranslate
dart run llmt --force --config btcam/trconfig.yaml

# Full retranslate + verify pass
dart run llmt --force --verify --config btcam/trconfig.yaml

# Override model and endpoint via CLI flags
dart run llmt --endpoint http://localhost:8000/v1 --model llama3.2

# Target only a specific top-level YAML subtree
dart run llmt --only paywallOfferings
dart run llmt --force --only paywallOfferings --config btcam/trconfig.yaml
```

## Configuration & Sharing Strategy

`llm_translate` resolves parameters (endpoint, model, verify_model, api_key) using a 3-tier precedence order:

1. **CLI Flags**: `--endpoint`, `--model`, `--verify-model`, `--api-key`, `--env-file`, `--header "key: value"`
2. **Environment Variables / `.env` files**:
   - `LLM_TRANSLATE_ENDPOINT` (fallback `LLM_ENDPOINT`)
   - `LLM_TRANSLATE_MODEL` (fallback `LLM_MODEL`)
   - `LLM_TRANSLATE_VERIFY_MODEL` (fallback `LLM_VERIFY_MODEL`)
   - `LLM_TRANSLATE_API_KEY`
   - `LLM_TRANSLATE_HEADERS` (JSON map or key:value pairs; supports `{session_id}` / `{uuid}` macros)
3. **Project `trconfig.yaml`**: `llm:` block

### Example `.env` (machine / user specific)

Place in project root, user home directory (`~/.env`), or `~/.config/llm_translate/.env`:

```env
LLM_TRANSLATE_ENDPOINT=https://opencode.ai/zen/go/v1
LLM_TRANSLATE_MODEL=deepseek-v4-flash
LLM_TRANSLATE_VERIFY_MODEL=deepseek-v4-flash
LLM_TRANSLATE_API_KEY=YOUR_API_KEY
LLM_TRANSLATE_HEADERS={"x-opencode-session": "{session_id}"}
```

> **Tip:** Any header containing `{session_id}` or `{uuid}` is automatically populated with a stable run UUID.

### OpenCode Auto-Discovery

When using the OpenCode endpoint (`https://opencode.ai/zen/go/v1`), `llmt` automatically checks `~/.local/share/opencode/auth.json` for the `opencode-go` API key if `LLM_TRANSLATE_API_KEY` is not explicitly set in your CLI flags or `.env` files.

### Example `trconfig.yaml` (project level)

```yaml
entry_file: strings/strings.yaml
locales:
  - en
  - de
  - el

llm:
  endpoint: http://localhost:8000/v1
  model: Hy-MT2-7B-oQ4
  headers:
    x-custom-tracking: "{session_id}"
```

