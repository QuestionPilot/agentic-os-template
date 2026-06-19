---
title: Project Manual Standard
tags:
  - memory-vault/system
  - agentic-os/project-manual
---

# Project Manual Standard

Project manuals are thin local files placed in meaningful folders so agents enter a project already briefed.

Use `AGENTS.md`, `CLAUDE.md`, or another harness entrypoint as needed.

## Purpose

A project manual should say:

- what this folder is
- why it exists
- what done looks like
- what stack and commands matter
- what decisions are already made
- where memory, Linear, repo, deploy, and docs live
- any folder-specific overrides

## Rules

- Keep it under 200 lines.
- One per meaningful folder, not automatically one per repo.
- Do not store secrets.
- Do not duplicate the whole Memory Vault.
- Link back to the relevant Memory project note.
- Use the closest manual to the files being changed.
- Update the date when materially changed.

## Template

Use [[80-Templates/project-manual]].
