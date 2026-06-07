# Goal Run

Use this playbook before autonomous work, recurring automations, broad improvement loops, or agent runs that may continue beyond one short interaction.

## Goal Anchors

Every goal-run needs six anchors.

| Anchor | Requirement |
| --- | --- |
| Noun target | Name the concrete thing being changed or produced. |
| Decision criteria | Define how each item should be judged. |
| State change | Require an output that changes durable state. |
| Proof artifact | Name the evidence the run must leave behind. |
| Stop condition | Define what done enough means. |
| Safety cap | Limit time, turns, files, retries, spend, or scope. |

## Steps

1. State the target.
2. State the criteria.
3. State the durable side effect.
4. State the proof artifact.
5. State the stop condition.
6. State the safety cap.
7. Route the result to the right source of truth.

## Routing

- Active tasks and status go to Linear.
- Durable knowledge goes to Obsidian.
- Framework behavior goes to `core/`, `playbooks/`, `verification/`, or `skills/`.
- Harness-specific behavior goes to `AGENTS.md`, `CLAUDE.md`, or another harness entrypoint.

## Closeout

Do not call the run complete without the proof artifact and a source-of-truth decision.

