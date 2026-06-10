---
title: Linear Handshake
tags:
  - memory-vault/system
  - linear
---

# Linear Handshake

Linear is the active-work layer. Memory Vault is the durable-memory layer.

Linear setup is deferred, but this boundary is active now.

## Linear Owns

- current tasks
- status
- blockers
- acceptance criteria
- owners
- priorities
- due dates
- next actions
- implementation follow-ups

## Memory Vault Owns

- durable project context
- decisions and rationale
- lessons with future triggers
- source-derived wiki notes
- session summaries worth recalling
- project/area strategy
- observability and improvement recommendations

## Handshake Rule

Every active project should eventually have:

- a Linear project or issue set for execution state
- a Memory Vault project note for durable context
- links in both directions

## Closeout Routing

At closeout, classify each item:

| Item | Destination |
|---|---|
| Still needs action | Linear |
| Explains why the work exists | Memory project or area note |
| Changes future behavior | `agentic-os-template`, project manual, or lesson |
| Is source-derived knowledge | `10-Wiki/` |
| Is only historical but useful | `30-Archive/` |
| Is transient | no action |
