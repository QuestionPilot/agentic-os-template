---
title: Observability
tags:
  - memory-vault/system
  - agentic-os/observability
---

# Observability

Observability is the Agentic OS feedback layer.

## What To Track

- route usefulness
- skill usage and stale skills
- repeated manual work
- stale memory
- tool health
- cost or token pressure where measurable
- high-leverage recommendations
- Dream Review findings
- data-readiness gaps
- unbounded goal-runs or recurring work without proof artifacts

## Current Implementation

Use file-based notes under [[40-Observability/README]]. Do not build a dashboard until the underlying notes and checks prove useful.

Run [[00-System/Dream Review]] manually before automating it. Use [[00-System/Health Check]] for the executable audit.

Use [[40-Observability/data-readiness]] when repeated work is slowed down by messy sources, missing summaries, unclear consumers, or boundary risk.

## Rule

Recommendations are proposals, not automatic rewrites. A human or primary agent should review before changing SOPs, skills, or durable strategy.
