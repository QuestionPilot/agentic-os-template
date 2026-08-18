# Harness Entrypoints

Use this playbook when installing or refreshing the root instruction file for an AI harness.

## Goal

Make the active harness follow this repository's shared framework without copying project history, local secrets, stale memory, or every local machine rule.

## Entrypoints

- Codex: `AGENTS.md`
- Claude Code: `CLAUDE.md`
- Hermes Agent: `SOUL.md` (the global identity file in the Hermes home /
  profile dir; per-project `CLAUDE.md`/`AGENTS.md`/`SOUL.md` files are auto-discovered
  from the working directory and compose with it)
- Cursor: `AGENTS.md` (discovered from a project root and its nested subdirs;
  the build also renders a global copy in the Cursor config home, and whether
  that user-level copy is auto-loaded is an open item in the Cursor adapter —
  so a project-root `AGENTS.md` pointing at this checkout is the reliable
  channel. Cursor's CLI additionally reads a project-root `CLAUDE.md` as rules,
  so do not restate the same instructions in both files)

These files are front doors into the framework. Keep them thin. Shared operating rules belong in `core/`, proof patterns in `verification/`, workflows in `playbooks/`, and tool guidance in `skills/`.

## Steps

1. Run `scripts/validate.sh`.
2. Pick the root entrypoint for the target harness.
3. Inspect any existing target instruction file before changing it.
4. Back up or version the current target file if it contains useful local rules.
5. Copy or reference the root entrypoint using the harness's normal convention.
6. Keep machine-specific paths, credentials, auth state, plugin caches, and local tool state outside this repository.
7. Keep shared knowledge in framework folders, not in the harness entrypoint. The entrypoint adapts the harness to the framework.
8. Run a harmless startup or help command for the harness if one exists.
9. Re-run `scripts/validate.sh` after any changes to this repository.

## Copy Vs Reference

Prefer a reference when the harness can reliably read this repository directly.
Prefer a copy when the harness expects instructions at a fixed local path.

If copying, keep the copied file thin. It should point back to this repository's shared framework instead of becoming a second source of truth.

## Tool-Specific Boundaries

Harness-specific files may name the harness's local convention, such as `AGENTS.md`, `CLAUDE.md`, `SOUL.md`, `.codex/`, `.claude/`, or local command syntax.

Shared framework files should describe the behavior without depending on one harness's folder shape.

## Closeout

State the entrypoint installed, target harness, target file, validation run, and any local follow-up that belongs outside this repository.
