---
title: <project-or-issue-name>
tags:
  - linear-handshake
linear: https://linear.app/<workspace>/project/<slug>
status: <mirror of Linear state at last sync — informational only>
harness: all
learned_by:
---

# {{Project or Issue Name}}

Handshake note for a Linear project or issue. See `$AI_CONFIG_DIR/obsidian/vault-guide.md` §5 (Linear Handshake) + §8 (runtime contract) for the bidirectional-link pattern and ownership rule.

**Ownership rule:** Linear owns status (acceptance criteria, blockers, current state). This note owns durable rationale, decisions, and lessons. The `status:` frontmatter is a stale-by-design mirror — query Linear for current state.

**`linear:` frontmatter:**

- For a project: `https://linear.app/<workspace>/project/<slug>`
- For an issue: `https://linear.app/<workspace>/issue/<KEY-N>`
- **Allowed absence:** when the work is not tracked in Linear (or Linear is unavailable), omit the `linear:` key. The rest of this template still works as a project-handshake note.

## Linear

`<URL>` — the canonical Linear project/issue this note mirrors. Click to see current state.

## Purpose and Outcome

The durable rationale — what we are trying to achieve and why it matters. This is what Linear's status field does not capture: the operating reason.

## Open Questions and Context

Notes that do not belong in Linear's acceptance criteria. Background context, unresolved trade-offs, links to prior decisions.

## Decisions

Links to relevant notes under `03-Decisions/`. Each decision note carries its own rationale; this section is the index.

- `[[<decision note title>]]` — one-line summary.

## Lessons

Links to relevant notes under `04-Lessons/`. Each lesson note carries its own classification and durable form.

- `[[<lesson note title>]]` — one-line summary.

## References

Project repo URL, source code locations, supporting documents.

- Repo: `<URL>`
- Source: `<path or URL>`
- Supporting: `<links>`
