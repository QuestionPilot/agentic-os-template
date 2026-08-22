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

Two instruments the audit calls, also runnable on their own:

```bash
bin/retrieval-evals.sh                  # measure search against [[00-System/Retrieval Fixtures]]
node bin/generate-session-index.js      # rebuild [[90-Indexes/Session Index]] from the session archive
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
- retrieval-fixture pointers still resolving, and the fixture set still carrying negative controls
- the generated [[90-Indexes/Session Index]] matching regeneration

Checks that target an optional artifact report `N/A` rather than passing. A fresh vault has not created everything yet, and an instrument that did not run must say so instead of reading as clean.

## Rule

Warnings are not always blockers, but they must be adjudicated. A clean audit is evidence; it is not a substitute for judgment.

For work that changes recurring runs, automations, or data flows, also verify the relevant [[00-System/Goal Run Standard]] anchors and [[00-System/Data Readiness]] pantry/prep/plate path manually.
