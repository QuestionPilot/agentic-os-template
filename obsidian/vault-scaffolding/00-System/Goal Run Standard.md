---
title: Goal Run Standard
tags:
  - memory-vault/system
  - agentic-os/goals
---

# Goal Run Standard

Use this standard before any autonomous run, recurring automation, long agent loop, or broad "go improve this" task.

The purpose is to make the agent's work measurable, bounded, and useful before it starts.

## Required Anchors

Every goal-run needs six anchors:

| Anchor | Requirement |
|---|---|
| Noun target | Name the concrete thing being changed or produced. |
| Decision criteria | Define how each item should be judged. |
| State change | Require an output that changes durable state, not just analysis. |
| Proof artifact | Name the evidence the run must leave behind. |
| Stop condition | Define what "done enough" means. |
| Safety cap | Limit time, turns, files, retries, spend, or scope. |

## Routing

- Active follow-up goes to Linear.
- Durable knowledge goes to Memory Vault.
- Operating standards go to `ai-config`.
- Raw source evidence stays in [[20-Raw/sources]] or the source system.

## Before Running

Ask:

- What is the target object?
- What should the agent decide for each item?
- What durable state should change?
- What proof will let a human verify the run?
- Where should the agent stop?
- What safety cap prevents runaway work?

## Closeout

Record the result in the right source of truth. If the run produced a reusable lesson, classify it through [[00-System/Self-Improvement Loop]].
