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

Every goal-run needs seven anchors:

| Anchor | Requirement |
|---|---|
| Noun target | Name the concrete thing being changed or produced. |
| Decision criteria | Define how each item should be judged — prefer an objective, machine-checkable rule. |
| State change | Require an output that changes durable state, not just analysis. |
| Proof artifact | Name the evidence the run must leave behind. |
| Stop condition | Define what "done enough" means, as a checkable predicate (not "until satisfied"). |
| Safety cap | Limit time, turns, files, retries, spend, or scope — a separate failure predicate from the done check. |
| Input provenance | For autonomous runs: declare which material decision inputs the agent supplied on the absent operator's behalf, and carry that declaration into the proof artifact — a self-written brief must be stamped self-authored, not interviewed. |

## Make the checks real

Two anchors above quietly decide whether a loop works:

- **Stop condition = a checkable predicate, not a mood.** "Iterate until X metric >= Y" beats "until it's good" — a subjective done-check lets a run stop early or never. When the work is inherently subjective, make the check as objective as you can (a rubric a second agent scores, a screenshot diff), not an implicit "until satisfied".
- **Safety cap = a separate *failure* predicate, checked every iteration.** It bounds the run when "done" is never reached. In a single-agent prompt a cap is advisory — a stuck agent often runs past it; for a hard ceiling that halts regardless of the agent's self-assessment (plus a per-iteration trace), run under a runtime harness that enforces iteration limits, not a prose instruction.

## Routing

- Active follow-up goes to Linear.
- Durable knowledge goes to Memory Vault.
- Operating standards go to `agentic-os-template`.
- Raw source evidence stays in [[20-Raw/sources]] or the source system.

## Before Running

Ask:

- What is the target object?
- What should the agent decide for each item?
- What durable state should change?
- What proof will let a human verify the run?
- Where should the agent stop?
- What safety cap prevents runaway work?
- For autonomous runs: which decision inputs will the agent supply itself, and where is that declared?

## Closeout

Record the result in the right source of truth. If the run produced a reusable lesson, classify it through [[00-System/Self-Improvement Loop]].
