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
| `state-delta` | a Linear project (created / closed / status-changed) or new durable on-disk artifact directory came into existence during this session | a `project_*.md` or `runtime_*.md` memory file written BEFORE session exit, plus a `MEMORY.md` index update |

## Promotion Rule

Do not let lessons stay buried in chat, comments, or raw logs.

- If it affects global behavior, update `core/` only with explicit user instruction.
- If it affects one harness, update that harness entrypoint.
- If it is active work, create or update a Linear issue.
- If it is durable knowledge, write it to Obsidian or the long-term vault.
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
4. Does Linear need a follow-up issue?
5. Does Obsidian need a durable note?
6. Did the work reveal a missing silver platter, unclear data path, or unbounded goal-run?
7. **File sweep:** What files / directories did this session create that should NOT survive past it? List every `Write` / `Edit` / `Bash mkdir` / `Bash touch` / `Bash cp` / shell `>` or `>>` redirect / Linear-CLI file output that the session performed, and attach exactly one explicit classification per artifact: `keep-because-<reason>` (durable evidence — state the reason), `clean-now` (execute the `rm` INLINE during closeout BEFORE emitting the output block, then record it as `cleaned-now` in the output's `## Files created this session` section — NOT in `## State Deltas`, which carries Linear-state + new-on-disk-directory deltas), or `clean-by-<date-or-owner>` (must survive this session but has a bounded retention — name the rule explicitly). **Default-keep is forbidden** — every created artifact gets one of the three classifications, silence is not an option. Per [[feedback_clean_operation_no_lingering_junk]] the operator's standard is "if you have to create junk files as part of a process, you need to clean them up as soon as that process is done"; Q7 is the closeout walk's enforcement of that directive. The output block's `## Files created this session` section is where Q7's answers land — `_none_` is valid only when the session created no files outside the State Deltas dirs.

   **Q7a — operator-main git-state cleanliness.** Before the closeout output block can write `operator-main clean at <SHA>` (or any equivalent clean-claim line) in `## State Deltas` or `## Running State`, run all three of these checks against the operator-main checkout: `git status --porcelain` MUST be empty, `git diff --cached --quiet` MUST exit 0 (no staged changes), `git diff --quiet` MUST exit 0 (working tree vs index). If any check fails, the closeout walk pauses to either (a) commit / stash / restore the dirty state inline BEFORE emitting the output block, OR (b) explicitly name the dirty state in the State Deltas line (e.g. `operator-main has 1 staged file: scripts/foo.sh (uncommitted)`). **Silent claims of `clean` are forbidden.** A false-RED case study — a stray staged `scripts/check-drift.sh` removal slipping past a prior session's closeout and propagating as a false `make verify` failure into the next session — is what Q7a closes. See [[feedback_verify_red_first]] (the kickoff-side discipline that caught the propagation) for the sister rule.

If the answer is no, say `no-action` and why. (Q7 itself never short-circuits — even a `no-action` session must enumerate its created files; the only valid Q7 answer for a session that created none is `_none_`. Q7a never short-circuits either — the operator-main git-state checks run before the output block writes any clean-claim line.)
