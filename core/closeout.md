# Closeout

Every meaningful workstream should end with a clear closeout.

## Required Closeout

The canonical output-block schema — section names, order, and per-section
content — lives in `linear/closeout-format.md`; the `closeout` capability
emits it. The block must cover:

- result (`## Result`)
- files or systems changed (`## State Deltas` + `## Files created this session`)
- verification performed and the independent review decision (`## Verification`)
- residual risk (`## Residual Risk`)
- self-improvement classification (`## Lessons`)

## Self-Improvement Closeout

Use exactly one classification for each meaningful lesson:

- `rule`
- `check`
- `script`
- `linear`
- `obsidian`
- `playbook`
- `skill`
- `data-readiness`
- `goal-run`
- `no-action`
- `state-delta`

Do not write durable memory for every interaction. Write only when the lesson changes future behavior or preserves useful knowledge.

## Repository Boundary

This repository defines the closeout standard. It is not the place to record ordinary closeout notes, daily logs, active status, or project history.

- Put active follow-ups and acceptance state in your active-work tracker (Linear is the canonical example).
- Put durable lessons, decisions, and project memory in your durable vault (an Obsidian-format vault is the canonical example).
- Update this repository only when the standard operating procedure itself changes.
