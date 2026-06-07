---
title: Health Check
tags:
  - memory-vault/system
  - memory-vault/audit
---

# Health Check

Use the Memory Vault audit before calling meaningful memory-system work complete and during Dream Review.

## Command

```bash
node bin/memory-vault-audit.js
```

## What It Checks

- broken wikilinks
- markdown frontmatter and `.base` YAML
- likely secret patterns
- disposable artifacts
- raw inbox files missing from [[20-Raw/sources]]
- wiki notes missing source references
- decisions and lessons missing from indexes
- active-task markers buried outside Linear
- required data-readiness and goal-run notes

## Rule

Warnings are not always blockers, but they must be adjudicated. A clean audit is evidence; it is not a substitute for judgment.

For work that changes recurring runs, automations, or data flows, also verify the relevant [[00-System/Goal Run Standard]] anchors and [[00-System/Data Readiness]] pantry/prep/plate path manually.
