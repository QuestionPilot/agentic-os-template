---
title: Fresh Start Policy
tags:
  - memory-vault/system
  - agentic-os/fresh-start
---

# Fresh Start Policy

Memory Vault starts clean.

Do not bulk-import prior project memories, assistant notes, transcripts, environment history, or agent memory stores.

## Outside Sources

Outside material is not the new source of truth unless it is reviewed and promoted. This includes:

- agent memory stores
- local agent folders
- chat/session exports
- project notes
- assistant-specific memory files

## Promotion Test

Promote outside content only when all are true:

- It is still true.
- It will help future work.
- It is durable, not just historical.
- It belongs in Memory Vault rather than Linear, `agentic-os-template`, a project repo, or local secure config.
- It can be summarized cleanly instead of copied wholesale.
- The user approves the promotion, or the need is obvious during an active workstream.

## Promotion Destinations

| Outside content | Destination |
|---|---|
| Active task, blocker, acceptance criteria, next action | Linear |
| Reusable operating rule | `agentic-os-template` |
| Project memory | `01-Projects/` |
| Area memory | `02-Areas/` |
| Decision and rationale | `03-Decisions/` |
| Durable lesson with future trigger | `04-Lessons/` |
| Source-derived research or concept | `10-Wiki/` plus `20-Raw/sources` |
| Historical summary worth searching later | `30-Archive/` |
| No durable value | Leave behind |

## Rule

Summarize and link. Do not copy outside sprawl into the vault.
