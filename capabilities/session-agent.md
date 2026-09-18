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

The spine of every non-trivial task. It auto-fires at session start (the framework session-start hook directs it first) and re-invokes for each later non-trivial prompt. Read `$AI_CONFIG_DIR/capabilities/reference/session-agent.md` on demand for rationale, alternatives, and full orchestration detail; all must-fire rules are here.

| Mode | When | Job |
| --- | --- | --- |
| **Mode 1 — Kickoff orient** | First invocation in a session | O1–O5, then R1–R5 for the first request. |
| **Mode 2 — Route only** | Every later invocation | R1–R5 only; Mode 1 findings remain in context. |

If `session-agent` has not run in this session, run Mode 1. Otherwise run Mode 2. Run every Mode 1 step; if one was skipped, re-run it before routing.

## Mode 1 — Kickoff orient

**Step 0 — run once.** Run:

```bash
$AI_CONFIG_DIR/scripts/orient.sh --memory-dir <this harness's memory store>
# PowerShell: pwsh -File $AI_CONFIG_DIR/scripts/orient.ps1 -MemoryDir <path>
```

Consume its one `orient/v1` JSON document: a projects-first cut with per-project open issues, `projectless_open_issues`, `mine_in_progress`, `anomalies`, `memory_pointers`, `surfaces`, and `degraded`. It degrades, never fails: an absent/erroring surface is named in `degraded` and still yields valid exit-0 JSON. Read the script header for its contract. On nonzero exit, collect by hand per `$AI_CONFIG_DIR/capabilities/reference/session-agent.md`.

### O1. Active-project memory

`MEMORY.md` headlines are not source of truth. For each `memory_pointers` entry in the orient document (project-type notes, `metadata.type: project`) whose description names active or recently-active work, read its body before acting. Do not re-read `reference_*` or `feedback_*` bodies at kickoff; their headlines are stable. Cross-issue tracker claims inside those bodies are stale-prone; O5 re-checks them.

### O2. Session-start hints

Scan the 7–10-day framework-commit hints in `additionalContext` for `<PREFIX>-<number>`, using the workspace prefix in `TRACKER_ISSUE_PREFIX` (`local.env`; not literal `TEAM`: a literal `TEAM-\d+` match finds nothing and silently disables the step). For any scanned identifier whose parent project's memory headline says `COMPLETE`, `CLOSED`, or `DONE`, flag the contradiction in the first turn and investigate before trusting the headline: memory captures what was true when written, the window what is true now. Use judgment over first-turn context; make no tool calls.

### O3. Tracker cut

Read `projects[]` and its open issues, `projectless_open_issues`, and `mine_in_progress`. Flag every `anomalies[]` entry: the cuts disagreeing (`open-issue-count-mismatch`) or a project nobody is on (`all-issues-backlog-no-assignee`) are not noise. For each degraded surface, give exactly one named warning and continue; never call it "no active work." If `surfaces.linear` is absent or errored, still collect the same projects-first cut by hand through installed MCP or `linear` CLI, per `$AI_CONFIG_DIR/linear/linear-setup.md` §4; degradation changes the method, not the requirement.

### O4. Vault orient

Read **three** notes explicitly, loading only the needed slice:

- `$OBSIDIAN_VAULT_PATH/START.md` — the vault's working rules.
- The **operator-identity master note** the vault entrypoint designates (the `harness: all`-scoped identity note; path is vault-specific) — a mandatory sub-step in its own right.
- `$OBSIDIAN_VAULT_PATH/04-Lessons/_triggers.md` — the generated triggers-only view (link + **Trigger** per row) R1a matches; `_index.md` is the fallback when it is absent. Keep it in context; Mode 2 re-scans without re-reading. Apply harness scope at body-read time from each note's `harness:` key.

**Degrade gracefully — never fail the orient.** If the vault is unreachable or no identity note is configured, read what you can and continue with a one-line note (the harness's per-machine identity cache is the offline fallback if it keeps one). An unreachable lesson index degrades the same way: note it, declare `Lessons: index unreachable` at R5, and fall back to the autoloaded memory-index feedback headlines as the only recall surface.

### O5. Cross-issue claims

For any cross-issue claims in O1's memory bodies (claims about *other* issues' states — "`<PREFIX>`-X is Done", "`<PREFIX>`-Y is gating"), verify against the tracker at kickoff; the body-read step does not self-correct them. Query each concrete `<PREFIX>-<number>` and compare its `state` with the claim per `$AI_CONFIG_DIR/linear/linear-setup.md` §4. Flag mismatches in the orient summary.

### Mode 1 output

In the first response, emit this orient summary and the R5 declaration together:

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

Safety posture reports detected `.safety`, never declared policy: posture, every tightening name, and unresolved count when configured guardrails are not in force, so broken wiring never reads as "none configured". It defaults to `safe` and only adds tightenings (contract: `core/operating-system.md` → Per-Run Safety Posture). Enforcement strength is harness-dependent — never let the line claim enforcement it cannot see.

## Routing — R1–R5 in both modes

Mode 2 skips O1–O5. Both modes complete every routing step.

### R1. Classify

State the task surface in one sentence: bug fix, feature, refactor, UI, security-sensitive change, data analysis, infra, docs, audit, ops, review-only, planning, implementation, or publish/live.

### R1a. Recall applicable lessons — match triggers, read the few that fire

Match the just-classified surface + the concrete task against **two recall surfaces**:

1. **The lesson index Trigger column** read at O4. In Mode 2 it is normally in context — re-scan without re-reading. If it is NO LONGER in context (a compaction summarized it away), re-read the file first; never declare `none match` from a remembered index.
2. **The autoloaded memory-index headlines.** A match here counts the same as an index-trigger match.

For each match, `Read` the note **body** before executing. Bounds:

- **Respect harness scope** — filter on the index's scope column if present, else on a matched note's frontmatter `harness:` key; skip foreign scopes.
- **Cap APPLICABLE body-reads at ~3**, most-specific-first. Scope-skipped notes do not consume the cap; bound total probes at ~6 and name the rest in the declaration without reading them.
- **Zero matches is a normal outcome** — declare `Lessons: none match`. Do not force-fit a lesson to satisfy the declaration.
- **Vault unreachable** (index never loaded at O4): match the autoloaded headlines only and declare `Lessons: index unreachable`.
- **Recall out of scope by policy** (a sandboxed run, a worktree with no vault mount): declare `Lessons: skipped — <reason>`; `none match` claims a scan and `index unreachable` claims a failure.

The result feeds the `Lessons:` line at R5. If the operator later corrects you with a rule a recall surface should have matched, that is a **recall failure** — record it at closeout per `core/self-improvement.md`, naming the failed surface, so the miss tunes the triggers instead of duplicating the rule.

### R2. Pick the primary capability

Consult the **harness's installed capability catalog**: Claude Code — `$CLAUDE_CONFIG_DIR/SKILLS.md` plus the quick-reference table in `$CLAUDE_CONFIG_DIR/CLAUDE.md`; Codex — `$CODEX_HOME/AGENTS.md`.

If several capabilities could apply, the task spans surfaces, the quick-reference gives no clean primary, the user asks which capability to use, or risk is high (the R2b list), run the **orchestration sub-routine**: classify the surface, name risk/output/evidence constraints, consult the catalog, compose the chain, and confirm with the user only when routing is non-obvious or risk is high. **Pick the smallest useful chain — one primary, secondaries only for evidence, risk, or output format; don't load whole families.** Full CO1–CO5 detail and composition rules: `$AI_CONFIG_DIR/capabilities/reference/session-agent.md`.

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
   writes each lane's six-line brief (`core/operating-system.md` → "Delegating to
   subagents", discipline-kernel preamble included), executors build, and the
   orchestrator inspects every diff and reruns the proof itself — never a rubber
   stamp.
3. `inline` — the residue: a change neither rule above claimed (single-file
   fixes).

A delegated value may name the lanes' effort level once the Effort rule's calibration
(`core/operating-system.md` → Effort) has settled below high; omit it to run at high.

Roles only — which models fill orchestrator, executor, and critic is the operator
layer's call. The pre-edit gate does not check this line; it exists so the routing
walk asks HOW, not only WHICH.

### R3. Name the verification gate

Choose the matching gate from `$AI_CONFIG_DIR/verification/` — e.g. `code-change`,
`audit-systems`, `data-readiness`, `ui-browser`, `docs-framework`, `high-risk`,
`process-memory`, `tool-freshness`, `deploy-live`.

### R4. Apply Linear

If the task is multi-step or spans sessions, a Linear issue or project must exist before execution. Create it to the canonical standard in `$AI_CONFIG_DIR/linear/issue-template.md` — BOTH halves, at create time: the required-metadata checklist (team; project, or an explicit deliberately-projectless reason in the body; a deliberate priority — never the default "No priority"; at least one label; an assignee, or the standard's deliberately-unassigned reason; parent/relations when spawned by other tracked work) AND the structured body (outcome, scope, acceptance criteria, verification, links). A title + prose-blob issue is nonconforming even when the prose is good. Create it via the installed Linear surface (`$AI_CONFIG_DIR/linear/linear-setup.md` §4). Single-file fixes, trivial edits, and questions stay as session todos. If no write-capable Linear access exists, produce a Linear-ready markdown draft.

### R5. State the chosen chain in one line, then execute

```
Routing: <one-sentence task surface>
Primary skill: <capability name, or "ad-hoc — no specific capability">
Lessons: <matched lesson/note names, body-read ones first> | none match | index unreachable | skipped — <reason>
Verification: <gate name from $AI_CONFIG_DIR/verification/>
Linear gate: <ISSUE-ID or URL> | none — single-step | none — drafted
Execution: inline | delegated wave | delegated wave + panel
```

A delegated value may append its effort level: `Execution: delegated wave (effort:
medium)`.

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

If a later turn changes the `Execution:` value (e.g. `inline` → `delegated
wave`), re-emit the declaration carrying the new value.

**Mid-task Execution checkpoint.** On a task declared `delegated wave` or
`delegated wave + panel`, the driver's third inline edit — a file-modifying call
on task content since the declaration; brief and re-emit do not count — is the
checkpoint: write the lane's brief (then stop editing task content) or re-emit R5
as Mode 2. Keeping the work re-emits `inline`; R2b rule 1 keys the panel to the
PATH, so the reason line carries the still-owed panel and the re-emit never
cancels it. A fourth edit with neither is a second miss; it recurs every three
edits. Q1b records a stale declaration. Definitions: reference doc.

Declare honestly: `none match`, `none — single-step`, and `inline` are valid only
after the scan or the walk actually ran — written by reflex they defeat the gate.
Full notes: the reference doc.
