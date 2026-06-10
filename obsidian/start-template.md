---
title: START
tags:
  - system
  - start
---

# START

This is the kickoff entry point — AI agents read this every session to ground orient. See `$AI_CONFIG_DIR/obsidian/vault-guide.md` §7 for the minimum-contract shape.

## Read Order

Numbered list of `00-System/` notes the agent should consult next, after this file. Operator-curated. Example shape:

1. `[[Memory Core]]` — current operating principle.
2. `[[Source of Truth]]` — canonical source pointers.
3. `[[Linear Handshake]]` — active-project bidirectional links.

## Working Rule

One or two sentences capturing the current operating principle. Mirrors `Memory Core.md` content; restating here is intentional — the agent reads this file first.

Example: "Retrieve the smallest useful slice. Prefer fresh signal over stale memory. Split writes to the layer that owns the fact."

## Linear Boundary

What belongs in Linear vs the vault.

- **Linear owns:** active tasks, status, owner, acceptance criteria, blockers, follow-ups.
- **The vault owns:** durable rationale, decisions, lessons, source-derived summaries.

For each active Linear project, mirror it with a handshake note under `01-Projects/<project>/` using `handshake-template.md`. The vault note's `linear:` frontmatter is a stale-by-design pointer — Linear is queried for current state.

## Closeout

Before writing durable memory at session end, classify each lesson via the canonical 11-class taxonomy from `core/self-improvement.md` (`rule`, `check`, `script`, `linear`, `obsidian`, `playbook`, `skill`, `data-readiness`, `goal-run`, `no-action`, `state-delta`). The class names the destination — only `obsidian`-class lessons land here.

The AI proposes notes; the operator commits. Direct AI writes to the vault are off-policy.

## Health Check

Operator-defined audit. Suggested form: a one-line bash command the operator can run to confirm vault sync + structural integrity. Example placeholders:

```bash
# Confirm START.md is reachable and the 13 top-level folders exist.
ls "$OBSIDIAN_VAULT_PATH/START.md" && \
  ls -d "$OBSIDIAN_VAULT_PATH"/{00-System,01-Projects,02-Areas,03-Decisions,04-Lessons,10-Wiki,20-Raw,30-Archive,40-Observability,50-Outputs,80-Templates,90-Indexes,95-Views}
```

Replace with whatever audit your storage provider + vault layout warrants.
