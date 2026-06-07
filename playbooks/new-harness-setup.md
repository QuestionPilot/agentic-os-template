# New Harness Setup

Use this when a new AI app, coding agent, or fresh instance needs to use this operating framework.

## Goal

Make the agent productive without importing stale project history, local secrets, or machine-specific assumptions.

## Checklist

1. Read the active harness entrypoint, such as `AGENTS.md` or `CLAUDE.md`.
2. Read `README.md`, then only the relevant `core/`, `skills/`, `verification/`, and `playbooks/` files.
3. Configure Linear, or the approved equivalent, as the active-work layer.
4. Configure Obsidian, or an approved equivalent, as the durable-knowledge layer.
5. Confirm the agent understands the source-of-truth split in `core/memory-model.md`.
6. Run the framework compiler for the chosen harness: `bash scripts/install.sh --harness <h>` on POSIX or `pwsh scripts/install.ps1 -Harness <h>` on Windows. The compiler installs only those capabilities whose `capabilities/<name>.md` header explicitly lists the chosen harness in its `harnesses:` field — that header is authoritative. The 3 native spine capabilities (`session-agent`, `closeout`, `self-audit`) ship to every harness adapter. The framework authors no vendored capabilities — framework-shipped skills are restricted to the spine; tool and app skills are operator-managed Shape C, kept in the operator's harness config rather than the framework.
7. Confirm the build produced the expected skill files and hook wiring under the harness's config dir (the directory named by the target env var in `local.env` — `CLAUDE_CONFIG_DIR` for Claude, `CODEX_HOME` for Codex). The drift gate `scripts/check-drift.sh --manifest` detects hand-edits to compiled output.
8. To extend the framework, write `capabilities/<name>.md` plus the per-harness realization at `harnesses/<h>/capabilities/<name>.md`, then re-run the compiler — do not hand-edit files in the harness config dir.
9. Add project-local entrypoints from `templates/` only inside target project folders.
10. Run the framework validation script and any relevant smoke test from the installed skill notes.

## External Tools

The compiler ships every capability whose `harnesses:` header lists the chosen harness — currently only the native spine capabilities. All other tools — cross-model review, web research, docs lookups, browser proof — are operator-local Shape C skills, kept in the operator's harness config rather than the framework. Configure these external tools separately, as needed:

- Active work: Linear, or an approved equivalent.
- Durable knowledge: Obsidian, or an approved equivalent.
- Current external docs: an operator-installed docs tool (CLI or MCP).
- Browser proof: an operator-installed browser/rendering tool (CLI or MCP).
- Other platform-specific tools (databases, payments, deploys, source control, etc.) — install only when that surface is active.

## Smoke Test

- Framework validation passes.
- The selected harness entrypoint points back to this repo.
- Linear and durable vault responsibilities are separate and documented for the harness.
- The chosen harness loads the compiled skill files at session start (e.g. the framework's session-start surface directs invocation of the `session-agent` capability for Mode 1 orient).
- No local paths, secrets, plugin caches, raw transcripts, or project history were added to this repo.

## Closeout

State which harness was configured, which capabilities were compiled (and any that intentionally remain off-harness), which external tools were connected, what validation passed, and what remains manual or unsupported.
