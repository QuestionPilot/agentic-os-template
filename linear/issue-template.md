# Issue Template

The canonical shape for a Linear issue in an agentic-OS workspace. The bar: a
future agent can execute the issue without rereading the conversation that
spawned it. Two halves, both required **at create time** — the metadata
checklist (Linear fields) and the description body (markdown sections). A
title plus a prose-blob description is nonconforming even when the prose is
good: metadata left "for later" is how bare issues are born.

## Required metadata — set at create time, not later

| Field | Rule |
| --- | --- |
| Team | Always explicit. |
| Project | Every issue belongs to a project. A genuinely standalone issue states `Deliberately projectless: <reason>` in its body instead. |
| Priority | Chosen deliberately — never left at "No priority". |
| Labels | At least one from [`labels.md`](labels.md) (a Type label; add Operations labels as they apply). |
| Assignee | The owner. A deliberately-unassigned issue states why in the body. |
| Parent / relations | An issue spawned by other tracked work links back: parent for decomposition, `blocks` / `blocked-by` / `related` for sequencing. Mirror hard blockers as real relations, not prose. |
| Estimate / cycle | Optional — set them when the team plans with them. |

One-shot create with full metadata (lineark CLI shown; MCP equivalent per
[`linear-setup.md`](linear-setup.md) §4.2):

```bash
lineark issues create "Title" \
  --team <TEAM_KEY> --project <PROJECT_NAME_OR_UUID> \
  --priority <urgent|high|medium|low> --labels "<Type>,<ops-label>" \
  --assignee <owner> [--parent TEAM-NN] \
  --description "$(cat issue-body.md)" --format json
# then, for sequencing constraints:
lineark relations create TEAM-XX --blocked-by TEAM-YY --format json
```

## Description body

```markdown
## Outcome

What state is true when this issue is complete — one or two sentences, observable.

## Scope

What is included and excluded. Excluded is as load-bearing as included.

## Acceptance criteria

- [ ] Observable criterion a reviewer can check
- [ ] Observable criterion a reviewer can check

## Verification

The proof required before closing: command, browser flow, review, or live artifact.

## Dependencies & sequencing

Blocking or related issues and the order constraint — mirrored as real Linear
relations, not prose only. Omit this section when the issue is standalone.

## Links

- Relevant repo, PR, or deploy:
- Relevant durable note:
- Relevant playbook or artifact:
```

## Hygiene check

The advisory `scripts/check-linear-hygiene.sh` (PowerShell twin:
`check-linear-hygiene.ps1`) sweeps the workspace's open issues against the
machine-visible subset of this standard and WARNs on gaps — missing project,
default priority, no labels, no assignee, or a body without an
`## Acceptance criteria` H2 heading. The documented escapes above are honored:
a body stating `Deliberately projectless: <reason>` or
`Deliberately unassigned: <reason>` suppresses the corresponding warning.
Fields the sweep does not police: team (the create command enforces it),
parent/relations and body completeness beyond the AC heading (judgment calls).
Issues it could not fully read are named `unchecked`, never silently skipped.
It is a soft signal, never a gate.
