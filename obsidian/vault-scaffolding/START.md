---
title: START
tags:
  - memory-vault/start
  - agentic-os
---

# START

Read this first when using Memory Vault.

## Read Order

1. [[README]]
2. [[00-System/Memory Core]]
3. [[00-System/Source of Truth]]
4. [[00-System/Retrieval Routes]]
5. [[00-System/Fresh Start Policy]] when outside content is involved
6. [[00-System/Data Readiness]] when the work depends on raw files, exports, APIs, transcripts, or repeated briefs
7. [[00-System/Goal Run Standard]] before autonomous runs, recurring automations, or broad improvement loops
8. Relevant note under [[01-Projects/README|Projects]], [[02-Areas/README|Areas]], [[03-Decisions/_index|Decisions]], [[04-Lessons/_index|Lessons]], [[10-Wiki/index|Wiki]], or [[20-Raw/sources|Raw Sources]]

## Working Rule

Retrieve the smallest useful slice. Do not load the whole vault by default.

## Linear Boundary

Linear is the day-to-day active-work layer for status, blockers, acceptance criteria, ownership, and next actions. Memory Vault stores the durable context behind that work.

Linear setup is intentionally deferred. Until then, notes may include a `linear:` placeholder, but do not invent issue IDs.

## Closeout

Before writing durable memory, classify the event through [[00-System/Self-Improvement Loop]]. If it does not change future behavior, preserve project state, or create reusable knowledge, do not write it.

Before automating or routing repeated work, define the goal anchors in [[00-System/Goal Run Standard]] and confirm the pantry/prep/plate path in [[00-System/Data Readiness]].

## Health Check

For meaningful vault changes, run:

```bash
node bin/memory-vault-audit.js
```

For a broad question with no obvious route, `bin/vault-search.sh <query>` is the deterministic full-text baseline; `bin/retrieval-evals.sh` checks it still retrieves. See [[00-System/Health Check]].
