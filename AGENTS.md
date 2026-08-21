# Codex Entrypoint

This repository is the AI operating framework. Start with `README.md`, then read only the relevant files from `core/`, `verification/`, `playbooks/`, `skills/`, `linear/`, and `obsidian/`.

Use this file only for Codex-specific notes that do not belong in the shared framework. Do not duplicate shared rules here.

## Active-Work and Durable-Knowledge Layers

The framework references two external layers. Both have a canonical default — Linear for active work, Obsidian-format vault for durable knowledge — but the framework accepts equivalents at either layer.

- **Active-work tracker.** Default and canonical example: **Linear**, with two first-class access surfaces (`linear` CLI or Linear MCP). See [`linear/linear-setup.md`](linear/linear-setup.md) for setup, operating instructions, and the runtime contract — capability bodies are tracker-surface-agnostic, so an operator using Jira, GitHub Projects, or another tracker can adapt the contract documented there. The framework's spine capabilities (session-agent, closeout, self-audit) degrade gracefully when no tracker surface is installed: a one-line warning surfaces the gap and work continues.
- **Durable-knowledge layer.** Default and canonical example: a local **Obsidian-format vault** (a directory of Markdown files — Obsidian.app is not required; any editor that handles `[[wiki-link]]` syntax over plain Markdown works). The path is declared in `local.env` as `OBSIDIAN_VAULT_PATH`. See [`obsidian/vault-guide.md`](obsidian/vault-guide.md) — operators using Notion, Logseq, Bear, or a plain Git-tracked `/notes/` directory can map the §4 + §5 shapes onto their tool of choice.

If you have not connected either layer yet, the framework runs and capabilities still execute — the spine surfaces a one-line note about the missing layer instead of failing closed.

## First-Time Setup Check

If `$CODEX_HOME/skills/closeout/SKILL.md` does not exist, this machine does not have the OS spine installed.

**Fresh clone (no `local.env` yet):** run `bash scripts/bootstrap.sh` first — it seeds `local.env` from `templates/local.env.example`, checks required CLIs (`gh`, `jq`, `rg` universally; `codex` only when `--harness codex` is targeted), and writes the harness configs. `bootstrap.sh` is the canonical fresh-clone entry point. Operator tools (Linear surface, code-intelligence MCP, etc.) are operator-local and advisory — see [`linear/linear-setup.md`](linear/linear-setup.md). The framework ships no tool catalog.

**Existing `local.env` (re-render only):** run

```bash
bash scripts/install.sh --harness claude --harness codex
```

`install.sh` is idempotent (~1 minute; safe to re-run) and requires `local.env` to exist at the repo root — its `local.env`-existence guard `die`s early when the file is absent (run `scripts/bootstrap.sh` first to seed it). Both harnesses install in one pass. After install completes, the compiled `$CODEX_HOME/AGENTS.md` becomes the steady-state entrypoint with full Layer 1 / 2 / 3 orientation.

## Codex-Specific Notes

- Codex uses `AGENTS.md` as its repo instruction entrypoint.
- Shared framework changes require explicit user approval.
- Keep active work in your tracker and durable knowledge in your vault; do not turn this repository into daily logs, project memory, or local machine state.
- Do not add local paths, auth state, plugin caches, generated artifacts, or project history to this repository.
