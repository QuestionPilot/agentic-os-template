---
title: Recall Workflow
tags:
  - memory-vault/system
  - memory-vault/retrieval
---

# Recall Workflow

Recall means finding past durable context without loading the whole vault.

## Order

1. Check Linear for active work if the question is about current status.
2. Check the relevant project or area note.
3. Check [[03-Decisions/_index]] and [[04-Lessons/_index]].
4. Check [[10-Wiki/index]] for source-derived knowledge.
5. Search narrowly with `rg` when indexes are insufficient.

## Answer Standard

- Cite the note or source.
- Distinguish current state from past history.
- Say when a match is weak or stale.
- Do not turn raw source text into confirmed memory.

## Vector Search

Do not add Pinecone or another vector layer by default. Consider it only after file search and indexes show real retrieval strain.
