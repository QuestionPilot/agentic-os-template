---
name: session-agent
summary: Auto-fires at session start to orient the AI (memory + Linear + vault + reconcile session-start hints), then routes the user's prompt to the smallest useful capability chain. Subsequent prompts re-invoke to route without re-orienting. Single capability for kickoff + routing + orchestration; subsumes route + skill-orchestrator.
triggers: [start of any session, first action on any session, before the first file-modifying action, start of any non-trivial task, a task pivots significantly mid-session, several capabilities could apply, a task spans multiple surfaces, the user asks which capability to use, the enforcement gate asks for session-agent, when the framework session-start hook directs you here]
verification: none
harnesses: [claude, codex, hermes, cursor]
kind: native
enforcement: pre-edit-gate
lifecycle: shipped
---

# Session Agent — Session Kickoff Orient + Routing

The spine of every non-trivial task. **It auto-fires at session start** (the
framework session-start hook directs its invocation first), then
re-invokes on every non-trivial prompt to route to the smallest useful chain.

Conditional depth — why each rule exists, per-surface alternatives, the full
orchestration walk, case studies — lives in
`$AI_CONFIG_DIR/capabilities/reference/session-agent.md`. Read on demand; every
must-fire rule is inline below.

| Mode | When | Job |
| --- | --- | --- |
| **Mode 1 — Kickoff orient** | First invocation per session | Orient (O1–O5), then route the first request (R1–R5). |
| **Mode 2 — Route only** | Every subsequent invocation | Route only (R1–R5). Mode 1's findings are still live in context. |

**Selection rule:** if you have not invoked `session-agent` earlier in this
session, run Mode 1. Otherwise run Mode 2. Each harness realization
(`harnesses/<h>/capabilities/session-agent.md`) documents how its hook detects
prior invocation.

---

## Mode 1 — Kickoff orient

Run all five sub-steps. Skipping one is a Mode 1 failure — re-run it before
routing.

**Step 0 — run the orient helper once.** It does the deterministic collection
(tracker + memory) O1 and O3 consume:

```bash
$AI_CONFIG_DIR/scripts/orient.sh --memory-dir <this harness's memory store>
# PowerShell: pwsh -File $AI_CONFIG_DIR/scripts/orient.ps1 -MemoryDir <path>
```

It emits ONE `orient/v1` JSON document — a **projects-first** cut with per-project
open issues, `projectless_open_issues` (the reconciliation net), `mine_in_progress`,
`anomalies`, `memory_pointers`, `surfaces`, and `degraded`. It **degrades, never
fails**: an absent or erroring surface still yields a valid document on exit 0,
naming that surface in `degraded`. Read the script header for the contract. Non-zero
exit = the script could not run; collect by hand per
`$AI_CONFIG_DIR/capabilities/reference/session-agent.md`.

### O1. Read project memory bodies for active-work projects

The harness autoloads `MEMORY.md` — a one-line index of headlines. **Headlines are
not the source of truth.** For each `memory_pointers` entry in the orient
document (project-type notes, `metadata.type: project`) whose description names
active or recently-active work, `Read` the body before acting on the headline. Do
NOT re-read `reference_*` / `feedback_*` bodies at kickoff — those are
headline-stable. Cross-issue tracker claims inside those bodies are stale-prone; O5
re-checks them.

### O2. Reconcile session-start hints against memory headlines

The session-start hook surfaces the last 7–10 days of framework commits in
`additionalContext`. Scan them for tracker issue identifiers — the
`<PREFIX>-<number>` shape, where **`<PREFIX>` is your workspace's issue prefix**
(`TRACKER_ISSUE_PREFIX` in `local.env`). `TEAM` is only the documentation
placeholder; a literal `TEAM-\d+` match finds nothing in a real workspace and
silently disables the step. For any identifier whose parent
project's memory headline says `COMPLETE` / `CLOSED` / `DONE`, that is a
contradiction — flag it in the first turn and dig before trusting the headline:
memory captures what was true when written, the window what is true now. Model
judgment over first-turn context — no tool calls.

### O3. Read the tracker cut from the orient document

From the emitted JSON: `projects[]` (with each project's open issues),
`projectless_open_issues`, and `mine_in_progress` are the active-work picture. Also:

- **`anomalies[]` — flag every one in the orient summary.** They are the cuts
  disagreeing (`open-issue-count-mismatch`) or a project nobody is on
  (`all-issues-backlog-no-assignee`), not noise.
- **`degraded[]` / `surfaces` — apply the one-line-warning rule.** A degraded
  surface gets exactly one named warning line and the orient continues; it is never
  silently reported as "no active work".

**When `surfaces.linear` is absent or errored, tracker collection is still
MANDATORY:** perform the same projects-first cut BY HAND via the installed surface
(MCP, or direct `linear` CLI calls) per `$AI_CONFIG_DIR/linear/linear-setup.md` §4,
which carries the command shapes. A degraded surface downgrades the METHOD,
never the requirement — "the helper reported the surface down" is not a licence to
skip O3.

### O4. Vault orient — entrypoint, operator-identity master, AND lesson index

Read **three** notes explicitly — load only the relevant slice, never the whole
vault:

- `Read` `$OBSIDIAN_VAULT_PATH/START.md` — the vault's working rules.
- `Read` the **operator-identity master note** the vault entrypoint designates (the
  `harness: all`-scoped identity note; path is vault-specific) — its own mandatory
  sub-step, not an optional follow of START.md's pointer.
- `Read` `$OBSIDIAN_VAULT_PATH/04-Lessons/_index.md` — the canonical lesson index,
  whose **Trigger column** is what R1a matches against. Keep it in context; Mode 2
  re-scans without re-reading. Apply harness scope at body-read
  time from each note's frontmatter `harness:` key.

**Degrade gracefully — never fail the orient.** If the vault is unreachable or no
identity note is configured, read what you can and continue with a one-line note
(the harness's per-machine identity cache is the offline fallback if it keeps one).
An unreachable lesson index degrades the same way: note it, declare
`Lessons: index unreachable` at R5, and fall back to the autoloaded memory-index
feedback headlines as the only recall surface.

### O5. Cross-issue tracker state verification

For any cross-issue claims in O1's memory bodies (claims about *other* issues'
states — "`<PREFIX>`-X is Done", "`<PREFIX>`-Y is gating"), verify against the
tracker at kickoff regardless; such claims are not self-correcting at the body-read
step. Query each concrete `<PREFIX>-<number>` and compare its `state` with the claim
(read command per `$AI_CONFIG_DIR/linear/linear-setup.md` §4). Flag mismatches in the
orient summary.

### Mode 1 output

End the orient pass with a structured summary the user sees:

```
Orient:
- Active Linear project(s): <list with issue IDs + state>
- Open issues in active project(s): <count + headlines>
- Projectless open issues: <count + list, or "none">
- Anomalies: <one line each, or "none">
- Memory contradictions vs session-start commits: <one line each, or "none">
- Vault: <one line from START.md>
- Lesson index: <N triggers loaded | unreachable — recall degraded to memory headlines>
- Cross-issue claim verification: <pass / mismatches found>
- Degraded surfaces: <one named line each, or "none">
- Safety posture: <orient `.safety`: "safe (none configured)" | "safe (configured, N unresolved)" | "tightened — <names>">
```

Then proceed to R1–R5 — the orient summary and the routing declaration land in the
same first response.

The **Safety posture** line reports what orient DETECTED (`.safety`), never declared
policy: posture, each tightening's name, and, when guardrails are configured but not
in force, the `unresolved` count, so broken wiring never reads as "none configured". It
defaults to `safe` and only adds tightenings (contract:
`core/operating-system.md` → Per-Run Safety Posture). Enforcement strength is
harness-dependent, so never let the line claim hard enforcement it cannot see.

---

## Routing steps (R1–R5) — both modes; Mode 2 skips O1–O5 and runs only these

### R1. Classify the task surface — one sentence

Bug fix, new feature, refactor, UI, security-sensitive change, data analysis, infra,
docs, audit, ops, review-only, planning, implementation, publish/live.

### R1a. Recall applicable lessons — match triggers, read the few that fire

Match the just-classified surface + the concrete task against **two recall
surfaces**:

1. **The lesson index Trigger column** read at O4. In Mode 2 it is normally in
   context — re-scan without re-reading. If it is NO LONGER in context (a
   compaction summarized it away), re-read the file first; never declare `none match`
   from a remembered index.
2. **The autoloaded memory-index headlines.** A match here counts the same as an
   index-trigger match.

For each match, `Read` the note **body** before executing. Bounds:

- **Respect harness scope** — filter on the index's scope column if present, else
  on a matched note's frontmatter `harness:` key; skip foreign scopes.
- **Cap APPLICABLE body-reads at ~3**, most-specific-first. Scope-skipped notes do
  not consume the cap; bound total probes at ~6 and name the rest in the declaration
  without reading them.
- **Zero matches is a normal outcome** — declare `Lessons: none match`. Do not
  force-fit a lesson to satisfy the declaration.
- **Vault unreachable** (index never loaded at O4): match the autoloaded headlines
  only and declare `Lessons: index unreachable`.
- **Recall out of scope by policy** (a sandboxed run, a worktree with no vault
  mount): declare `Lessons: skipped — <reason>` rather than faking `none match`
  (which claims a scan) or `index unreachable` (which claims a failure).

The result feeds the `Lessons:` line at R5. If the operator later corrects you with
a rule a recall surface should have matched, that is a **recall failure** — record it
at closeout per `core/self-improvement.md`, naming the failed surface, so the miss
tunes the triggers instead of duplicating the rule.

### R2. Pick the primary capability

Consult the **harness's installed capability catalog**: Claude Code —
`$CLAUDE_CONFIG_DIR/SKILLS.md` plus the quick-reference table in
`$CLAUDE_CONFIG_DIR/CLAUDE.md`; Codex — `$CODEX_HOME/AGENTS.md`.

If several capabilities could apply, the task spans surfaces, the quick-reference
gives no clean primary, the user asks which capability to use, or risk is high (the
R2b list), run the **orchestration sub-routine**: classify the surface, name
risk/output/evidence constraints, consult the catalog, compose the chain, and confirm
with the user only when routing is non-obvious or risk is high. **Pick the smallest
useful chain — one primary, secondaries only for evidence, risk, or output format;
don't load whole families.**
Full CO1–CO5 detail and composition rules:
`$AI_CONFIG_DIR/capabilities/reference/session-agent.md`.

If genuinely no capability fits, declare `ad-hoc — no specific capability`.

### R2b. Decide how the work executes — one line

Questions and review-only tasks are `inline` — decided before the walk starts. For a
change, walk top-down; the first rule that fires wins, and it lands on the
`Execution:` line at R5.

1. `delegated wave + panel` — the change is framework or high-risk (auth /
   permissions / billing / migrations / secrets / public surfaces), whatever its
   size: the wave below (one lane is enough for a small change) plus a cross-model
   critic panel on the diff before merge.
2. `delegated wave` — a multi-file build or ≥2 independent lanes: the orchestrator
   writes each lane's four-line brief (`core/operating-system.md` → "Delegating to
   subagents", discipline-kernel preamble included), executors build, and the
   orchestrator inspects every diff and reruns the proof itself — never a rubber
   stamp.
3. `inline` — the residue: a change neither rule above claimed (single-file
   fixes).

Roles only — which models fill orchestrator, executor, and critic is the operator
layer's call. The pre-edit gate does not check this line; it exists so the routing
walk asks HOW, not only WHICH.

### R3. Name the verification gate

Choose the matching gate from `$AI_CONFIG_DIR/verification/` — e.g. `code-change`,
`audit-systems`, `data-readiness`, `ui-browser`, `docs-framework`, `high-risk`,
`process-memory`, `tool-freshness`, `deploy-live`.

### R4. Apply the Linear gate

If the task is multi-step or spans sessions, a Linear issue or project must exist
**before execution**. Create it to the canonical standard in
`$AI_CONFIG_DIR/linear/issue-template.md` — BOTH halves, at create time: the
required-metadata checklist (team; project, or an explicit deliberately-projectless
reason in the body; a deliberate priority — never the default "No priority"; ≥1
label; an assignee, or the standard's deliberately-unassigned reason;
parent/relations when spawned by other tracked work) AND the structured body
(outcome, scope, acceptance criteria, verification, links). A title + prose-blob
issue is nonconforming even when the prose is good. Create it via the installed
Linear surface (`$AI_CONFIG_DIR/linear/linear-setup.md` §4).

Single-file fixes, trivial edits, and questions stay as session todos. If no
write-capable Linear access exists, produce a Linear-ready markdown draft.

### R5. State the chosen chain in one line, then execute

```
Routing: <one-sentence task surface>
Primary skill: <capability name, or "ad-hoc — no specific capability">
Lessons: <matched lesson/note names, body-read ones first> | none match | index unreachable | skipped — <reason>
Verification: <gate name from $AI_CONFIG_DIR/verification/>
Linear gate: <ISSUE-ID or URL> | none — single-step | none — drafted
Execution: inline | delegated wave | delegated wave + panel
```

When the orchestration sub-routine fired, extend with:

```
Surface: <one sentence>
Risk: <low | medium | high — and why if not low>
Primary: <capability name>
Secondary: <capability name(s) — or "none">
Verification: <verification recipe path>
Next action: <one sentence>
```

After emitting, proceed with the work.

Declare honestly: `none match`, `none — single-step`, and `inline` are valid only
after the scan or the walk actually ran — written by reflex they defeat the gate.
Full notes: the reference doc.
