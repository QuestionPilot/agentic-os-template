---
lifecycle: shipped
---

# closeout — reference

Conditional depth for the `closeout` capability body (`capabilities/closeout.md`).
Nothing here is load-bearing: every must-fire gate, question, class, and write rule
lives inline in the body (skill-authoring principle 3). This file holds the WHY, the
case studies that produced each rule, and the formatting detail a closeout consults
only while composing a drain (principle 5).

---

## Why Q0 runs first

Q0 is the EAD gate (Eliminate / Automate / Delegate). It runs before the
classification walk because if the honest answer is "we should have eliminated
this", the right outcome is `no-action` with a rationale — and walking the
classification machinery for work that should never have shipped is wasted effort.
The principle behind it is named in `core/operating-system.md` → `## Boring is
Beautiful`.

What Q0 does NOT skip is anything with an external consequence: State Deltas, the
Q7 file sweep, Q7a git-state verification, Linear updates, and the output block all
run regardless. Junk files survive a `no-action` close just as readily as a
substantive one, and a stray staged change propagates to the next session as a
false-RED either way.

## Q1a — why recall failures are classified as recall failures

When the operator has to re-teach a rule that already existed somewhere, the
tempting move is to write the rule down again. That produces a duplicate and leaves
the retrieval path just as broken. The lesson is always about the surface:

- **not-loaded** — store silo, stale harness index, vault unreachable, lesson index
  skipped at O4. Fix store placement or orient discipline.
- **loaded-but-ignored** — the rule was in context and was acted against. Rephrase
  the lesson's Trigger / headline so the next session-agent R1a scan matches it.

The `self-audit` recall-efficacy check counts these, so they must be recorded
explicitly in the session log's Lessons section rather than folded into a generic
"we learned X".

## Q3a / Q3b — why two capture questions instead of one

Q3a fires on **repetition** (a multi-step procedure ran again) and Q3b fires on
**quality** (a deliverable was notably better than the usual bar). They are separate
because they miss different things: repetition without quality produces a boring but
reusable procedure; quality without repetition produces a method that strands
because nothing forces it to surface. A method that fires both is ONE lesson — log
it once.

Q3b requires an observable signal — operator reaction, a comparative result, an
independent review. A retrospective vibe is not a trigger. When it fires, mine the
session for the *method*: what was thought about (the framing, the decomposition,
the checks that were weighed) and how it was proven (the evidence that made the
result trustworthy). Label the reconstruction as inferred unless the session
actually demonstrates it. The common landings are a `skill` candidate row (a
repeatable procedure) or a `playbook` proposal (a workflow), but any class the table
assigns is equally valid.

**Write boundary on the Q3b path:** the Q3a catalog candidate row is the ONLY direct
write. Every other landing is proposal-only — propose path + body and get explicit
user approval before any write.

**Why the candidate row goes to the catalog SOURCE:** on harnesses whose rendered
catalog is build-manifest-managed, a hand edit to the rendered catalog trips the
drift gate. Each harness realization names the concrete source destination.

## Q4a — the semantic-drift case study

A whole-system review once flagged five vault project notes at once that had passed
the structural audit while misdirecting the next agent that loaded them: each note's
status field said Completed, but its prose still read "currently", "next step is",
"treat X as the active successor". A mechanical audit cannot catch prose tense, so
the Q4a edit — performed in the same session as the transition — is the only gate.

The reverse transition carries the mirror duty. A project that becomes active again
with no live project-type memory note is invisible to the next orient's body-read
step; a recreated memory note alone is machine-local, so the vault project note is
flipped back to active in the same pass to make the reactivation visible beyond this
machine. A project reactivated and then completed within the same session nets out
through the Q4a terminal edit alone — no note recreation.

## Q7a — the false-RED case study

A stray staged `scripts/check-drift.sh` removal slipped past one session's closeout
and propagated into the next session as a false `make verify` failure. Q7a closes
that window on the write side; its sister rule is the kickoff-side verify-first
discipline that caught the propagation — run the verification gates at session start
before trusting a prior session's green claim.

## Why the drain writes but the `obsidian` class proposes

The `obsidian` lesson class stays **propose-don't-write** for a lesson distilled
fresh from the transcript into a curated note, because the transcript is
mixed-origin untrusted text and that path carries the laundering risk the rule
exists to stop.

Two paths are different and DO write:

1. **The session-log drain.** It is append-only — a brand-new uniquely-named file
   each session — so it never edits or overwrites operator-curated memory. It
   captures the *candidate* lessons/decisions so nothing is lost even when their
   promotion to a curated note is deferred.
2. **Feedback/decision-note promotion (distillation).** A `feedback_*` / `decision`
   note is the agent's own curated single-fact note, not mixed-origin transcript
   text. Promoting it into `04-Lessons` is the cache→durable flow the Cache Contract
   (`core/memory-model.md`) prescribes. The safety does NOT rest on assuming the
   note was scanned when written — it may have been edited since, or written via a
   path that skipped the scan — so closeout RE-RUNS the injection scan at
   distillation time over both the source note and the folded lesson.

Without distillation, feedback written in the TAIL of a session strands:
raw-archived by the drain but absent from the hot Lessons layer until a periodic
batch runs, and lost outright if a machine wipe lands first.

**Why the completeness guard is not in `make verify`.** A mid-session store
legitimately holds not-yet-distilled notes (this session's, distilled at this
session's close), so a per-push gate would false-fail. `check-distillation-completeness`
is an operator-invoked guard run at the wipe / migration boundary, the way
`check-clean.sh` runs at the CI boundary.

## Drain — pre-flight, identity, and body shape

### Pre-flight (before writing)

The vault may live on cloud storage (Google Drive, Dropbox, iCloud) with no git.
Guard against split-brain:

- **Reachable + synced-down:** confirm `$OBSIDIAN_VAULT_PATH` exists and is fully
  synced down. If the path is missing or the provider is mid-sync, FLAG and do not
  write a half-state.
- **Conflict-copy scan:** if the vault holds provider conflict copies (names like
  `foo (1).md` or containing `conflict`), surface them — a prior write may not have
  converged. Resolve or FLAG before adding more.
- **Operator-serialized:** only one machine runs `closeout` at a time. Because each
  session writes its OWN uniquely-named file, serialized closeouts never collide.

### Identity

- Generate a stable **`closeout_id`** once (e.g. `openssl rand -hex 4`). It ties the
  log ↔ the Linear closeout comment ↔ the commit ↔ the transcript; put it in the log
  frontmatter AND in the Linear comment.
- Machine id via `hostname` (short form).
- Capture the harness's real session/transcript id into frontmatter when the harness
  exposes it; otherwise leave it empty — the `closeout_id` carries filename
  uniqueness regardless.

`HHMMSS` + `<machine>` + `<closeout_id>` in the filename make it globally unique and
filename-sortable (it survives cloud-storage mtime drift).

### Body shape

Reuse the vault's `80-Templates/session-summary.md` shape, extended with a
**per-issue section** (operator requirement). Frontmatter: `title` (quoted), `date`,
`machine`, `harness`, `session_id`, `closeout_id`, `linear` (issue ids touched),
`tags: [<vault>/session]`. Sections:

- `## TL;DR` — one line.
- `## Issues this session` — for each issue touched, an `### <ISSUE-ID> — <title>`
  with **Why this issue exists / What we did / Where it stands** (+ PR or commit).
- `## Decisions locked` — durable decisions (note which were drained to
  `03-Decisions/`).
- `## Files / systems changed` — repos@sha · PR urls; vault notes touched.
- `## Verification` — what was run/proven; name skipped checks.
- `## Raw observations` — the quarantine section (see the body's trust model).
- `## Pick up here` — one sentence: the next concrete action.
- `## Links` — project note · Linear · decisions/lessons.

### Why the two wikilink rules exist

- **No cross-layer wikilinks.** The vault audit resolves every wikilink against the
  vault, and a harness memory-store filename (`project_*` / `feedback_*` /
  `reference_*`) is a guaranteed broken link there. When a memory-store reference
  has a vault counterpart, wikilink the vault note and backtick the memory-store
  name alongside it.
- **Full-path wikilinks.** The vault audit registers each note only under its full
  vault-relative path (with or without the `.md`/`.base` extension) and, for a note
  at the vault root, its bare name — it does not resolve a subdirectory note by
  basename the way an Obsidian-style UI does. A bare-basename link to a subdirectory
  note either fails the audit or, worse, silently resolves to a root-level note that
  happens to share the name.

Both rules are now enforced by `scripts/check-wikilinks.sh`, which resolves links
the SAME way the vault audit's `checkWikilinks` does and prints a suggestion when a
basename is unambiguous. A memory-store name wrongly written as `[[name]]` fails
closed — the intended enforcement of the first rule.

### Why the machine-path scan has no raw-evidence exemption

A session log is durable, cloud-synced, and read by every harness, so a machine path
under `## Raw observations` is still a machine path in the durable log. The whole
file is scanned. `scripts/check-machine-paths.sh` mirrors the vault audit's
`checkAgnostic` rule — it flags a home path with a real username segment while
leaving a URL path and a lone `Users` token in prose untouched.

### Why the gates are wrapped

Composing the checks by hand at write time is exactly where one silently gets
dropped: a skipped gate looks identical to a passed one in a transcript, and the
miss surfaces only on the NEXT vault audit — after the artifact already landed.
`scripts/closeout-gate.sh` makes the SET the unit. Its fail-closed asymmetry matters:
a check that runs and reports a finding FAILS, a check whose *script* is absent also
FAILS (a gate that cannot run has proven nothing), but a check whose *target surface*
is absent (no vault for the wikilink check, no memory store for the project-note
budget) is a NAMED SKIP. Read the script header for the full contract.

The project-note budget is the one check that scans something other than the draft.
It measures the memory store, because that is the file closeout is about to grow:
the self-audit already reports the same per-note budget, but as an advisory warn
read after the fact, in a different session from the write that caused it. Moving
the same measurement to write time puts the finding in front of the session that
can act on it, and keeps the two in agreement by construction — both classify a
note by its frontmatter `type:`, and both read the same
`PROJECT_NOTE_BODY_WARN_KB` knob.

The injection scan itself is belt-and-suspenders, not the primary defense: it catches
BARE, line-leading directives — the shape verbatim-pasted hostile tool/web text takes
— and has accepted false-negatives (fenced/quoted, Unicode-whitespace-obfuscated, or
heading-embedded payloads). The primary defense is the provenance + quarantine
discipline in the body: do not paste untrusted text into a trusted section in the
first place.

## Detail moved out of the body (skill-authoring §16)

The body states the goal, the done test, and the boundaries; the enumerations a
reader can reconstruct from the pointed-at canonical file live here.

### Inputs — what a "new durable on-disk artifact directory" looks like

A fresh `cross-model-out/<YYYY-MM-DD>-<slug>/` run dir, a new `docs/plans/<name>.md`.

### Q3 — the seven steps of the promotion trust contract

Provenance -> synthesize a script -> fixture test -> temp staging -> test must
pass -> **explicit user approval** -> atomic commit. The fixture-test and
explicit-approval steps are non-optional; never auto-promote an unvetted flow into
the trusted skill set. Canonical: `skills/skill-authoring.md` principle 11.

### Q4 — what "full metadata at create time" means

Project, deliberate priority, at least one label, assignee, a relation back to the
spawning issue; the template's deliberately-projectless / deliberately-unassigned
escapes apply. Closeout speed is how bare issues are born, which is why the
follow-up issue conforms to the canonical standard rather than to whatever is
quickest at 2am.

### Q7 — worked classification examples

- `keep-because-<reason>`: `keep-because-cross-model-out-run-dir`,
  `keep-because-PR-artifact`.
- `clean-by-<date-or-owner>`: `clean-by-2026-06-25`.

Default-keep is forbidden — every created artifact gets one of the three
classifications; silence is not an option.

### Pre-write gate — what remediation looks like

Move a flagged payload under `## Raw observations` or drop it, fix each unresolved
link to its full vault-relative path, replace each machine path with an agnostic
reference (repo-relative, home-relative, or vault-relative), trim the over-budget
project note — then re-run.

### Distillation — why the `## Source Notes` linkage is separator-tolerant

The completeness guard normalizes separators, so either slug style
(`feedback-foo-bar` / `feedback_foo_bar`) resolves against the same lesson.

### Why the vault audit stays clean after a drain

The vault's audit (`bin/memory-vault-audit.js`) stays clean after a drain: session
logs are append-only archives, so its orphan check exempts `30-Archive/Sessions/`.

## Why closeout has no enforcement hook

The prior auto-enforcement was a `Stop` hook with memory-path and Q7-cleanup
exemptions. It was removed because it re-fired on closeout's own
protocol-prescribed writes — the state-delta memory writes that cite framework
files, and the Q7 cleanup `rm` — looping a normal session. The gate was built up
incrementally, then removed in favor of discipline-backed closeout. The discipline
lives in the session-agent kickoff orientation and in the agent/operator
remembering, not in a hook.

Related: the transcript is the marker that closeout ran — there is no
"closeout-ran" marker artifact to write. The session-log drain is different: it
writes durable session *content* to the vault, not a ran-marker.

## Memory hygiene — why refresh beats append

`consolidate-memory` runs the same Keep / Update / Consolidate / Replace / Delete
lifecycle as a periodic full-store sweep; at closeout the scope is only the notes
the session actually wrote. Canonical definitions are in `core/memory-model.md`;
closeout is the write-side enforcement point. Pre-existing findings in untouched
notes route to a `consolidate-memory` follow-on rather than blocking a closeout —
a closeout that has to fix the whole store stops happening.
