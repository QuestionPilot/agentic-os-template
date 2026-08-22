---
title: Source of Truth
tags:
  - memory-vault/system
---

# Source of Truth

Use the right layer for the right job.

| Information | Source of truth |
|---|---|
| Agent operating rules, verification standards, tool-use hierarchy | `agentic-os-template` |
| Active work, owners, status, blockers, acceptance criteria, next actions | Linear |
| Durable project memory, decisions, lessons, source summaries | Memory Vault |
| Source code, deploy scripts, product docs that ship with the product | Project repos |
| Local folder orientation for a harness | Root `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, or equivalent |
| Secrets, API keys, auth state, machine-specific config | Local secure config outside Drive |
| Outside memory awaiting review | Original source until promoted through [[00-System/Fresh Start Policy]] |

## Memory Vault Does Not Store

- Secrets or tokens
- Full raw chat transcripts by default
- Active task queues that belong in Linear
- Project source code that belongs in repos
- Generated browser traces, screenshots, logs, or test outputs unless explicitly curated as source material

## Conflict Rule

If a vault note conflicts with current project files, Linear status, or live system evidence, trust the current verified source and update the vault if the correction is durable.

## Wiki Trust Rule

Do not treat wiki notes or raw sources as confirmed truth unless they cite sources and the relevant project or decision note confirms them. Until confirmed, treat a note as a lead to verify, not a fact to rely on.
