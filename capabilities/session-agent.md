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
not the source of truth.** For any `project_*.md` referenced there whose headline
names active or recently-active work, read the file body before acting on the
headline. Cross-issue Linear claims embedded in those bodies (e.g. "QUE-X is Done")
are particularly stale-prone — Mode 1's O5 step re-checks them against Linear.

**Tool calls:**
- For each `project_*.md` in `MEMORY.md` whose headline names active work: `Read` the absolute path under the harness config dir's `projects/<project-slug>/memory/` directory.
- Do NOT re-read `reference_*.md` / `feedback_*.md` bodies at kickoff — those are headline-stable.

### O2. Reconcile session-start hints against memory headlines

The framework session-start hook surfaces the last 7–10 days of `agentic-os-template` commits
in `additionalContext`. For any `QUE-\d+` identifiers in those commits whose parent
project's memory headline says `COMPLETE` / `CLOSED` / `DONE`, that's a contradiction
— flag it in the first turn and dig before trusting the memory headline. Memory
captures what was true when written; the session-start window captures what is true now.

**Tool calls:** none specific — this step reads the session-start-injected context
that is already in the model's first turn and compares against the memory bodies
read in O1.

### O3. Kickoff Linear query — projects-first ordered cut

Use whichever Linear surface the operator installed per `$AI_CONFIG_DIR/linear/linear-setup.md` —
`lineark` CLI or Linear MCP. Both are first-class; the framework prefers `lineark`
for token cost but does not require it.

**Query order (surface-agnostic):**

1. **List Linear projects** filtered to Active + Planned state TYPES. State NAMES
   vary per workspace; state TYPES (`started`, `planned`) are workspace-portable —
   filter on type.
2. **For each surfaced project, list its issues.** A fresh-spawned project may
   have all issues in Backlog and no assignee; the per-project sweep catches them.
3. **As a tertiary check, list personally-assigned issues** filtered to In Progress
   (continuation of work in flight).

**Always run the project sweep first.** The assignee+In-Progress cut alone misses
fresh-spawned projects entirely — see [[feedback_session_kickoff_cut]].

**Per-surface commands:** see `$AI_CONFIG_DIR/linear/linear-setup.md` §4 for the actual command
shapes (lineark CLI flags or Linear MCP tool names + arguments). The same query
order applies to both surfaces.

**Surface-absent fallback:** if neither `lineark` nor a Linear MCP connector is
installed, the framework gracefully degrades — orient continues with memory + vault
only; a one-line warning surfaces the missing surface. Document the install in the
next session per `$AI_CONFIG_DIR/linear/linear-setup.md`.

**MCP edge case:** if the Linear MCP reports ✓ Connected but `list_projects`
returns an empty array, this is the [[reference_mcp_silent_empty_tools]] pattern —
restart the harness's MCP connection (or fall back to `lineark` if installed)
before accepting "no active work" as the answer.

### O4. Vault orient

Open the durable-knowledge vault's `START.md` to ground the session in the vault's
working rules. Load only the relevant slice — do not load the whole vault.

**Tool calls:**
- `Read` the absolute path `$OBSIDIAN_VAULT_PATH/START.md`. (The vault path is
  declared in `local.env`; on harnesses without it, skip with a one-line note.)

### O5. Cross-issue Linear state verification

For any cross-issue Linear claims surfaced in O1's memory bodies (claims about
*other* issues' states — "QUE-X is Done", "QUE-Y is gating", etc.), verify
against Linear at kickoff regardless. Cross-issue claims aren't self-correcting
at the body-read step.

**Tool calls:**
- For each cross-issue claim with a concrete `QUE-\d+` identifier: query the
  Linear surface for the issue and compare the `state` field against the memory
  body's claim (see `$AI_CONFIG_DIR/linear/linear-setup.md` §4 for the per-surface read command).
  Flag mismatches in the orient summary.

### Mode 1 output

End the orient pass with a structured summary the user sees:

```
Orient:
- Active Linear project(s): <list with QUE-IDs + state>
- Open issues in active project(s): <count + headline list>
- Memory contradictions vs session-start commits: <one line per contradiction, or "none">
- Vault: <one line of context from START.md>
- Cross-issue Linear claim verification: <pass / mismatches found>
```

Then proceed immediately to the routing steps (R1–R5 below) for the user's request.
The orient summary + routing declaration both land in the same first response.

---

## Mode 2 — Route only

Skip O1–O5. Run only R1–R5 below. The Mode 1 orient outputs are still live in the
session context.

---

## Routing steps (R1–R5) — used by both modes

### R1. Classify the task surface — one sentence

Bug fix, new feature, refactor, UI, security-sensitive change, data analysis,
infra, docs, audit, ops, review-only, planning, implementation, publish/live.

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
project must exist **before execution**. Draft into the issue shape from
`$AI_CONFIG_DIR/linear/tool-agnostic-linear.md` (outcome, scope, AC, verification,
links) and create it via the operator's installed Linear surface (see
`$AI_CONFIG_DIR/linear/linear-setup.md` §4 for the per-surface create command).

Single-file fixes, trivial edits, and questions stay as session todos. If no
write-capable Linear access exists, produce a Linear-ready markdown draft.

### R5. State the chosen chain in one line, then execute

```
Routing: <one-sentence task surface>
Primary skill: <capability name, or "ad-hoc — no specific capability">
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
  only that session-agent ran and that the `Linear gate:` line was declared; it
  does not police the judgment.
- **Be honest on the Linear gate.** Splitting genuine multi-session work into
  "single-step" to skip the gate defeats the protocol.
- **Token cost.** Mode 1 is expensive (multiple Linear queries + memory body
  reads + vault read). Mode 2 is cheap (no tool calls beyond consulting the
  catalog). Don't re-orient on every prompt.
