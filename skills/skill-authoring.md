# Skill Authoring Playbook

Principles for authoring and maintaining skills and capabilities well — and the engineering
disciplines (evaluation, debugging) used while building and fixing them. These are the agnostic
rules this framework already applies implicitly; this doc makes them explicit so a fresh author
(human or agent) reaches the same decisions without rediscovering them.

**Consult when:** writing a new skill/capability, revising an existing one, reviewing a skill change,
or deciding how a skill should process data, delegate, or be tested.

**Non-goals:** this is not a style guide, not a directory layout spec (see [`README.md`](README.md)
and [`skill-template.md`](skill-template.md) for those), and not a mandate to rewrite working skills.
Each principle is a decision rule, not a refactor order.

---

## 1. Script-first skill architecture

**Rule.** When a skill processes data (transcripts, logs, inventories, structured files), offload the
deterministic work — parsing, classification, counting, normalization — to a bundled script that
emits structured output (JSON), and have the model only *present* it. Moving processing out of the
model cuts tokens 60–75%. Keep classification rules in exactly one place (the script); the SKILL.md
must not restate or re-apply them.

**Apply when:** the skill touches >~50 items or files larger than a few KB, the rules are
deterministic (regex / keyword / lookup), or the skill runs often. **Not when:** the skill's core
value *is* the model's judgment (code review, architectural analysis) or the input is unstructured
natural language.

## 2. Pass paths, not content

**Rule.** When an orchestrator skill dispatches subagents that need reference material, have it
discover and pass file *paths* (via glob/search), not file *contents*. Each subagent reads lazily —
only the files and sections it actually needs. Include a standalone fallback (the subagent discovers
paths itself if none were passed). This is lazy evaluation for orchestration: don't pay to read until
you know you need it.

**Apply when:** authoring any orchestration/fan-out skill. **Content-passing is acceptable only**
when the material is small, static, and guaranteed to be fully consumed every invocation (e.g. a
sub-50-line schema the subagent always needs whole).

## 3. Load-bearing rules inline

**Rule.** A rule that MUST fire for the skill to be correct or safe lives in the SKILL.md (capability
body) itself — never only in a referenced file that may not be loaded at runtime. References are for
depth and examples; they are not a safe home for must-fire constraints. Inline the load-bearing
minimum and no more (see principle 5 — every body line has a multiplicative cost).

**Apply when:** a rule's omission would cause a wrong, unsafe, or non-compliant action. If you catch
yourself putting a must-fire gate behind a "see references/…" pointer, pull it inline.

## 4. Structural-not-prose contract tests

**Rule.** Test an authored artifact by asserting its **structure** — required sections present,
token/line budgets respected, cross-references resolve, required fields exist — rather than its exact
wording. Prose assertions are brittle: they break on benign edits and tempt authors to freeze
phrasing. Prefer structural assertions; targeted source-string checks are fine as deliberate
regression anchors (pin a specific bug's fingerprint), not as the primary contract. This is the
`check` lesson class in [`../core/self-improvement.md`](../core/self-improvement.md) made concrete.

**Apply when:** adding any contract test for a skill, capability, doc, or fixture.

## 5. Delegation economics + body size is multiplicative

**Rule.** Delegating implementation/review to a different-model executor (e.g. Codex) carries a fixed
per-batch orchestration overhead (~4–5k tokens) against a variable per-unit saving (~3–5k tokens), so
it only pays off past a **~5–7 reviewable-unit crossover** — below that, do it inline. Separately and
more importantly: **a SKILL.md body's size is a *multiplicative* cost driver** —
`cost ≈ body_lines × tokens_per_line × tool_calls` — because every line is re-read on every tool call
for the whole session. Move conditional content (>~50 lines, used in a minority of invocations) to a
reference file; keep only always-needed content inline (this is the tension partner of principle 3).

**Apply when:** sizing a skill body, deciding whether to add guidance to a body vs a reference, or
choosing between inline execution and Codex delegation. A "helpful" 50-line addition to a body can be
net-negative even when its advice is sound.

## 6. Python over bash for NEW pipeline scripts

**Rule.** For a *new, standalone* multi-step pipeline script — one that chains 2+ external CLI tools,
needs retry or graceful degradation, has >~3 subcommands, or must be testable from a non-shell
runner — prefer Python. Its explicit `subprocess` error handling avoids the bash `set -euo pipefail` +
command-substitution footguns that bite on different OS/bash versions. Bash stays correct for
one-liners, simple sequential scripts, and git/CI steps where "abort the pipeline" is the only failure
mode.

> **Non-negotiable framework caveat.** This does **not** apply to the framework's own shipped scripts.
> Those are intentionally maintained as **bash ↔ PowerShell twins** for cross-OS parity
> (`CONTRIBUTING.md` sets the Bash 3.2 + PowerShell 7+ conventions; the framework convention is that
> any logic or denylist change to a shipped script is mirrored in its `.ps1` twin). This principle is
> forward-looking guidance for *new standalone* pipeline scripts,
> not a license to introduce Python into — or drop the PowerShell twin of — any paired framework
> script. The framework adopts Python only if and when it adds it as a deliberately paired surface.

**Apply when:** starting a new pipeline helper outside the twin-script set.

## 7. Eval-harness methodology

**Rule.** When claiming a skill change improved triggering or output quality, measure it: **variance
matters more than a single rate-shift**, so run **N≥3** trials on ambiguous fixtures and use a snapshot
A/B harness (old vs new, e.g. under `/tmp`) rather than trusting one run. A single passing run is an
anecdote, not evidence.

**Apply when:** tuning a skill's description/triggering, or claiming a behavior change is an
improvement. **Not when:** the change is purely structural and verified by a deterministic check.

**Tiers — catch 95% for free, spend model calls only on judgment.** Layer skill verification so the
cheap checks run always and the expensive ones run only when asked:

1. **Tier 1 — static validation** (free, always-on, CI-gated): structural contract tests (principle 4),
   frontmatter/shape lint, link/reference resolution. Deterministic; no model call.
2. **Tier 2 — end-to-end**: spawn a real agent in the target harness and run the skill against
   fixtures, asserting on its structured output. Slow and nondeterministic — apply principle 7's N≥3 +
   variance-over-rate-shift discipline.
3. **Tier 3 — LLM-as-judge**: score doc or output *quality* with a model only where the property is
   judgment, not a deterministic check. Slowest and least stable.

Gate Tiers 2–3 behind an **`EVALS=1`** env flag so the default inner loop and the public CI stay fast
and free; Tier 1 is the always-on gate, 2–3 are opt-in.

**Harness-native runners — do NOT hardcode `claude -p`.** The framework is harness-agnostic, so a
Tier-2/3 runner is defined per harness, not copied from one CLI to another. Sketch:

- **Claude:** `claude -p "<prompt>" --output-format json` (or the Agent SDK); assert on the JSON.
- **Codex:** `codex exec --skip-git-repo-check "<prompt>"` with the fixture piped via **stdin**, never a
  file-read prompt (those can hang `codex exec`); assert on its final stdout, or use `--output-schema` /
  `--json` when you need schema-stable fields or event-level checks rather than freeform prose.

Do not copy the Claude E2E verbatim into the Codex lane — invocation, output shape, and hook semantics
differ between harnesses.

## 8. Causal-chain debug discipline

**Rule.** When a skill or script fails, three gates before you "fix" it: (a) **causal chain** — state
how the suspected cause actually produces the observed symptom before changing anything; (b)
**prediction for uncertain links** — for any step you're unsure of, predict the observable *before*
you test it, so a surprise teaches you something; (c) **environment-sanity checklist** — confirm the
basics first (right directory, right tool on `PATH`, right env/keys, right OS/shell) before deep
debugging. Change one thing at a time.

**Apply when:** debugging any skill/script failure, especially cross-harness or cross-platform.

## 9. Agent-CLI rubric (reference)

**Rule.** When choosing or building a CLI for agent use — or judging a third-party tool's
agent-fitness — apply this 7-point rubric. It operationalizes the CLI-over-MCP policy in
[`../core/tool-use.md`](../core/tool-use.md):

1. **Non-interactive by default** on automation paths — detect no-TTY (or honor `--no-input`); never block on a prompt.
2. **Structured, parseable output** — offer a `--json`/machine-readable mode alongside human output.
3. **Progressive help discovery** — `--help` at each level reveals the next; an agent can self-orient.
4. **Fail fast with actionable errors** — exit non-zero with a message that names the fix, not a stack trace.
5. **Safe retries + explicit mutation boundaries** — re-running a read is free; mutations are idempotent or explicitly flagged.
6. **Composable, predictable command structure** — consistent `noun verb --flag` shape; pipe-friendly.
7. **Bounded, high-signal responses** — output is scoped/paginated; an agent pays real tokens for every extra line.

**Apply when:** adding a CLI dependency, wrapping a tool for a skill, or evaluating whether a CLI
beats an MCP for a job.

## 10. Git-workflow skills as explicit state machines

**Rule.** A skill that automates version-control flows (commit, push, PR, branch/worktree cleanup) must
model the workflow as an **explicit state machine** — re-read the relevant state at each transition
boundary and branch on that result, rather than observing state once and carrying it forward in prose.
Git state is multi-dimensional and mutating commands change it, so an early observation goes stale.
Name each dimension and its failure state, and re-check at the point of decision:

- **Working-tree cleanliness** — derive from `git status` (covers staged, modified, *and* untracked
  files); never `git diff HEAD`, which is blind to untracked-only work.
- **Branch identity** — re-run `git branch --show-current` *after* any branch-changing step. Detached
  HEAD is its own state: `git push -u origin HEAD` is invalid from it (HEAD doesn't resolve to a branch ref).
- **Upstream vs unpushed** — "no upstream configured" and "nothing to push" are different states;
  confirm `@{u}` exists *before* counting unpushed commits, and treat that count as only as fresh as
  the last fetch — a stale remote-tracking ref misreports "nothing to push" / "behind".
- **PR existence** — tie detection to the current branch (`gh pr view`), not a bare branch name
  (`gh pr list --head` can match another fork's reused name). Treat an expected "no PR" non-zero exit as
  a normal state transition, not a failure.
- **Default-branch & worktree safety** — every path that can reach push/PR (including "clean tree but
  unpushed commits" shortcuts) passes the default-branch guard first; if the user declines to create a
  feature branch off the resolved default branch, that is a *stop*, not a continue. And remove the
  *attached worktree* (`git worktree remove`) before a `--delete-branch` merge — otherwise the
  branch-deletion step fails even though the merge itself succeeds.

**Apply when:** authoring or editing any skill/capability that drives `git` or a host VCS CLI (`gh` in
the examples is the GitHub adapter; the invariant — branch identity, upstream, PR/MR existence,
default-branch and cleanup safety — is host-neutral). The highest-risk surface is the "clean working
tree but maybe still work to do" shortcut — it combines the most state dimensions at once; after
touching any single transition, walk all adjacent states before considering the change done.

## 11. Promoting a successful ad-hoc flow → skill (the trust contract)

**Rule.** When a one-off flow ran successfully and is worth keeping, do not auto-promote it into a
permanent skill. Promotion is a **trust contract**: an unvetted skill that silently auto-installs is
the failure mode — it ships unproven behavior under a name future sessions will trust on sight. Walk
these **seven staged steps in order**; the **fixture-test** and **explicit-user-approval** steps are
**NON-OPTIONAL** and must not be collapsed, reordered, or skipped — they are the two gates that protect
trust:

1. **Provenance guard.** Confirm the flow actually succeeded *and* is repeatable before promoting.
   Name the concrete successful run (the session, the inputs, the observed correct output). A flow run
   once is an anecdote (principle 7's logic applies to behavior, not just triggering) — a skill is a
   standing promise, so a single lucky run is not promotable. Reject promotion of flows whose success
   you cannot point to.
2. **Synthesize a deterministic script from the flow.** Extract the flow's deterministic work
   (parsing, classification, counting, ordered command steps) into a bundled script that emits
   structured output, per principle 1 (script-first) — the model only *presents*. A flow that is
   purely model judgment with no deterministic spine is usually not a promotion candidate; if you must
   promote one, say so explicitly and skip to step 4 with the SKILL.md body carrying the load-bearing
   rules inline (principle 3).
3. **Fixture test (NON-OPTIONAL).** Capture the successful run's input as a fixture and assert the
   synthesized script reproduces the known-good output — a structural assertion per principle 4, not a
   prose match, and preserving the source's line shape so detection cannot silently no-op. No fixture,
   no promotion. This is the mechanical half of the trust contract: it proves the script actually does
   what the ad-hoc flow did before a future session relies on it.
4. **Temp staging.** Build the candidate skill in a temporary/staging location (e.g. under `/tmp`,
   mirroring principle 7's snapshot A/B harness), never directly into the live skill set. Promotion
   touches the harness's trusted capability surface; stage first so a failing candidate never lands
   where the router can pick it up.
5. **Test must pass.** Run the step-3 fixture test (and any triggering/quality eval from principle 7)
   against the staged candidate. A failing or absent test is a hard stop — the promotion does not
   proceed to approval. Do not paper over a red test by weakening the assertion.
6. **Explicit user approval (NON-OPTIONAL).** Present the staged candidate — what it does, the fixture
   evidence from step 5, where it will install — and get explicit user sign-off before any write to
   the live skill set. This mirrors the `rule` / `playbook` lesson-class gate in
   [`../core/self-improvement.md`](../core/self-improvement.md): shared, trusted framework surface is
   never modified on the agent's own authority. Silence is not approval; a passing test is not
   approval. No approval, no promotion.
7. **Atomic commit.** Only after approval, move the staged candidate into the live set and commit it
   atomically with its fixture and test together — never the skill without the test that vouches for
   it. Author the live skill via the skill-creation capability (`skill-creator`) so it lands in the
   canonical shape (this playbook supplies the *promotion lifecycle* and the principles; `skill-creator`
   supplies the *authoring mechanics* — they compose, they do not overlap).

**Apply when:** a session ran a flow worth keeping and you (or the user, or the closeout walk) ask "is
this worth promoting to a skill?". The closeout walk surfaces this question and routes it through the
`skill` lesson class (see [`../capabilities/closeout.md`](../capabilities/closeout.md) and the `skill`
class in [`../core/self-improvement.md`](../core/self-improvement.md)). **Not when:** the flow is a
genuine one-off with no foreseeable reuse (do not manufacture reuse to justify a skill — that is the
EAD-gate's "should have eliminated this" failure inverted), or when an existing skill already covers it
(extend the existing one instead of forking a near-duplicate).

---

## 12. Escape hatches: rules-bearing skills state when to break the rules

A skill that imposes standing *default* rules on output or behavior — an output style, a
review discipline, a mode — must state explicit override conditions: the cases where a
rule fights the task and the task wins while the shape stays (e.g. "when asked to
explain, explain fully — still no preamble"). Without them, rule-following deletes
answers: the model obeys the letter of a brevity rule and drops the option list that WAS
the answer. Overrides run in both directions — some loosen a rule (explain fully), some
tighten one (a no-questions rule still stops and confirms before a destructive action) —
name both kinds. The list is small and concrete — name the situations, not a vague "use
judgment" — and short: §5's multiplicative body-size cost applies to this section like
any other.

**Defaults are overridable; invariants are not.** Safety, authorization, and
irreversible-action gates are hard invariants — a skill that carries both classifies
which is which, and no escape hatch ever loosens an invariant in service of task
completion. Precedence when rules collide: hard invariants, then explicit user
direction, then task completeness, then stylistic defaults.

Mode-like skills (rules that persist across turns) additionally state their persistence
contract: when the rules apply, when they lapse, and a canonical off-switch phrase —
discoverable and documented, while unambiguous semantic equivalents ("go back to
normal") also deactivate; exact-string matching alone is brittle. A mode without a
stated off-switch either dies silently after a few turns or outlives the user's intent;
both are trust failures. Wire it to §4: a rules-bearing skill's contract test asserts
the override section exists, and for mode skills that the off-switch is stated.

**Apply when:** authoring or reviewing any skill whose body is standing rules the model
keeps following across turns or outputs. **Not when:** the skill is a one-shot
procedure that ends on its own — a script-first pipeline (§1), a git-workflow state
machine (§10), a single-run generator. The boundary is the rules' lifetime, not the
skill's architecture: a procedural skill that ALSO imposes standing output rules needs
the section for those rules.

(Pattern source: the MIT-licensed `i-have-adhd` skill's "When to break the rules" +
"Persistence" sections — adopted 2026-08-02, hardened by a three-family panel review.)

---

## 13. Context pointers: the wording decides when material is reached

**Rule.** Any reference an agent holds in context that names out-of-context material — a skill
description, an index row's trigger column, a "see X when Y" line in an entrypoint doc — is a
**context pointer**, and its *wording* — far more than the quality of its target — decides whether
the material is ever reached. A must-have target behind a weakly worded pointer is a variance bug:
some runs reach it, some don't. For material that legitimately lives behind a pointer, **sharpen the
wording first; inline only if sharpening fails** (inlining pays §5's multiplicative cost forever).
This never overrides principle 3: a load-bearing, must-fire rule belongs inline from the start —
pointer tuning is for the reference depth around it, not the gate itself. A pointer does two jobs: say what the material is, and name the
distinct trigger cases — front-load the words that do the triggering work, collapse synonyms that
rename one case, and cut identifying description the target's own body already carries, because an always-loaded
pointer costs tokens on every turn whether or not it fires. The trigger-case job has a negative side:
a skill description may also name its **anti-triggers** (what the skill is NOT for), but only where a
genuine routing boundary exists — a neighboring skill whose trigger space overlaps ("NOT for X — that
is skill Y"). An anti-trigger marks a real boundary between overlapping skills, never an enumeration
of every irrelevant task; each clause pays the same always-loaded cost as the rest of the pointer.
A description may also carry a **path-keyed MUST-use trigger**, binding the skill to a path domain
("editing anything under path X → this skill MUST be used"). The routing-boundary discipline holds
here too, with its own concrete test: the skill must genuinely own the path domain — it is the single
designated authority for that domain, and no other skill's description or trigger row claims an
overlapping path — the same path, an ancestor, or a descendant (a competing claim means resolving
ownership first, never shipping a second MUST) —
and the claim is never a blanket over paths the skill does not truly own. Each path clause, like each
anti-trigger, marks a real boundary and pays the always-loaded cost.

**Apply when:** writing or tuning any skill description, index trigger row, or entrypoint pointer —
and *before* concluding that under-triggering material must move inline. Measure a re-phrase with
principle 7's N≥3 harness, not a single anecdotal fire.

## 14. Completion criteria carry the quality bar

**Rule.** Every step in a procedural skill ends on a **completion criterion** — the condition that
tells the agent the step is done — and that criterion, more than the step's imperative, sets how much
work actually happens. Two properties make it load-bearing: **clarity** (can the agent tell done from
not-done? a fuzzy bound like "understanding reached" invites ending early, with attention pulled
forward by the visible later steps) and **demand** (how much the bound requires: "every modified file
accounted for" forces digging that "produce a change list" never will). Prefer criteria that are both
checkable and exhaustive; when a step keeps finishing prematurely, sharpen its bound before
restructuring the skill. Demand also binds flat reference bodies ("every rule evaluated — applied or
explicitly inapplicable"), so even a no-steps skill carries an exhaustiveness bar.

**Apply when:** writing or reviewing any skill step, checklist item, or gate — especially after
observing a skill rush past a step in live runs. §4's structural tests assert a criterion *exists*
and states a checkable bound; whether it actually induces the work is behavioral — measure that with
principle 7's harness, not a lint.

## 15. Leading words, stated positives, and no-op pruning

**Rule.** Three prompt-layer levers that decide whether a body line earns its multiplicative cost
(§5):

- **Leading words.** A compact concept the model already holds (*tight*, *red*, *frontier*,
  *fixture*) anchors a whole region of behavior in a single term — repeated verbatim, never
  re-explained, with the surrounding text pinning which sense is meant.
  Prefer an existing word over coining one (a made-up term pays in definition tokens what a
  pretrained word carries for almost nothing), and hunt for multi-sentence restatements that collapse into one
  ("fast, deterministic, low-overhead loop" → "a *tight* loop").
- **State the positive.** Steering by prohibition drags the forbidden behavior into context and makes
  it *more* available ("don't think of an elephant"). Phrase the target behavior instead ("write
  one-line comments" beats "don't write long comments"); keep a prohibition only as a hard guardrail
  you cannot phrase positively, and pair it with its positive target.
- **No-op pruning.** An instruction the model already obeys by default pays cost to say nothing. The
  test — does the line change behavior versus the default? — is settled by running the skill
  (principle 7), not by debate; delete failing sentences whole. Exception: a rare-path or safety
  guardrail whose trigger your trials never exercised is not a proven no-op — absence of effect on
  the happy path is not evidence (§12's invariants stay). Two adjacent prunes: don't restate
  what the environment already answers cheaply (`--help` output, config files, directory layout —
  a doc that caches a cheap lookup goes stale; point at the authoritative lookup and cache only the
  unwritten convention or the gotcha), and watch for **sediment** — stale layers surviving because adding feels safe and removing feels
  risky.

**Apply when:** writing or reviewing any skill body, capability body, or agent-consumed doc — and in
any review that flags a body as over-budget (§5): apply these levers before cutting substance.

(Pattern source for §§13–15: the MIT-licensed `mattpocock/skills` repo's `writing-for-agents`
reference — concepts adopted and adapted 2026-08-07; wording ours.)

---

## Related

- [`README.md`](README.md) / [`skill-template.md`](skill-template.md) — the skills catalog and entry shape.
- [`../core/tool-use.md`](../core/tool-use.md) — CLI-over-MCP policy that principle 9 operationalizes.
- [`../core/self-improvement.md`](../core/self-improvement.md) — the `check` lesson class (behind principle 4) and the `skill` class, which routes authoring guidance like this doc into `skills/` and is the home of the promotion trust contract (principle 11).
- [`../capabilities/closeout.md`](../capabilities/closeout.md) — the closeout walk surfaces "did a successful repeatable flow run worth promoting?" and routes it through the `skill` class into principle 11's trust contract.
- [`../verification/code-change.md`](../verification/code-change.md) / [`../verification/docs-framework.md`](../verification/docs-framework.md) — proof recipes for the artifacts these principles produce.
- [`../playbooks/github-housekeeping.md`](../playbooks/github-housekeeping.md) — the branch/worktree/PR hygiene flow principle 10 applies to.
