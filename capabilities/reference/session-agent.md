---
lifecycle: shipped
---

# session-agent — reference

Conditional depth for the `session-agent` capability body
(`capabilities/session-agent.md`). Nothing here is load-bearing: every rule that
MUST fire for a correct orient or route lives inline in the body (skill-authoring
principle 3). This file carries the WHY, the case studies, the per-surface command
alternatives, and the orchestration detail — read it when a body rule is
surprising, when a surface misbehaves, or when routing is genuinely ambiguous
(principle 5: body size is a multiplicative cost, so conditional content lives
here).

---

## Why Mode 1 collects through a script

Mode 1 used to hand-narrate its tracker collection: a query order in prose, a
per-surface command shape, pagination caveats, and a `.state`-shape warning — and
the model re-derived HOW to look on every session before it read anything. That
narration is deterministic work, so it moved into `scripts/orient.sh` (principle
1, script-first). The body now says what to READ from the emitted JSON and what to
do about it; the script header documents the collection contract.

The lessons the narration used to carry, preserved here because they explain the
script's shape:

- **Projects-first, always.** An assignee + In-Progress cut alone misses
  fresh-spawned projects entirely — a just-created project's issues sit in Backlog
  with no assignee, so only the per-project sweep surfaces them. Learned live when
  a kickoff orient reported "no active work" over a freshly-spawned project.
- **The projectless net is not optional.** A standalone issue belonging to no
  project is invisible to the per-project sweep, and unless it is assigned AND In
  Progress it is invisible to the mine cut too. It surfaces only in the global
  open sweep. `orient.sh` runs that sweep and reports the set difference as
  `projectless_open_issues`.
- **Payload shapes have two standing traps (`linear` CLI).** Lists arrive as
  OBJECTS (`{nodes:[…]}` — unwrap `.nodes` before any array filter), and
  `issue query` returns ALL states by default, so every open cut passes
  `-s triage -s backlog -s unstarted -s started` explicitly. `.state` and
  `.assignee` are objects (`.name`); `orient.sh` normalizes every shape in one
  place so no caller has to remember this. See `linear/linear-setup.md` §4.3.
- **Truncation is reported, not hidden.** A projectless issue on page two is
  exactly the one the sweep exists to catch, so a cut that disagrees with the
  project union surfaces as the `open-issue-count-mismatch` anomaly rather than a
  silently short list.

## Tracker surfaces other than the `linear` CLI

`orient.sh` drives the `linear` CLI only. The Linear MCP remains a first-class
operator surface for interactive work (`linear/linear-setup.md` §4 has the
per-surface command shapes); it is simply not the kickoff collection path, because
one deterministic collector beats two narrated ones.

If the operator runs an MCP-only setup, `orient.sh` degrades — `surfaces.linear`
reports `absent` and `degraded` names it — and Mode 1's tracker cut is gathered
through the MCP by hand using the same order the script implements: all projects →
per-project issues → mine + In Progress → global open sweep (drop Done/Canceled
client-side when the surface does not hide them). Filter projects by state TYPE
(`started`, `planned`) rather than state NAME; names vary per workspace.

**MCP edge case.** If the Linear MCP reports ✓ Connected but `list_projects`
returns an empty array, treat it as the silent-empty-MCP-tools failure pattern (a
stale connection returns empty results instead of erroring) — restart the harness's
MCP connection, or fall back to the `linear` CLI, before accepting "no active work"
as the answer.

**Neither surface installed.** The framework degrades: orient continues with memory
+ vault only and a one-line warning names the gap. Document the install in the next
session per `linear/linear-setup.md`.

## Why the vault reads are named individually (O4)

Three notes, three reasons:

1. **`START.md`** — the vault's working rules.
2. **The operator-identity master note.** START.md points at it in prose ("load the
   Operator Soul first"), and a prose pointer is an instruction *chain* agents skip.
   Naming the read as its own mandatory sub-step is the fix: the identity master
   must land every session, not only when the chain is followed.
3. **The lesson index (`04-Lessons/_index.md`).** Lessons were previously
   write-only in practice — sessions distilled lessons INTO the vault at closeout,
   but no orient or routing step ever read one back OUT, so operators re-taught
   rules that were already recorded. The **canonical** index is read rather than a
   generated per-harness view because only the canonical one carries the Trigger
   column; harness scope is applied later, at body-read time, from each matched
   note's frontmatter `harness:` key.

## Why R1a is bounded the way it is

R1a is the read side of the self-improvement loop (closeout is the write side).
Its bounds come from panel findings on earlier drafts:

- **Foreign-scope matches must not starve the recall.** Scope-skipped notes do not
  consume the ~3 applicable-body-read cap; only reads that actually apply do.
- **A post-compaction scan over nothing silently becomes a false `none match`.**
  Hence the rule that a Mode 2 route re-reads the index file when the index is no
  longer in context, instead of declaring from memory.
- **`skipped — <reason>` exists so honesty has a valid option.** A sandboxed run or
  a worktree with no vault mount legitimately cannot recall; declaring `none match`
  there claims a scan that did not happen, and `index unreachable` claims a failure
  that did not occur.
- **Recall failures tune triggers, not rules.** If the operator later re-teaches a
  rule that a recall surface should have matched, closeout records WHICH surface
  failed (not-loaded vs loaded-but-ignored) per `core/self-improvement.md`, so the
  miss rephrases a Trigger instead of duplicating the rule.

## Orchestration sub-routine — full detail

The body states the trigger conditions and the one rule that must fire ("pick the
smallest useful chain"). The full walk:

- **CO1. Classify** the task surface in one sentence: review-only, planning,
  implementation, publish/live, operations, or memory.
- **CO2. Identify constraints:** risk level (auth/billing/secrets/migrations/
  customer-data/public surfaces); output format (code/doc/artifact/dashboard/
  message); evidence needed (tests/browser-render/screenshot/sign-off).
- **CO3. Consult** the installed capability catalog and find the row matching the
  primary surface.
- **CO4. Compose** the chain: one primary; secondaries only for evidence, risk, or
  output format; a verification recipe from `verification/`.
- **CO5. Confirm** with the user only if routing is non-obvious or risk is high.
  Otherwise state the chain and proceed.

Composition rules beyond "smallest chain":

- When surfaces tie, pick the one that **gates** the others — design before
  implementation; debug before refactor; verification last.
- For cross-functional work, route the **starting** surface and surface the next
  chains as follow-ups rather than mashing them into one route.
- High-risk surfaces always get an explicit verification recipe named in the output.
- If no capability fits cleanly, recommend adding one via a skill-creation
  capability — don't force-fit.

When the sub-routine fired, the R5 declaration is extended with the block the body
shows (Surface / Risk / Primary / Secondary / Verification / Next action).

## Why R2b asks HOW, not only WHICH

The delegated-execution method — the orchestrator plans and writes each lane's
four-line brief, executors build, the orchestrator inspects every diff and reruns the
proof itself, and a cross-model critic panel reads the diff for framework or
high-risk work — lived only as an operator-layer FACT. A rule that is loaded but has
no step consuming it gets re-taught every session; the durable fix is a declaration
line the routing walk must fill, which is what R2b's `Execution:` line is.

The three values are role-shaped on purpose. The framework names orchestrator,
executor, and critic; which model fills each role is the operator layer's binding, so
the body stays model-agnostic and survives a change of models.

The rules are a top-down cascade — first match wins, risk BEFORE size — because the
two predicates overlap: a one-line change to an auth path is small and dangerous at
the same time, and a size-first reading would route it `inline`. So rule 1 is the
risk rule. Framework and high-risk changes (auth, permissions, billing, migrations,
secrets, public surfaces) earn `delegated wave + panel` whatever their size, because
a defect there is expensive and hard to walk back and a second model family reading
the diff catches what the author's own review does not; the wave under a one-line
fix is simply a single lane. Rule 2 is the size rule: a multi-file build or ≥2
independent lanes is where an orchestrator's diff inspection pays for itself, since
parallel lanes are where unreviewed work accumulates fastest.

Questions and review-only work never enter the walk: they are `inline` before it
starts, because nothing is being built — no lane to delegate, no diff for a panel to
read. The cascade is for CHANGES, and a change of any size enters it, which is why
rule 1 is a risk test and not a size test. Rule 3 is then the residue — the
single-file build that neither the risk rule nor the size rule claimed.

That ordering is the whole reason the step is a walk rather than a menu. The body
carries the same three rules in the same order; if the two ever disagree, the body
is the contract and this page is the explanation.

The four-line brief contract is `core/operating-system.md` → "Delegating to
subagents"; the executor preamble it prepends is `core/discipline-kernel.md`.

## Token cost

Mode 1 is expensive: one `orient.sh` run plus memory-body reads plus three vault
reads. Mode 2 is cheap — no tool calls beyond consulting the catalog and re-scanning
the in-context lesson index, with R1a body-reads firing only on a trigger match.
That asymmetry is why Mode 1 is one-shot per session: re-running it mid-session
re-pays the orient cost for findings that are already live in context.

## Why the enforcement gate checks only two lines

The pre-edit-gate class checks that session-agent ran and that the `Linear gate:`
and `Lessons:` lines were declared. It does not police the judgment behind them —
the protocol's value is in the model thinking through the steps, not in any single
line. It is a discipline net with a kill switch, not a security boundary, which is
why it enforces the first complete declaration per session rather than re-policing
every Mode 2 route. The `Execution:` line R2b adds sits outside the gate's
check for the same reason: it is protocol the routing walk owes the operator, not an
enforcement surface.

## Notes — honesty rules and mode economics

- **Mode 1 fires once per session.** A mid-session pivot uses Mode 2; an operator
  "re-orient" forces a Mode 1 re-run.
- **Be honest on the Linear gate.** Splitting genuine multi-session work into
  "single-step" to skip the gate defeats the protocol.
- **Be honest on the Lessons line.** `none match` after an actual trigger scan is
  valid; as a reflex to satisfy the gate it defeats the recall step — the line exists
  because already-recorded rules kept getting skipped. `index unreachable` claims a
  failure and `skipped — <reason>` a policy bound; use whichever is true.
- **Be honest on the Execution line.** A value below the rule that fires skips the
  wave or the panel the operator asked for.
- **The gate enforces the first complete declaration per session.** Later Mode 2
  routes re-declare by protocol; the hook does not re-police them — a discipline net
  with a kill switch, not a security boundary.
- **Mode 1 is expensive, Mode 2 is cheap.** Don't re-orient on every prompt.
