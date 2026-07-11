---
name: session-agent
summary: Auto-fires at session start to orient the AI (memory + Linear + vault + reconcile session-start hints), then routes the user's prompt to the smallest useful capability chain. Subsequent prompts re-invoke to route without re-orienting. Single capability for kickoff + routing + orchestration; subsumes route + skill-orchestrator.
triggers: [start of any session, first action on any session, before the first file-modifying action, start of any non-trivial task, a task pivots significantly mid-session, several capabilities could apply, a task spans multiple surfaces, the user asks which capability to use, the enforcement gate asks for session-agent, when the framework session-start hook directs you here]
verification: none
harnesses: [claude, codex, hermes]
kind: native
enforcement: pre-edit-gate
lifecycle: shipped
---

# Session Agent — Session Kickoff Orient + Routing

The session-agent capability is the spine of every non-trivial task. **It auto-fires
at session start** (the framework session-start hook emits a directive in additional
context instructing its invocation as the first action). It then re-invokes on every
non-trivial prompt to route the request to the smallest useful capability chain.

**Two modes, one capability.** The body teaches both — which one to use is
determined by whether session-agent has already run this session.

| Mode | When | Job |
| --- | --- | --- |
| **Mode 1 — Kickoff orient** | First invocation per session (no prior `session-agent` invocation in transcript) | Orient: memory + Linear + vault + reconcile session-start contradictions. Then route the user's first request (steps R1–R5 below). |
| **Mode 2 — Route only** | Every subsequent invocation in the same session | Just route (steps R1–R5). Skip the orient — Mode 1's findings are still live in context. |

**Determining which mode:** if you have not invoked `session-agent` earlier in
this session, run Mode 1. Otherwise run Mode 2. Each harness's realization
documents how its enforcement hook detects prior invocation — see
`harnesses/<h>/capabilities/session-agent.md`. Mode 1 is one-shot per session;
re-running it mid-session re-pays the orient token cost without value.

---

## Mode 1 — Kickoff orient

Run these five sub-steps in order. Each names the specific tool calls to make.
Skipping a sub-step is a Mode 1 failure — re-run the missed sub-step before routing.

### O1. Read project memory bodies for active-work projects

The harness autoloads `MEMORY.md` — a one-line index of headlines. **Headlines are
not the source of truth.** For any project-type memory note (`metadata.type: project`)
referenced there whose headline names active or recently-active work, read the file body before acting on the
headline. Cross-issue Linear claims embedded in those bodies (e.g. "`<PREFIX>`-X is
Done", where `<PREFIX>` is your workspace's tracker issue prefix) are particularly
stale-prone — Mode 1's O5 step re-checks them against Linear.

**Tool calls:**
- For each project-type memory note (`metadata.type: project`) referenced in `MEMORY.md` whose headline names active work: `Read` the absolute path under the harness config dir's `projects/<project-slug>/memory/` directory. Detect the kind by frontmatter `metadata.type`, not a `project_*.md` filename glob — the auto-memory store is kebab-named.
- Do NOT re-read `reference_*.md` / `feedback_*.md` bodies at kickoff — those are headline-stable.

### O2. Reconcile session-start hints against memory headlines

The framework session-start hook surfaces the last 7–10 days of `agentic-os-template` commits
in `additionalContext`. Scan those commits for tracker issue identifiers — the
`<PREFIX>-<number>` shape, where **`<PREFIX>` is your workspace's issue prefix**
(your Linear team key; recorded as `TRACKER_ISSUE_PREFIX` in `local.env`). `TEAM`
is only the framework documentation placeholder — a literal `TEAM-\d+` match finds
nothing in a real workspace, which silently disables this whole reconciliation
step. For any such identifier whose parent project's memory headline says
`COMPLETE` / `CLOSED` / `DONE`, that's a contradiction — flag it in the first turn
and dig before trusting the memory headline. Memory captures what was true when
written; the session-start window captures what is true now.

**Tool calls:** none specific — this step reads the session-start-injected context
that is already in the model's first turn and compares against the memory bodies
read in O1.

### O3. Kickoff Linear query — projects-first ordered cut

Use whichever Linear surface the operator installed per `$AI_CONFIG_DIR/linear/linear-setup.md` —
`lineark` CLI or Linear MCP. Both are first-class; the framework prefers `lineark`
for token cost but does not require it.

**Query order (surface-agnostic):**

1. **List all Linear projects.** Surface-dependent: the `lineark` CLI returns the
   full project set with **no per-project state field and no state filter** (only
   `--led-by-me`) — do not try to pre-filter projects by state against it. The
   Linear MCP returns richer project objects — *if* its tool exposes project state,
   you may filter to Active + Planned state TYPES (`started`, `planned`; state
   NAMES vary per workspace, so filter on type). Either way, step 2 is what
   actually surfaces active work.
2. **For each project, list its issues.** A fresh-spawned project may have all
   issues in Backlog and no assignee; the per-project sweep catches them.
   `lineark issues list` already **hides Done/Canceled by default** (`--show-done`
   to include), so its output IS the open-work cut. A Linear-MCP `list_issues` may
   *not* hide them — filter out Done/Canceled client-side if so.
3. **As a tertiary check, list personally-assigned issues** that are In Progress
   (continuation of work in flight) — e.g. `lineark issues list --mine`, filtering
   on state: `.state == "In Progress"` for lineark (where `.state` is a bare
   string) or `.state.name == "In Progress"` for the MCP's nested object (§4.3).
4. **Global open-issues sweep — the projectless-issue net.** List ALL open
   issues team-wide with no project, assignee, or state filter — e.g. a bare
   `lineark issues list` (Done/Canceled hidden by default, so the output IS the
   team-wide open cut) or the Linear MCP's `list_issues` with no project filter
   (drop Done/Canceled client-side). A standalone issue that belongs to no
   project is invisible to sweep 2, and unless it happens to be assigned + In
   Progress it is invisible to cut 3 as well — a Backlog, Blocked, or unassigned
   standalone issue surfaces ONLY here. Cheap (one list call); never skip it.
   If the surface paginates or truncates (a bounded first page), page through
   to exhaustion — a projectless issue on page two is exactly the one this
   sweep exists to catch.

**Always run the project sweep first.** The assignee+In-Progress cut alone misses
fresh-spawned projects entirely — a just-created project's issues sit in Backlog
with no assignee, so only the per-project sweep surfaces them (a lesson learned
live when a kickoff orient reported "no active work" over a freshly-spawned
project).

**`.state` shape varies by call (lineark).** `projects list` has no `state` field;
`issues list` returns `.state` as a bare **string**; only `issues read` returns a
`{id, name}` **object**. Query `.state` directly on a list, `.state.name` only on a
read — a `.state.name` filter over a list throws `Cannot index string with string
"name"`. See `$AI_CONFIG_DIR/linear/linear-setup.md` §4.3.

**Per-surface commands:** see `$AI_CONFIG_DIR/linear/linear-setup.md` §4 for the actual command
shapes (lineark CLI flags or Linear MCP tool names + arguments). The same query
order applies to both surfaces.

**Surface-absent fallback:** if neither `lineark` nor a Linear MCP connector is
installed, the framework gracefully degrades — orient continues with memory + vault
only; a one-line warning surfaces the missing surface. Document the install in the
next session per `$AI_CONFIG_DIR/linear/linear-setup.md`.

**MCP edge case:** if the Linear MCP reports ✓ Connected but `list_projects`
returns an empty array, treat it as the silent-empty-MCP-tools failure pattern
(a stale connection returns empty results instead of erroring) — restart the
harness's MCP connection (or fall back to `lineark` if installed) before
accepting "no active work" as the answer.

### O4. Vault orient — entrypoint, operator-identity master, AND lesson index

Ground the session in the vault. Read **three** notes explicitly — load only the
relevant slice, never the whole vault:

1. **`START.md`** — the vault's working rules.
2. **The operator-identity master note** — the `harness: all`-scoped identity note
   ("Operator Soul" or equivalent) holding who the operator is and how they want to
   be worked with. The vault entrypoint names it; the path is vault-specific (e.g.
   under an `Areas/` folder). Read that named note as its **own mandatory
   sub-step** rather than treating START.md's prose pointer ("load the Operator
   Soul first") as optional — a prose pointer is an instruction *chain* agents
   skip, so naming the read here is the fix: the identity master must land every
   session, not only when the chain is followed.
3. **The lesson index — `04-Lessons/_index.md`.** The durable-lessons table whose
   **Trigger column** ("Before installing any external skill", "Before fanning out
   parallel subagents", …) is the retrieval hook the R1a recall step matches
   against. This read exists because lessons were previously write-only in
   practice: sessions distilled lessons INTO the vault at closeout, but no orient
   or routing step ever read one back OUT, so operators re-taught rules that were
   already recorded. The **canonical** index is read (not the generated per-harness
   view) because only it carries the Trigger column; the harness-scope filter is
   applied at body-read time instead — before reading a matched lesson's body,
   check its frontmatter `harness:` key and skip notes scoped to another harness.

**Tool calls:**
- `Read` `$OBSIDIAN_VAULT_PATH/START.md`.
- `Read` the operator-identity note START.md designates (vault-specific path).
- `Read` `$OBSIDIAN_VAULT_PATH/04-Lessons/_index.md` (or the vault's equivalent
  lessons index if the vault names a different layout). Keep the index in context
  for the session — Mode 2 routing re-scans it without re-reading the file.
- **Degrade gracefully — never fail the orient.** If the vault is unreachable
  (Drive/VPN down) *or* reachable but no identity note is configured/named, read
  what you can (or skip) and continue with a one-line note. If the harness keeps a
  per-machine identity cache (a lean projection of the master), use it as the
  offline fallback; otherwise continue without identity context. An unreachable
  lesson index degrades the same way: note it in the orient summary, declare
  `Lessons: index unreachable` at R5, and fall back to the autoloaded memory-index
  feedback headlines as the only recall surface.

### O5. Cross-issue Linear state verification

For any cross-issue Linear claims surfaced in O1's memory bodies (claims about
*other* issues' states — "`<PREFIX>`-X is Done", "`<PREFIX>`-Y is gating", etc.,
in your workspace's issue prefix — `TEAM` is only the docs placeholder), verify
against Linear at kickoff regardless. Cross-issue claims aren't self-correcting
at the body-read step.

**Tool calls:**
- For each cross-issue claim with a concrete `<PREFIX>-<number>` identifier: query the
  Linear surface for the issue and compare the `state` field against the memory
  body's claim (see `$AI_CONFIG_DIR/linear/linear-setup.md` §4 for the per-surface read command).
  Flag mismatches in the orient summary.

### Mode 1 output

End the orient pass with a structured summary the user sees:

```
Orient:
- Active Linear project(s): <list with issue IDs + state>
- Open issues in active project(s): <count + headline list>
- Memory contradictions vs session-start commits: <one line per contradiction, or "none">
- Vault: <one line of context from START.md>
- Lesson index: <N lessons / triggers loaded | unreachable — recall degraded to memory-index headlines>
- Cross-issue Linear claim verification: <pass / mismatches found>
- Safety posture: <default "safe"; name any active tightening from a session-guardrail skill or unattended-governance flag>
```

Then proceed immediately to the routing steps (R1–R5 below) for the user's request.
The orient summary + routing declaration both land in the same first response.

The **Safety posture** line makes the run's posture visible at start; it defaults
to `safe` and reports any active tightening, never a loosening — the contract is
`core/operating-system.md` → Per-Run Safety Posture.

---

## Mode 2 — Route only

Skip O1–O5. Run only R1–R5 below. The Mode 1 orient outputs are still live in the
session context.

---

## Routing steps (R1–R5) — used by both modes

### R1. Classify the task surface — one sentence

Bug fix, new feature, refactor, UI, security-sensitive change, data analysis,
infra, docs, audit, ops, review-only, planning, implementation, publish/live.

### R1a. Recall applicable lessons — match triggers, read the few that fire

Durable lessons only compound if they re-enter context at task time; this step
is the read side of the self-improvement loop (closeout is the write side).
Match the just-classified surface + the concrete task against **two recall
surfaces**:

1. **The lesson index Trigger column** read at O4. Mode 2: it is normally
   already in context from Mode 1 — re-scan it without re-reading the file.
   But if the index is NO LONGER in context (a compaction summarized it away),
   re-read the file before declaring — never declare `none match` from a
   remembered index (panel finding: a post-compaction scan over nothing
   silently becomes a false `none match`).
2. **The autoloaded memory-index headlines** — the feedback/decision one-liners
   the harness injected at session start. These are rules too; a match here
   counts the same as an index-trigger match.

For each match, `Read` the lesson/feedback note **body** before executing —
the headline names the rule, the body carries the how and the edge cases.
Bounds, so this stays a slice and not a vault load:

- **Respect harness scope:** if the index carries an explicit scope/harness
  column, filter on it before reading; otherwise check a matched note's
  frontmatter `harness:` key first and skip notes scoped to another harness.
- **Cap the APPLICABLE body-reads at ~3**, most-specific-first. Scope-skipped
  notes do not consume the cap (panel finding: foreign-scope matches must not
  starve the recall of applicable lessons), but bound the total probes at ~6 —
  needing more than that means the triggers are too broad; read the most
  specific 3 and name the rest in the declaration without reading them.
- **Zero matches is a normal outcome** — declare `Lessons: none match` and
  proceed. Do not force-fit a lesson to satisfy the declaration.
- **Vault unreachable** (index never loaded at O4): match against the
  autoloaded headlines only and declare `Lessons: index unreachable`.
- **Recall out of scope by policy:** a contained task may legitimately forbid
  vault or extra-file reads (a sandboxed run, an isolation worktree with no
  vault mount). Declare `Lessons: skipped — <reason>` honestly rather than
  faking `none match` (which claims a scan) or `index unreachable` (which
  claims a failure).

The result feeds the `Lessons:` line of the R5 declaration. If, later in the
session, the operator corrects you with a rule that WAS in a recall surface
this step should have matched, that is a **recall failure** — record it at
closeout per `core/self-improvement.md` (which surface failed: not-loaded vs
loaded-but-ignored), so the miss tunes the triggers instead of re-writing the
rule as a duplicate.

### R2. Pick the primary capability

Consult the **harness's installed capability catalog**:
- Claude Code: `$CLAUDE_CONFIG_DIR/SKILLS.md` (the build-generated catalog) + the
  quick-reference table in `$CLAUDE_CONFIG_DIR/CLAUDE.md`.
- Codex: `$CODEX_HOME/AGENTS.md` capability catalog + the catalog file.

If several capabilities could apply, the task spans surfaces, the quick-reference
does not resolve a clean primary, or risk is high (auth/billing/secrets/migrations/
public surfaces), run the **orchestration sub-routine** (CO1–CO5 below).

If genuinely no capability fits, declare `ad-hoc — no specific capability`.

### R3. Name the verification gate

Choose the matching gate from `$AI_CONFIG_DIR/verification/` — e.g. `code-change`,
`audit-systems`, `data-readiness`, `ui-browser`, `docs-framework`, `high-risk`,
`process-memory`, `tool-freshness`, `deploy-live`.

### R4. Apply the Linear gate

If the task is multi-step or spans more than one session, a Linear issue or
project must exist **before execution**. Create it to the canonical standard in
`$AI_CONFIG_DIR/linear/issue-template.md` — BOTH halves, at create time: the
required-metadata checklist (team; project, or an explicit
deliberately-projectless reason in the body; a deliberate priority — never the
default "No priority"; at least one label; an assignee, or the standard's
stated deliberately-unassigned reason; parent/relations when
the issue is spawned by other tracked work) AND the structured body (outcome,
scope, acceptance criteria, verification, links). A title + prose-blob issue
is nonconforming even when the prose is good. Create it via the operator's
installed Linear surface (see `$AI_CONFIG_DIR/linear/linear-setup.md` §4 for
the per-surface create command).

Single-file fixes, trivial edits, and questions stay as session todos. If no
write-capable Linear access exists, produce a Linear-ready markdown draft.

### R5. State the chosen chain in one line, then execute

```
Routing: <one-sentence task surface>
Primary skill: <capability name, or "ad-hoc — no specific capability">
Lessons: <matched lesson/note names, body-read ones first> | none match | index unreachable | skipped — <reason>
Verification: <gate name from $AI_CONFIG_DIR/verification/>
Linear gate: <ISSUE-ID or URL> | none — single-step | none — drafted
```

When the orchestration sub-routine fired (multi-surface or risky), extend with:

```
Surface: <one sentence>
Risk: <low | medium | high — and why if not low>
Primary: <capability name>
Secondary: <capability name(s) — or "none">
Verification: <verification recipe path>
Next action: <one sentence>
```

After emitting, proceed with the work.

---

## Orchestration sub-routine (R2 fallback)

Fires when several capabilities could apply, the task spans surfaces, the
quick-reference does not resolve a clean primary, the user explicitly asks
"which capability should I use", or risk is high.

- **CO1. Classify** the task surface in one sentence: review-only, planning,
  implementation, publish/live, operations, or memory.
- **CO2. Identify constraints:** risk level (auth/billing/secrets/migrations/
  customer-data/public surfaces); output format (code/doc/artifact/dashboard/
  message); evidence needed (tests/browser-render/screenshot/sign-off).
- **CO3. Consult** the installed capability catalog and find the row matching
  the primary surface.
- **CO4. Compose** the chain: one primary; secondaries only for evidence, risk,
  or output format; a verification recipe from `$AI_CONFIG_DIR/verification/`.
- **CO5. Confirm** with the user only if routing is non-obvious or risk is high.
  Otherwise state the chain and proceed.

Orchestration rules:
- Pick the smallest useful chain. Don't load whole families.
- When surfaces tie, pick the one that **gates** the others — design before
  implementation; debug before refactor; verification last.
- For cross-functional work, route the **starting** surface and surface the next
  chains as follow-ups rather than mashing them into one route.
- High-risk surfaces always get an explicit verification recipe named in the output.
- If no capability fits cleanly, recommend adding one via a skill-creation
  capability — don't force-fit.

---

## Notes

- **Mode 1 fires once per session.** Re-invoking session-agent mid-session for a
  pivot uses Mode 2 (the orient is already in context). Forcing a re-orient is
  rare and explicit; the operator can request it by saying "re-orient" — which
  is a Mode 1 re-run.
- **The protocol's value is in the model thinking through the steps** — not in
  any single line of the declaration. The pre-edit-gate enforcement class checks
  only that session-agent ran and that the `Linear gate:` and `Lessons:` lines
  were declared; it does not police the judgment.
- **Be honest on the Linear gate.** Splitting genuine multi-session work into
  "single-step" to skip the gate defeats the protocol.
- **Be honest on the Lessons line.** `none match` after an actual trigger scan
  is a valid answer; `none match` as a reflex to satisfy the gate defeats the
  recall step — the whole line exists because rules that were already recorded
  kept getting skipped.
- **The gate enforces the first complete declaration per session.** Once both
  lines have been declared, later Mode 2 routes re-declare by protocol but the
  hook does not re-police them per task — it is a discipline net with a kill
  switch, not a security boundary. The recall habit on subsequent prompts is
  carried by the protocol, same as every other R-step.
- **Token cost.** Mode 1 is expensive (multiple Linear queries + memory body
  reads + vault reads, including the lesson index). Mode 2 is cheap (no tool
  calls beyond consulting the catalog and re-scanning the in-context lesson
  index; R1a body-reads only fire on a trigger match). Don't re-orient on
  every prompt.
