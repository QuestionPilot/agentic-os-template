---
name: closeout
summary: Wrap a session — walk the 8 closeout questions, classify each lesson into one of 11 classes, and route it to its source of truth.
triggers: [end of a session with meaningful work, user says wrap up or close out or we are done, a session summary is requested after real work]
verification: process-memory
harnesses: [claude, codex]
kind: native
lifecycle: shipped
---

# Closeout — Session Self-Improvement Pass

Wraps a session by running the canonical closeout protocol from
`ai-config/core/self-improvement.md` and routing every meaningful lesson to its
source of truth. A lesson is not learned until it changes a future behavior,
check, task, script, decision, or durable note.

## When to invoke

`closeout` is **manual-fire** — no hook enforces it. Invoke it explicitly (via
the `closeout` Skill / `/closeout`) when:

- The user says "wrap up", "close out", "end of session", "we're done", or asks
  for a summary at the end of meaningful work.
- A meaningful workstream finished — file edits, decisions, or discoveries.

Run it even when nothing was learned — answer `no-action` with a one-line reason.
That is a valid, complete outcome.

## Inputs to gather first

1. List the files touched this session. In a git repo, use `git status --short`
   and `git diff --stat`; otherwise summarize from the conversation.
2. Note any active Linear issue. Do not invent one. Check its status — if this
   session's work completed it, move it to Done as part of closeout. Verify; do
   not assume an integration did it.
3. Note any verification or tests that were run, or skipped.
4. **Enumerate State Deltas.** Linear projects created/closed/status-changed
   this session; Linear issues created (not just closed — new backlog issues
   count); new durable on-disk artifact directories (e.g. a fresh
   `cross-model-out/<YYYY-MM-DD>-<slug>/` run dir, a new `docs/plans/<name>.md`).
   If any exist, each becomes a mandatory `state-delta` lesson with a memory
   write performed BEFORE session exit — never deferred to a future session.
   See `ai-config/core/self-improvement.md` for the canonical taxonomy.

## The 8 closeout questions

From `ai-config/core/self-improvement.md` — answer each in 1–2 sentences. Q0 is
the EAD gate; it runs first because if the answer is "we should have eliminated
this", the right outcome is `no-action` with rationale, and walking the
classification machinery for work that should never have shipped is wasted.

0. **EAD gate (Eliminate / Automate / Delegate):** What did we build this
   session that we should have eliminated instead? Would the system be worse
   if we just didn't ship this? If the answer is "nothing breaks if we don't
   ship it", log the win and classify the work as `no-action`. State-delta
   lessons remain mandatory regardless of Q0 outcome — they were enumerated
   in the Inputs section above and the memory writes happen during closeout
   itself, never deferred. The Q7 file sweep below ALSO remains mandatory
   regardless of Q0 outcome — junk files survive a `no-action` close just as
   readily as a substantive one. Q7a verification (operator-main git-state
   cleanliness) is mandatory under the same logic — a stray staged change
   propagates to the next session as a false-RED whether the current session
   was substantive or `no-action`. Q0 skips only the remaining
   lesson-classification walk (questions 1–6), not the State Deltas, file
   sweep, Q7a git-state verification, Linear updates, or the output block.
   The principle behind this question is named in
   `core/operating-system.md` → `## Boring is Beautiful`.
1. Did we learn anything that should change future behavior?
2. Is the lesson already represented in the right source of truth?
3. Can the lesson become a check or script instead of prose? **And — did this
   session run a successful, repeatable flow worth promoting to a permanent
   skill?** If so, classify it `skill` and route it through the seven-step
   promotion trust contract in `ai-config/skills/skill-authoring.md`
   (principle 11) — provenance → synthesize a script → fixture test → temp
   staging → test must pass → **explicit user approval** → atomic commit. The
   fixture-test and explicit-approval steps are non-optional; never auto-promote
   an unvetted flow into the trusted skill set.
4. Does Linear need updating — a completed issue moved to Done, a status
   corrected, or a follow-up issue created?
5. Does the durable knowledge base need a note?
6. Did the work reveal a missing data path, an unclear handoff, or an unbounded
   autonomous run?
7. **File sweep:** What files / directories did this session create that should
   NOT survive past it? List every `Write` / `Edit` / `Bash mkdir` / `Bash touch`
   / `Bash cp` / shell `>` or `>>` redirect / Linear-CLI file output that the
   session performed. For each one, attach exactly one explicit classification:
   - `keep-because-<reason>` — durable evidence the session needs to preserve
     (e.g. `keep-because-cross-model-out-run-dir`, `keep-because-PR-artifact`,
     `keep-because-Linear-spec-input`). State the reason; do not leave it bare.
   - `clean-now` — the artifact is scratch / scaffolding that the session
     consumed; execute the `rm` INLINE during closeout, BEFORE emitting the
     output block, and record the cleanup as `cleaned-now` in the
     `## Files created this session` section below (NOT in `## State Deltas`
     — that section's job is Linear-state + new-on-disk-directory deltas,
     not per-file sweeps).
   - `clean-by-<date-or-owner>` — must survive this session but has a bounded
     lifetime; name the retention rule explicitly (e.g.
     `clean-by-2026-06-25` or `clean-by-project-close-+-30-days`) so a future
     hygiene sweep can collect it without re-deriving the policy.

   **Default-keep is forbidden.** Every created artifact gets one of the three
   classifications above; silence is not an option. Per
   [[feedback_clean_operation_no_lingering_junk]] the operator's standard is
   "if you have to create junk files as part of a process, you need to clean
   them up as soon as that process is done" — Q7 is how the closeout walk
   enforces it.

   **Q7a — operator-main git-state cleanliness.** Before the closeout output
   block can write `operator-main clean at <SHA>` (or any equivalent
   clean-claim line) in `## State Deltas` or `## Running State`, run all three
   of these checks against the operator-main checkout:

   ```bash
   git status --porcelain        # MUST be empty (no output at all)
   git diff --cached --quiet     # MUST exit 0 (no staged changes)
   git diff --quiet              # MUST exit 0 (working tree vs index)
   ```

   If any check fails, the closeout walk pauses to either (a) commit / stash /
   restore the dirty state inline BEFORE emitting the output block, OR
   (b) explicitly name the dirty state in the State Deltas line (e.g.
   `operator-main has 1 staged file: scripts/foo.sh (uncommitted)`).
   **Silent claims of `clean` are forbidden.** The <TEAM>-125 false-RED case
   study — a stray staged `scripts/check-drift.sh` removal slipping past a
   prior session's closeout and propagating as a false `make verify` failure
   into the next session — is what Q7a closes. See
   [[feedback_verify_red_first]] (the kickoff-side discipline that caught the
   propagation) for the sister rule.

If every answer is "no", classify as `no-action` with a single reason line and
skip to Output. (Q7 itself never short-circuits — even a `no-action` session
must enumerate its created files; the only valid Q7 answer for a session that
created none is `_none_`. Q7a never short-circuits either — the operator-main
git-state checks run before the output block writes any clean-claim line, even
on a `no-action` close.)

## Lesson classification

For each lesson, pick exactly one class and route it. The classes are defined in
`ai-config/core/self-improvement.md`:

| Class | Destination | How |
| --- | --- | --- |
| `rule` | `ai-config/core/*.md` or the harness entrypoint | Propose the edit, get explicit user approval before writing — shared framework content requires explicit user direction. |
| `check` | `ai-config/scripts/` or project-local | Small deterministic validator. |
| `script` | `ai-config/scripts/` or project-local | Automation for repeated manual work. |
| `linear` | A Linear issue | Create or comment; reference the closeout summary. |
| `obsidian` | The durable knowledge base | Propose path + body to the user; do not write directly. |
| `playbook` | `ai-config/playbooks/*.md` | New or updated workflow file (requires user approval). |
| `skill` | The harness's capability/skill set | Use a skill-creation capability for new ones. When a *successful repeatable flow* this session is worth keeping, promote it via the seven-step trust contract in `ai-config/skills/skill-authoring.md` (principle 11): provenance → synthesize a deterministic script → fixture test → temp staging → test must pass → **explicit user approval** → atomic commit. The fixture-test and explicit-approval steps are non-optional — an unvetted auto-promoted skill is the failure mode. |
| `data-readiness` | `playbooks/data-readiness-map.md`, verification, or Obsidian | Use when repeated work needs better source plumbing or summaries. |
| `goal-run` | `playbooks/goal-run.md` | Use when autonomous or recurring work needs clearer bounds. |
| `no-action` | Transcript only | Note it and move on. |
| `state-delta` | `memory/project_*.md` (or `runtime_*.md`) + `MEMORY.md` index update | Mandatory when a Linear project or new durable on-disk artifact dir came into existence this session. Write the memory pointer during closeout itself — never deferred. |

## Memory-hygiene (on any memory write)

Closeout is where memory writes happen, so it is also where the memory store is
kept healthy. When this session writes or updates a memory note — a `state-delta`
write, or any other memory-file change — apply the contracts from
`ai-config/core/memory-model.md` (canonical definitions there; this is the
write-side enforcement point):

1. **Refresh, don't blindly append.** Before adding a new note, classify the
   related existing notes with the Keep / Update / Consolidate / Replace / Delete
   lifecycle (`core/memory-model.md` → Memory Maintenance Lifecycle). Prefer
   Update or Consolidate over writing a near-duplicate new note.
2. **Discoverability.** After writing or renaming a note, confirm the memory
   index (`MEMORY.md`) carries a one-line pointer to it; after deleting or
   consolidating, remove the stale index line. An un-indexed note is invisible to
   the next session.
3. **Frontmatter parser-safety.** Keep top-level scalar values quoted when they
   contain ` #` or `: ` (the silent-corruption shapes). Run
   `scripts/check-memory-drift.{sh,ps1}` against the memory dir — one pass flags
   headline-vs-body drift, `MEMORY.md` bloat, AND frontmatter parser-safety
   hazards. Fix what it surfaces in the notes THIS session touched; pre-existing
   findings in untouched notes route to a `consolidate-memory` follow-on, not a
   blocked closeout.

`consolidate-memory` runs this same lifecycle as a periodic full-store sweep; at
closeout the scope is the notes the session actually wrote.

## Output

End with a single block in the shape from `ai-config/linear/closeout-format.md`:

```
## Result
<one line: what changed or was decided>

## Verification
<what was run, reviewed, or proven; explicitly note skipped checks>

## State Deltas
<one line per delta: kind → memory file (or `_none_` if no state changed)>

## Files created this session
<one line per created artifact: path → keep-because-<reason> | cleaned-now | clean-by-<date-or-owner>>
<or `_none_` if the session created no files outside the State Deltas dirs>

## Running State
<background processes, dev servers / ports, open worktrees / branches still live
at session end; or `_none_`>

## Residual Risk
<known gaps, follow-ups, or "none">

## Lessons
- [class] <one line> → <destination>
(or)
- [no-action] <one line reason>

## Pick up here
<one sentence: the next concrete action a fresh agent should take>
```

The `## State Deltas` section is required when any state changes occurred this
session (Linear-project create/close/status-change, new on-disk artifact dirs).
A literal `_none_` is the valid value when nothing changed. State-delta memory
writes are performed during closeout itself, not deferred.

Any `operator-main clean at <SHA>` line (or equivalent clean-claim) in this
section is gated by the Q7a verification above — the three `git status` /
`git diff --cached --quiet` / `git diff --quiet` checks must pass before the
clean-claim line is written. If they don't, name the dirty state explicitly
(e.g. `operator-main has 1 staged file: scripts/foo.sh (uncommitted)`)
instead of writing a silent `clean`.

The `## Files created this session` section captures the Q7 file-sweep output —
one line per created artifact with its explicit classification from the Q7
walk (`keep-because-<reason>` / `cleaned-now` / `clean-by-<date-or-owner>`).
**Default-keep is forbidden**: every entry carries an explicit classification,
silence is not an option. Use a literal `_none_` when the session created no
files outside the State Deltas dirs already named above. Anything classified
`clean-now` during Q7 must be removed INLINE before the output block emits;
write the entry as `cleaned-now` in this section to record that the cleanup
actually ran. The State Deltas section above already covers
Linear-project-state changes + new durable on-disk artifact directories;
this section's job is the per-file sweep that fell through that gate
(individual scratch files, backup snapshots, generated single-purpose files,
audit clones).

The `## Running State` section captures anything that survives session end —
background processes the user is expected to monitor (dev servers, watchers),
the ports they bind, and any open worktrees or branches the next session needs
to know about. Use `_none_` when the session leaves no live state behind. Any
operator-main `clean` claim here is gated by the same Q7a verification as in
`## State Deltas` above.

The `## Pick up here` section is the final line of the block: one sentence
naming the next concrete action a fresh agent should take. It exists so a
fresh session can re-enter the work without re-reading the whole transcript.
If the work is fully complete, write `done` and link the artifact (PR URL,
Linear issue, merged commit) that proves it.

If a Linear issue was active this session, also post this block as a comment on
that issue.

## Notes

- The transcript is the marker — do not write a side artifact to record that
  closeout ran.
- `no-action` is a legitimate, complete outcome.
- **`closeout` is manual-fire only — there is no Stop hook.** Invoke it whenever
  a session warrants a wrap-up (framework edits or not). The discipline lives in
  the session-agent kickoff orientation and the agent/operator remembering, not
  a gate.
  The prior auto-enforcement — a `Stop` hook with memory-path / Q7-cleanup
  exemptions — was removed in <TEAM>-211 because it re-fired on closeout's own
  protocol-prescribed writes (state-delta memory writes that cite framework
  files; the Q7 cleanup `rm`), looping a normal session. Lineage: <TEAM>-57 /
  <TEAM>-62 / <TEAM>-78 / <TEAM>-116 / <TEAM>-138 built the gate up; <TEAM>-211 removed it in
  favor of discipline-backed closeout.
