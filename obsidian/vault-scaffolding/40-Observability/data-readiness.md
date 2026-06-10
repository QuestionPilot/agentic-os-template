---
title: Data Readiness Observability
tags:
  - memory-vault/observability
  - agentic-os/data-readiness
---

# Data Readiness Observability

Use this note during Dream Review or project closeout to spot where the Agentic OS is blocked by weak data plumbing.

## Track

| Signal | Meaning | Action |
|---|---|---|
| Repeated raw pulls | Agent keeps rereading large sources | Create a silver platter. |
| Missing consumer | Summary exists but nobody acts on it | Pair it with a brief, Linear issue, or decision route. |
| Manual export loop | Human keeps downloading the same data | Consider CLI, connector, script, or automation. |
| Messy source format | PDFs, DOCX, XLSX, EML, screenshots block retrieval | Add conversion workflow before analysis. |
| Boundary risk | Data could cross client, matter, patient, or project lines | Add namespacing and approval gates. |
| Dashboard urge | Visualization requested before source clarity | Build pantry/prep/plate map first. |

## Recommendation Format

- Observation:
- Source evidence:
- Proposed prep artifact:
- Consumer:
- Approval gate:
- Destination: Linear, Memory Vault, `agentic-os-template`, project helper, or no-action
