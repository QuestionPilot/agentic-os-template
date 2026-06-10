---
title: Memory Core
tags:
  - memory-vault/system
  - agentic-os/memory
---

# Memory Core

Memory Vault is the file-first Memory Core for the Agentic OS.

## Layers

| Layer | Job | Location |
|---|---|---|
| Operating framework | Harness-neutral SOPs and verification standards | `agentic-os-template` |
| Active execution | Current tasks, status, blockers, acceptance criteria | Linear |
| Durable memory | Projects, areas, decisions, lessons, archive summaries | Memory Vault |
| Source-derived knowledge | Karpathy-style LLM wiki built from raw sources | [[10-Wiki/README]] |
| Data readiness | Pantry/prep/plate maps and silver platter summaries | [[00-System/Data Readiness]], [[50-Outputs/README]] |
| Local orientation | Thin folder manuals in project folders | [[00-System/Project Manual Standard]] |
| Self-improvement feedback | Dream reviews, health checks, repeated-work/stale-memory notes | [[40-Observability/README]] |

## Buckets

- Profile: durable operating preferences and current strategic state, only when confirmed.
- Memory: meaningful session summaries and project history.
- Knowledge: source-derived wiki notes with citations and clear confidence.
- Prep: deterministic source-derived summaries that help agents reason without rereading raw material.

## Rule

Do not mix the buckets. Current work belongs in Linear, durable memory belongs here, and SOP changes belong in `agentic-os-template`.

Outside material stays outside the system until it passes [[00-System/Fresh Start Policy]].

Raw data is not automatically memory. Use [[00-System/Data Readiness]] to turn raw sources into useful prep artifacts before building agents, automations, or dashboards.
