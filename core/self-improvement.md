# Self-Improvement

Self-improvement is the primary operating goal of this system.

A lesson is not learned until it changes a future behavior, check, task, script, decision, or durable note.

## When To Apply

Apply this loop when work reveals:

- a mistake or wrong assumption
- repeated friction
- a blocked or stale tool
- weak verification
- context or instruction drift
- a reusable discovery
- a user correction
- a better workflow pattern

## Lesson Classification

Classify each meaningful lesson as exactly one durable action:

| Class | Use when | Destination |
| --- | --- | --- |
| `rule` | future agents should behave differently | `core/` or the relevant harness entrypoint |
| `check` | the lesson can be enforced mechanically | validation, audit, test, or CI-style script |
| `script` | repeated manual work should be automated | `scripts/` or a project-local helper |
| `linear` | follow-up work remains active | Linear issue |
| `obsidian` | durable knowledge should be remembered | Obsidian vault |
| `playbook` | a repeatable workflow changed | `playbooks/` |
| `skill` | capability install or usage guidance changed, **or a successful repeatable ad-hoc flow is worth promoting to a permanent skill** | `skills/` — promote via the seven-step trust contract in `skills/skill-authoring.md` (principle 11); the fixture-test and explicit-user-approval steps are non-optional |
| `data-readiness` | repeated work needs better source plumbing or summaries | `playbooks/data-readiness-map.md`, verification, or Obsidian |
| `goal-run` | autonomous or recurring work needs clearer bounds | `playbooks/goal-run.md` |
| `no-action` | transient or already covered | closeout note only |
| `state-delta` | a Linear project (created / closed / status-changed) or new durable on-disk artifact directory came into existence during this session | a project-type memory note (frontmatter `metadata.type: project`) or `runtime_*.md` file written BEFORE session exit, plus a `MEMORY.md` index update |

## Promotion Rule

Do not let lessons stay buried in chat, comments, or raw logs.

- If it affects global behavior, update `core/` only with explicit user instruction.
- If it affects one harness, update that harness entrypoint.
- If it is active work, create or update a Linear issue.
- If it is durable knowledge, write it to Obsidian or the long-term vault.
- If a `feedback_*` (or `decision`) memory note was written to the harness-native
  store THIS session, **promote it into its thematic `04-Lessons` note at
  closeout** — fold the lesson in and add the note's name to that lesson's
  `## Source Notes`. This is a **cache→durable promotion** of an already-curated
  memory note (the agent's own single-fact note, not mixed-origin transcript text),
  and the Cache Contract in `core/memory-model.md` already states durability flows
  by promoting native memory through closeout into the vault. It is therefore
  **distinct from, and narrower than, the propose-don't-write rule for the
  `obsidian` class**: a brand-new lesson distilled fresh from the untrusted
  transcript still stays propose-only (an operator approves it before it enters a
  curated note), because that path carries the transcript-laundering risk the rule
  exists to stop. Promotion of an already-written feedback/decision note does not —
  **but the safety is enforced, not assumed**: closeout RE-RUNS the injection scan
  at distillation time on BOTH the source note and the folded lesson (never relying
  on a presumed scan-when-written), and the vault audit must stay clean, before the
  write stands. The `closeout` capability performs the promotion, and
  `scripts/check-distillation-completeness.{sh,ps1}` is the pre-wipe guard that
  verifies no feedback note ever strands undistilled.
- If it can be checked, add or update the check.
- If a successful repeatable flow is worth keeping, promote it to a `skill` — but only through the seven-step trust contract in `skills/skill-authoring.md` (principle 11). Provenance → synthesize a deterministic script → fixture test → temp staging → test must pass → explicit user approval → atomic commit. The fixture-test and explicit-approval steps are non-optional: auto-promoting an unvetted flow into the trusted skill set is the failure mode this gate exists to prevent.
- Every meaningful closeout ALSO writes a durable, append-only **session log** to the vault (`30-Archive/Sessions/`) — the always-on capture of what happened, distinct from the propose-don't-write `obsidian` class. It records the candidate lessons/decisions so nothing is lost when promotion to a curated note is deferred, and treats the transcript as untrusted, mixed-origin evidence (provenance labels; quarantine; injection scan before write). See `capabilities/closeout.md` → Session-log drain.

## Inputs — State Deltas

This section and the `state-delta` lesson class were introduced together so a session that creates/closes/status-changes a Linear project or spawns a new durable on-disk artifact directory writes the pointer DURING closeout rather than deferring.

Before the closeout questions, enumerate state changes that occurred this session:

- Linear projects created, closed, or status-changed.
- Linear issues created (not just closed — new backlog issues count).
- New durable on-disk artifact directories (e.g. a fresh `cross-model-out/<YYYY-MM-DD>-<slug>/` run dir, a new `docs/plans/<name>.md`).

If any deltas exist, each becomes a mandatory `state-delta` lesson with a memory write performed BEFORE session exit. If none, that is a valid finding — record `_none_` and proceed.

## Closeout Questions

Before claiming meaningful work is complete, answer. Q0 is the EAD gate; it
runs first because if the answer is "we should have eliminated this", the right
outcome is `no-action` with rationale and the rest of the walk is wasted.

0. **EAD gate (Eliminate / Automate / Delegate):** What did we build this session that we should have eliminated instead? Would the system be worse if we just didn't ship this? If the answer is "nothing breaks if we don't ship it", log the win and classify the work as `no-action`. State-delta lessons remain mandatory regardless of Q0 outcome — they were enumerated in the Inputs section above and the memory writes happen during closeout itself, never deferred. The Q7 file sweep below ALSO remains mandatory regardless of Q0 outcome — junk files survive a `no-action` close just as readily as a substantive one. Q7a verification (operator-main git-state cleanliness) is mandatory under the same logic — a stray staged change propagates to the next session as a false-RED whether the current session was substantive or `no-action`. Q0 skips only the remaining lesson-classification walk (questions 1–6), not the State Deltas, file sweep, Q7a git-state verification, Linear updates, or the output block. The principle behind this question is named in `core/operating-system.md` → `## Boring is Beautiful`.
1. Did we learn anything that should change future behavior?
2. Is the lesson already represented in the right source of truth?
3. Can the lesson become a check or script instead of prose?

   **Q3a — skill-candidate capture.** Did this session repeat a multi-step procedure worth capturing as a skill, but not (yet) worth the full seven-step promotion (`skills/skill-authoring.md` principle 11)? Add a CANDIDATE row to the harness's skill catalog (the catalog's candidates section) — name, one-line trigger, where the procedure ran — for manual triage. Write the row at the catalog's SOURCE: on harnesses whose rendered catalog is build-manifest-managed, that is the operator-local catalog overlay (re-render after writing) — a hand edit to the rendered catalog itself trips the drift gate; each harness realization names its concrete destination. No autonomous skill creation: the candidate row is the entire write; promotion stays manual via the trust contract.

4. Does Linear need updating — a completed issue moved to Done, a status corrected, or a follow-up issue created? A follow-up issue created at closeout conforms to the canonical standard in `linear/issue-template.md` — full metadata at create time (project, deliberate priority, at least one label, assignee, a relation back to the spawning issue) plus the structured body. Closeout speed is how bare issues are born: an issue spun out of a finishing session with title + prose alone strands its metadata on whoever picks it up. The issue's `state-delta` line records it as created `to-standard`.

   **Q4a — project-note closeout edit.** If a Linear project transitioned to Completed (or Canceled) this session, the durable-knowledge project note gets its closeout edit NOW, in the same session — not deferred: flip the note's status field to the terminal state, rewrite live-state prose ("currently", "next step is", "treat X as the active successor") into past tense, and add a one-line successor pointer when another project or issue carries the work forward. A completed note that still reads as active is the semantic-drift class a whole-system review flagged across five project notes at once — each passed the structural audit while misdirecting the next agent that loaded it. The mechanical audit cannot catch prose tense; this edit is the only gate.
5. Does the durable knowledge base (Obsidian is the canonical example) need a note?
6. Did the work reveal a missing data path (an unprepared silver platter), an unclear handoff, or an unbounded goal-run?
7. **File sweep:** What files / directories did this session create that should NOT survive past it? List every `Write` / `Edit` / `Bash mkdir` / `Bash touch` / `Bash cp` / shell `>` or `>>` redirect / Linear-CLI file output that the session performed, and attach exactly one explicit classification per artifact: `keep-because-<reason>` (durable evidence — state the reason), `clean-now` (execute the `rm` INLINE during closeout BEFORE emitting the output block, then record it as `cleaned-now` in the output's `## Files created this session` section — NOT in `## State Deltas`, which carries Linear-state + new-on-disk-directory deltas), or `clean-by-<date-or-owner>` (must survive this session but has a bounded retention — name the rule explicitly). **Default-keep is forbidden** — every created artifact gets one of the three classifications, silence is not an option. The operating standard is "if you have to create junk files as part of a process, you need to clean them up as soon as that process is done"; Q7 is the closeout walk's enforcement of that directive. The output block's `## Files created this session` section is where Q7's answers land — `_none_` is valid only when the session created no files outside the State Deltas dirs.

   **Q7a — operator-main git-state cleanliness.** Before the closeout output block can write `operator-main clean at <SHA>` (or any equivalent clean-claim line) in `## State Deltas` or `## Running State`, run all three of these checks against the operator-main checkout: `git status --porcelain` MUST be empty, `git diff --cached --quiet` MUST exit 0 (no staged changes), `git diff --quiet` MUST exit 0 (working tree vs index). If any check fails, the closeout walk pauses to either (a) commit / stash / restore the dirty state inline BEFORE emitting the output block, OR (b) explicitly name the dirty state in the State Deltas line (e.g. `operator-main has 1 staged file: scripts/foo.sh (uncommitted)`). **Silent claims of `clean` are forbidden.** A false-RED case study — a stray staged `scripts/check-drift.sh` removal slipping past a prior session's closeout and propagating as a false `make verify` failure into the next session — is what Q7a closes. Its sister rule is the kickoff-side verify-first discipline that caught that propagation: run the verification gates at session start before trusting a prior session's green claim.

If the answer is no, say `no-action` and why. (Q7 itself never short-circuits — even a `no-action` session must enumerate its created files; the only valid Q7 answer for a session that created none is `_none_`. Q7a never short-circuits either — the operator-main git-state checks run before the output block writes any clean-claim line.)
