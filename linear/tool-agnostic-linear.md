# Tool-Agnostic Linear Workflow

Use this when an AI system needs to plan or manage Linear work and may not have a dedicated Linear skill.

Website: https://linear.app

## Principle

Linear is the active-work layer. The tool surface can vary by agent, but the record should remain usable by humans and other agents.

## Access Modes

| Mode | Use when | Expected output |
| --- | --- | --- |
| Native Linear tools | The harness has a Linear app, connector, plugin, or MCP tools | Create or update real Linear projects, milestones, issues, comments, and documents |
| API or CLI | The environment has approved Linear credentials and a scriptable client | Read current Linear state, then create or update records through the official interface |
| Browser UI | The user approves UI operation and the environment supports browser control | Make careful UI edits after reading current workspace context |
| Draft-only | No write-capable Linear access exists | Produce Linear-ready project, milestone, issue, and closeout markdown |

## Read Before Write

Before creating work items, read or ask for:

- team or workspace
- existing projects with similar names
- current statuses
- labels
- owners or assignees
- cycles, milestones, or target dates
- existing issues that may duplicate the work

If this context cannot be retrieved, create a draft plan and clearly mark the missing identifiers.

## Project Shape

For a bounded workstream, create one project with:

- goal
- non-goals
- target architecture or desired end state
- completion standard
- milestones that represent phase gates
- a release or closeout gate

Use milestones for sequence. Use issue dependencies for hard blockers.

## Issue Shape

The canonical standard lives in `issue-template.md` — a required-metadata
checklist plus the description body below. Both halves apply in every access
mode, including draft-only: a draft that omits the metadata just moves the gap
to whoever executes the draft.

Set the metadata at create time: team; project (or an explicit
`Deliberately projectless: <reason>` line in the body); a deliberate priority —
never the default "No priority"; at least one label from `labels.md`; an
assignee; and parent or blocking/related relations when the issue is spawned by
other tracked work.

Each issue should be executable by a future agent without rereading the whole conversation:

```markdown
## Outcome

What state should be true when this issue is complete.

## Scope

What is included and excluded.

## Acceptance criteria

- [ ] Observable criterion
- [ ] Observable criterion

## Verification

- Command, browser flow, review, or live proof

## Dependencies & sequencing

- Blocking / related issues, mirrored as real relations (omit when standalone)

## Links

- Repo, deploy, doc, durable note, or artifact link
```

## Closeout Shape

Close issue comments with:

- result
- verification
- residual risk
- follow-ups
- lesson classification when relevant

## Safety

- Do not store secrets in Linear.
- Do not paste raw environment dumps.
- Do not mark high-risk work done without the verification gate in the issue.
- Do not archive rollback sources until cutover issues explicitly say it is safe.
