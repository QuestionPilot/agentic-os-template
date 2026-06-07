# Examples

This directory contains a minimal sample project that demonstrates the ai-config
operating framework end-to-end.

## Contents

| Path | Purpose |
| --- | --- |
| `sample-project/` | A minimal Claude Code project wired to the framework spine. |
| `sample-project/CLAUDE.md` | Project-local harness entrypoint pointing back to the framework. |
| `sample-project/local.env.example` | Placeholder `local.env` for the sample project build. |

## How to run

The sample project is intentionally minimal — it is a reading exercise, not an
install target. Use it to understand the harness entrypoint pattern before
configuring your own project.

1. Read `sample-project/CLAUDE.md` to see how a project-local entrypoint
   references the framework and wires the `session-agent` spine capability.
2. Copy `sample-project/local.env.example` to `local.env` in your own project
   root, fill in the placeholder values, then run the framework bootstrap:

   ```bash
   bash /path/to/ai-config/scripts/bootstrap.sh
   ```

3. Once bootstrap completes, open a Claude Code session in your project. The
   `session-agent` capability fires at session start (Mode 1 orient), loads
   your Linear and vault layers, and routes your first prompt.

## What the sample project shows

- **Harness entrypoint pattern.** `CLAUDE.md` in the project root is a thin
  pointer — it does not duplicate shared framework rules.
- **`session-agent` wiring.** The session-start hook directs `session-agent`
  invocation. This orients the AI to your Linear tracker and durable vault,
  then routes your first prompt to the smallest useful capability.
- **`local.env` shape.** The two required keys: `CLAUDE_CONFIG_DIR` (where the
  compiler writes the built config) and `OBSIDIAN_VAULT_PATH` (your durable
  knowledge layer). All other keys are optional.

## Next steps

- For the full install and bootstrap flow, see the Quickstart section in the
  repository `README.md`.
- For active-work tracker setup, see `linear/linear-setup.md`.
- For durable-knowledge vault setup, see `obsidian/vault-guide.md`.
- The framework ships only the spine capabilities (see `skills/registry.md`); tool and app skills are operator-local.
