# Sample Project — Claude Code Entrypoint

This is a minimal project-local harness entrypoint for a Claude Code session.
It demonstrates the pattern described in the ai-config framework's
`playbooks/harness-entrypoints.md`.

## What this file does

When Claude Code opens a session in this project, it reads this file first.
The file's job is to orient Claude to:
1. The framework operating rules (via the compiled `$CLAUDE_CONFIG_DIR`).
2. The project-specific context (this section).

It does **not** duplicate shared framework rules — those live in the framework
repo and are compiled into `$CLAUDE_CONFIG_DIR/CLAUDE.md` by `scripts/install.sh`.

## Framework orientation

The ai-config framework compiler writes a generated entrypoint to
`$CLAUDE_CONFIG_DIR/CLAUDE.md`. That compiled entrypoint is the
steady-state entry point for Claude Code sessions — start there.

The canonical framework source files (`core/`, `playbooks/`, `skills/`, etc.)
live in the ai-config checkout, accessible at `$AI_CONFIG_DIR` (set by
`scripts/bootstrap.sh`). Load those source files from there, not from
`$CLAUDE_CONFIG_DIR`, which holds only the compiled harness output.

The framework's spine capability is `session-agent`. It fires at session start
(Mode 1: orient + route) via the SessionStart hook. At each subsequent
non-trivial prompt, re-invoke `session-agent` (Mode 2: route only) to route
to the smallest useful capability.

## Active-work and durable-knowledge layers

- **Active work:** Linear (or your approved equivalent). The `session-agent`
  capability orients to your Linear workspace at session start.
- **Durable knowledge:** The vault at `$OBSIDIAN_VAULT_PATH` (or your approved
  equivalent). Load `START.md` inside the vault when vault context is relevant.

## Project context

_Replace this section with your project's specific context: what the project
does, its tech stack, any local conventions, and where key files live._

This sample project has no real code — it exists only to illustrate the
harness entrypoint pattern. For a real project, keep this section brief and
link outward to Linear or the vault rather than duplicating details here.

## Ground Rules

- Do not commit `.env`, auth files, local tool config, or machine-specific
  absolute paths to this repository.
- Keep active work in your tracker and durable knowledge in your vault.
- Run `bash scripts/validate.sh` from the ai-config checkout before commits
  (or `pwsh -NoProfile -File scripts/validate.ps1` on Windows).
