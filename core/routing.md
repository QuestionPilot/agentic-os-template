# Routing

Use the smallest capable route.

When the task is a fix — a failing test, error, regression, or defect — run `playbooks/root-cause-debugging.md` first: demonstrate the root cause before editing, and escalate per the rules below only after its three-strike stop.

## Agent Roles

- Primary agent: drives the task, integrates findings, verifies the result.
- Secondary agent: reviews, critiques, or handles a bounded independent task.
- Local tools and scripts: provide deterministic proof where possible.

## Escalate When

These escalation criteria are founding.

- the same failure repeats
- the work touches high-risk surfaces
- visual or user-facing quality needs independent judgment
- broad context or another model's perspective is likely to catch real misses
- the user explicitly asks for a second opinion or consensus

## Avoid

These anti-patterns are founding.

- routing just to appear thorough
- giving external agents broad memory access when a compact packet is enough
- treating another model's answer as completion evidence
- changing global rules based on one weak signal
