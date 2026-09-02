# `linear` CLI — static usage reference (pinned v2.5.0)

Load THIS instead of running `--help` chains — it is the full command surface at
the pinned version, kept honest by the drift check `tests/linear-cli-usage.test.sh`.
Update it in the same change as any version-pin bump (linear-setup.md §3.2 step 6).

**Three contracts:** (1) list payloads are `{nodes:[…]}` — unwrap `.nodes`;
(2) every query needs `--team <KEY>` or `--all-teams`; (3) `issue query` returns
ALL states by default — pass `-s triage -s backlog -s unstarted -s started` for
the open cut. `--json` on reads; state/assignee arrive as objects (`.name`),
priority as a number with sibling `.priorityLabel`.

## Command groups (singular, not plural)

```
auth      login | logout [ws] | list | default [ws] | token | whoami | migrate
issue     mine/list | query | view [-j] | create | update | delete | start | id |
          title | url | describe | commits | pull-request | attach | link |
          comment (add|update|delete|list) | relation (add|list|delete) |
          agent-session
project   list | view | create | update | delete
project-update  (status updates)
team      list | view | members | create | autolinks
user      list
cycle     list | view
milestone list | view | create | update | delete
initiative / initiative-update
label     list | create
document  create | view | update | delete
config    (interactive .linear.toml)  ·  completions  ·  schema  ·  api [query]
```

## The cuts framework scripts use

```bash
linear auth whoami                                   # workspace + "Display name: <n>"
linear project list --json                           # .nodes[]: id,name,slugId,status{name}
linear issue query --all-teams -s triage -s backlog -s unstarted -s started \
  --limit 250 --json                                 # global open sweep
linear issue query --all-teams --project <UUID> -s backlog -s unstarted -s started \
  -s triage --limit 250 --json                       # per-project open cut
linear issue query --all-teams --assignee <displayName> -s started --json   # mine
linear issue view TEAM-NN --json                     # single issue object
linear issue create -t "Title" --team KEY --project <P> --label L --priority 3 \
  --assignee <user> -d "body"                        # priority: 1 urgent…4 low
linear issue update TEAM-NN --state started          # state by type or name
linear issue comment add TEAM-NN --body-file <path>   # markdown bodies: a file, never `-b -` (CLI 2.5.0 posts a literal "-", it does not read stdin)
linear issue relation add|delete TEAM-X <type> TEAM-Y   # types: blocks, blocked-by,
linear issue relation list TEAM-X                       # related, duplicate
linear api '<graphql>'                               # escape hatch; `linear schema`
```

`issue query` filters: `--search`, `--search-comments`, `--team` (repeatable),
`--all-teams`, `-s/--state` (repeatable: triage backlog unstarted started
completed canceled), `--assignee`, `-U/--unassigned`, `--project`,
`--project-label`, `--cycle`, `--milestone`, `-l/--label` (repeatable),
`--limit` (0 = unlimited), `--sort manual|priority`.

Auth: OS keyring via `linear auth login`; headless via `LINEAR_API_KEY` env var
(takes precedence). Errors: exit 1 user, 2 unknown command/option.
