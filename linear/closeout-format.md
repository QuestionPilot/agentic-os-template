# Linear Closeout Format

Use this format for meaningful issue closeout comments.

Stamp a shared **`closeout_id`** at the top of the comment — the same id the
session-log drain writes to the vault log's frontmatter (see
`capabilities/closeout.md` → Session-log drain). It makes the Linear comment ↔ the
durable vault session log ↔ the commit all linkable from one token.

## Result

What changed or what was decided.

## Verification

Checks, tests, review, or live proof.

## State Deltas

Linear-state changes and new durable on-disk artifact dirs that came into existence
this session, with the memory file that captures each. Use `_none_` when no state
changed.

Any `operator-main clean at <SHA>` line in this section (or in `## Running State`
below) is gated by the Q7a verification in the closeout walk: `git status
--porcelain` empty + `git diff --cached --quiet` exit 0 + `git diff --quiet`
exit 0. If the checks don't pass, name the dirty state explicitly instead of
writing a silent `clean`.

Examples:

```
- Linear project created: <name> (<status>) → memory/project_<slug>.md, MEMORY.md indexed
- Linear issue created: QUE-NN, QUE-MM → no separate pointer (covered by parent project memory)
- New artifact dir: docs/plans/<date>-<slug>.md → no separate pointer (plan-class, lives in repo)
- operator-main: clean at <SHA> (verified: git status --porcelain empty, git diff --cached --quiet 0, git diff --quiet 0)
- operator-main: 1 staged file (scripts/foo.sh uncommitted) → resolve before next session
```

## Files created this session

The Q7 file-sweep output: one line per individual artifact this session created
that fell through the State Deltas gate above (scratch files, backup snapshots,
generated single-purpose files, audit clones, lone plan/spec files). Every
entry carries an explicit classification — **default-keep is forbidden**. Use
a literal `_none_` only when the session created no files outside the State
Deltas dirs above.

Classification tokens:

- `keep-because-<reason>` — durable evidence the session needs to preserve.
  State the reason concretely.
- `cleaned-now` — scratch that was removed INLINE before this block emitted.
- `clean-by-<date-or-owner>` — must survive this session but has a bounded
  retention rule. Name the rule explicitly so a future hygiene sweep can
  collect it without re-deriving the policy.

Examples:

```
- cross-model-out/<date>-<slug>/ → keep-because-PR-evidence-for-<issue-id>
- /tmp/scratch-diff.patch → cleaned-now
- inspection-sandbox/<vendor>/ → clean-by-<date> (kept for upstream-CWE follow-up)
- _none_   (when no files were created this session outside the State Deltas dirs)
```

## Running State

Background processes, dev servers and the ports they bind, open worktrees, or
branches still live at session end — anything the next session must inherit.
Use `_none_` when the session leaves no live state behind.

Examples:

```
- dev server: `npm run dev` on :3000 (pid 12345, foregrounded by user)
- worktree: .<harness>/worktrees/<name> on branch <branch> (uncommitted: <n> files)
- background: `tail -f` on staging logs, terminal 2
```

## Residual Risk

Known gaps, skipped checks, or follow-ups.

## Lesson Classification

One of: `rule`, `check`, `script`, `linear`, `obsidian`, `playbook`, `skill`, `data-readiness`, `goal-run`, `no-action`, `state-delta`.

## Pick up here

One sentence naming the next concrete action a fresh agent should take. Exists
so the next session can resume without re-reading the whole transcript. Write
`done` and link the proving artifact (PR URL, Linear issue, merged commit)
when the work is fully complete.
