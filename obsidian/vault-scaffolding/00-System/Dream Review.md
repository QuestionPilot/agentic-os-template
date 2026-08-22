---
title: Dream Review
tags:
  - memory-vault/system
  - agentic-os/dream-review
---

# Dream Review

Dream Review is the self-improvement pass for the Agentic OS.

It is inspired by the "dreaming" pattern: periodically look across recent work and suggest high-leverage improvements. Start manual and evidence-based before automating.

## Cadence

On-demand, entered through the closeout / [[00-System/Wrap-Up Workflow|wrap-up]] pass. Trigger it when a closeout surfaces systemic-drift signals — repeated manual work, stale or conflicting memory, tool or routing drift — or whenever the operator asks for it directly.

Run [[00-System/Health Check]] as part of the review.

## Inputs

**Primary — live sources** (read these first; on a fresh vault some will be thin — use what exists):

- Recent Linear issues and project status
- The harness memory store (the autoloaded index plus recently written notes)
- Recent commits in the operating-framework repo (`agentic-os-template`)
- The Health Check output
- Recent Memory Vault decisions, lessons, project notes, and source ingests

**Optional — the `40-Observability` tables, only when populated:**

- [[40-Observability/repeated-work]] · [[40-Observability/stale-memory]] · [[40-Observability/skills]] · [[40-Observability/tool-health]] · [[40-Observability/routes]] · [[40-Observability/recommendations]]

These tables are fed opportunistically by the lint and wrap-up workflows, not by every session. An empty table is expected and is not a blocker — Dream Review runs off the primary live sources above.

## Review Dimensions

1. Repeated manual work that should become a playbook, script, automation, or skill.
2. Stale or conflicting memory.
3. Missing Linear follow-ups.
4. Tool or skill drift.
5. High-cost or low-yield routing patterns.
6. Source gaps in the wiki.
7. Decisions that need review.
8. Project manuals that are missing or stale.

## Output

Write findings to [[40-Observability/dream-reviews]] and promote each recommendation to exactly one destination:

- Linear task
- Memory Vault note
- `agentic-os-template` SOP change
- project manual update
- script/check
- no action

## Rule

Dream Review proposes. It does not silently rewrite strategy, skills, SOPs, or project state.
