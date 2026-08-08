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

The spine of every non-trivial task. **It auto-fires at session start** (the
framework session-start hook emits a directive instructing its invocation as the
first action), then re-invokes on every non-trivial prompt to route the request to
the smallest useful capability chain.

Conditional depth — why each rule exists, per-surface alternatives, the full
orchestration walk, case studies — lives in
`$AI_CONFIG_DIR/capabilities/reference/session-agent.md`. Read it on demand; every
must-fire rule is inline below.

**Two modes, one capability.**

| Mode | When | Job |
| --- | --- | --- |
| **Mode 1 — Kickoff orient** | First invocation per session (no prior `session-agent` invocation in transcript) | Orient (O1–O5), then route the first request (R1–R5). |
| **Mode 2 — Route only** | Every subsequent invocation in the same session | Route only (R1–R5). Mode 1's findings are still live in context. |

**Selection rule:** if you have not invoked `session-agent` earlier in this
session, run Mode 1. Otherwise run Mode 2. Each harness realization
(`harnesses/<h>/capabilities/session-agent.md`) documents how its hook detects
prior invocation. Mode 1 is one-shot per session.

---

## Mode 1 — Kickoff orient

Run all five sub-steps. Skipping one is a Mode 1 failure — re-run the missed
sub-step before routing.

**Step 0 — run the orient helper once.** It does the deterministic collection
(tracker + memory) that O1 and O3 consume:

```bash
scripts/orient.sh --memory-dir <this harness's memory store>
# PowerShell: pwsh -File scripts/orient.ps1 -MemoryDir <path>
```

It emits ONE `orient/v1` JSON document — a **projects-first** cut with per-project
open issues, `projectless_open_issues` (the reconciliation net), `mine_in_progress`,
`anomalies`, `memory_pointers`, `surfaces`, and `degraded`. It **degrades, never
fails**: an absent or erroring surface still yields a valid document on exit 0, with
the surface named in `degraded`. Read the script header for the emitted contract.
Non-zero exit means the script itself could not run — then collect by hand per
`$AI_CONFIG_DIR/capabilities/reference/session-agent.md`.

### O1. Read project memory bodies for active-work projects

The harness autoloads `MEMORY.md` — a one-line index of headlines. **Headlines are
not the source of truth.** For each entry in the orient document's
`memory_pointers` (project-type notes, `metadata.type: project`) whose description
names active or recently-active work, `Read` the note body before acting on the
headline. Do NOT re-read `reference_*` / `feedback_*` bodies at kickoff — those are
headline-stable. Cross-issue tracker claims inside those bodies are stale-prone; O5
re-checks them.

### O2. Reconcile session-start hints against memory headlines

The session-start hook surfaces the last 7–10 days of framework commits in
`additionalContext`. Scan them for tracker issue identifiers — the
`<PREFIX>-<number>` shape, where **`<PREFIX>` is your workspace's issue prefix**
(recorded as `TRACKER_ISSUE_PREFIX` in `local.env`). `TEAM` is only the
documentation placeholder; a literal `TEAM-\d+` match finds nothing in a real
workspace and silently disables this whole step. For any identifier whose parent
project's memory headline says `COMPLETE` / `CLOSED` / `DONE`, that is a
contradiction — flag it in the first turn and dig before trusting the headline.
Memory captures what was true when written; the session-start window captures what
is true now. This step is model judgment over context already in the first turn —
no tool calls.

### O3. Read the tracker cut from the orient document

From the emitted JSON: `projects[]` (with each project's open issues),
`projectless_open_issues`, and `mine_in_progress` are the active-work picture. Also:

- **`anomalies[]` — flag every one in the orient summary.** They are the cuts
  disagreeing with each other (`open-issue-count-mismatch`) or a project nobody is
  on (`all-issues-backlog-no-assignee`), not noise.
- **`degraded[]` / `surfaces` — apply the one-line-warning rule.** A degraded
  surface gets exactly one named warning line in the orient summary and the orient
  continues; it is never silently reported as "no active work".

**When `surfaces.linear` is absent or errored, tracker collection is still
MANDATORY:** perform the same projects-first cut BY HAND via the installed surface
(MCP surface, or direct `lineark` calls) per `$AI_CONFIG_DIR/linear/linear-setup.md`
§4. A degraded surface downgrades the METHOD of collection, never the requirement —
"the helper reported the surface down" is not a licence to skip O3.

Per-surface command shapes (and the MCP alternative when `lineark` is not the
installed surface) are in `$AI_CONFIG_DIR/linear/linear-setup.md` §4.

### O4. Vault orient — entrypoint, operator-identity master, AND lesson index

Read **three** notes explicitly — load only the relevant slice, never the whole
vault:

- `Read` `$OBSIDIAN_VAULT_PATH/START.md` — the vault's working rules.
- `Read` the **operator-identity master note** the vault entrypoint designates (the
  `harness: all`-scoped identity note; path is vault-specific). This is its own
  mandatory sub-step, not an optional follow of START.md's prose pointer.
- `Read` `$OBSIDIAN_VAULT_PATH/04-Lessons/_index.md` — the canonical lesson index,
  whose **Trigger column** is what R1a matches against. Keep it in context for the
  session; Mode 2 re-scans it without re-reading. Apply harness scope at body-read
  time from each note's frontmatter `harness:` key.

**Degrade gracefully — never fail the orient.** If the vault is unreachable, or no
identity note is configured, read what you can and continue with a one-line note
(use the harness's per-machine identity cache as the offline fallback if it keeps
one). An unreachable lesson index degrades the same way: note it, declare
`Lessons: index unreachable` at R5, and fall back to the autoloaded memory-index
feedback headlines as the only recall surface.

### O5. Cross-issue tracker state verification

For any cross-issue claims in O1's memory bodies (claims about *other* issues'
states — "`<PREFIX>`-X is Done", "`<PREFIX>`-Y is gating"), verify against the
tracker at kickoff regardless; cross-issue claims are not self-correcting at the
body-read step. Query each concrete `<PREFIX>-<number>` and compare its `state`
against the memory body's claim (read command per
`$AI_CONFIG_DIR/linear/linear-setup.md` §4). Flag mismatches in the orient summary.

### Mode 1 output

End the orient pass with a structured summary the user sees:

```
Orient:
- Active Linear project(s): <list with issue IDs + state>
- Open issues in active project(s): <count + headline list>
- Projectless open issues: <count + list, or "none">
- Anomalies: <one line per anomaly, or "none">
- Memory contradictions vs session-start commits: <one line per contradiction, or "none">
- Vault: <one line of context from START.md>
- Lesson index: <N lessons / triggers loaded | unreachable — recall degraded to memory-index headlines>
- Cross-issue Linear claim verification: <pass / mismatches found>
- Degraded surfaces: <one line per named degraded surface, or "none">
- Safety posture: <report orient's `.safety`: "safe (no guardrail state configured/detected)" or "tightened — <names>">
```

Then proceed immediately to R1–R5 for the user's request — the orient summary and
the routing declaration land in the same first response.

The **Safety posture** line reports what orient DETECTED (`.safety`), not what policy
declares: posture, plus each tightening's name. It defaults to `safe` and can only add
tightenings, never a loosening — contract in `core/operating-system.md` → Per-Run Safety
Posture. Enforcement strength is harness-dependent (hard hooks on some harnesses,
advisory session discipline elsewhere), so never let the line claim hard enforcement it
cannot see: report the detected state and, when detection is `none-configured`, say so.

---

## Mode 2 — Route only

Skip O1–O5. Run only R1–R5. The Mode 1 orient outputs are still live in context.

---

## Routing steps (R1–R5) — used by both modes

### R1. Classify the task surface — one sentence

Bug fix, new feature, refactor, UI, security-sensitive change, data analysis, infra,
docs, audit, ops, review-only, planning, implementation, publish/live.

### R1a. Recall applicable lessons — match triggers, read the few that fire

Match the just-classified surface + the concrete task against **two recall
surfaces**:

1. **The lesson index Trigger column** read at O4. In Mode 2 it is normally already
   in context — re-scan without re-reading. But if it is NO LONGER in context (a
   compaction summarized it away), re-read the file before declaring; never declare
   `none match` from a remembered index.
2. **The autoloaded memory-index headlines.** A match here counts the same as an
   index-trigger match.

For each match, `Read` the note **body** before executing. Bounds:

- **Respect harness scope** — filter on the index's scope column if present,
  otherwise check a matched note's frontmatter `harness:` key and skip foreign
  scopes.
- **Cap APPLICABLE body-reads at ~3**, most-specific-first. Scope-skipped notes do
  not consume the cap; bound total probes at ~6, and name the rest in the
  declaration without reading them.
- **Zero matches is a normal outcome** — declare `Lessons: none match`. Do not
  force-fit a lesson to satisfy the declaration.
- **Vault unreachable** (index never loaded at O4): match against the autoloaded
  headlines only and declare `Lessons: index unreachable`.
- **Recall out of scope by policy** (a sandboxed run, a worktree with no vault
  mount): declare `Lessons: skipped — <reason>` honestly rather than faking
  `none match` (which claims a scan) or `index unreachable` (which claims a
  failure).

The result feeds the `Lessons:` line at R5. If the operator later corrects you with
a rule that WAS in a recall surface this step should have matched, that is a
**recall failure** — record it at closeout per `core/self-improvement.md`, naming
which surface failed, so the miss tunes the triggers instead of duplicating the rule.

### R2. Pick the primary capability

Consult the **harness's installed capability catalog**: Claude Code —
`$CLAUDE_CONFIG_DIR/SKILLS.md` plus the quick-reference table in
`$CLAUDE_CONFIG_DIR/CLAUDE.md`; Codex — the `$CODEX_HOME/AGENTS.md` catalog.

If several capabilities could apply, the task spans surfaces, the quick-reference
does not resolve a clean primary, the user asks which capability to use, or risk is
high (auth/billing/secrets/migrations/public surfaces), run the **orchestration
sub-routine**: classify the surface, name risk/output/evidence constraints, consult
the catalog, compose the chain, and confirm with the user only when routing is
non-obvious or risk is high. **Pick the smallest useful chain — one primary,
secondaries only for evidence, risk, or output format; don't load whole families.**
Full CO1–CO5 detail and the composition rules:
`$AI_CONFIG_DIR/capabilities/reference/session-agent.md`.

If genuinely no capability fits, declare `ad-hoc — no specific capability`.

### R3. Name the verification gate

Choose the matching gate from `$AI_CONFIG_DIR/verification/` — e.g. `code-change`,
`audit-systems`, `data-readiness`, `ui-browser`, `docs-framework`, `high-risk`,
`process-memory`, `tool-freshness`, `deploy-live`.

### R4. Apply the Linear gate

If the task is multi-step or spans more than one session, a Linear issue or project
must exist **before execution**. Create it to the canonical standard in
`$AI_CONFIG_DIR/linear/issue-template.md` — BOTH halves, at create time: the
required-metadata checklist (team; project, or an explicit deliberately-projectless
reason in the body; a deliberate priority — never the default "No priority"; at
least one label; an assignee, or the standard's deliberately-unassigned reason;
parent/relations when the issue is spawned by other tracked work) AND the structured
body (outcome, scope, acceptance criteria, verification, links). A title +
prose-blob issue is nonconforming even when the prose is good. Create it via the
operator's installed Linear surface (`$AI_CONFIG_DIR/linear/linear-setup.md` §4).

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

## Notes

- **Mode 1 fires once per session.** A mid-session pivot uses Mode 2. The operator
  can force a re-orient by saying "re-orient" — that is a Mode 1 re-run.
- **Be honest on the Linear gate.** Splitting genuine multi-session work into
  "single-step" to skip the gate defeats the protocol.
- **Be honest on the Lessons line.** `none match` after an actual trigger scan is a
  valid answer; `none match` as a reflex to satisfy the gate defeats the recall step
  — the line exists because rules that were already recorded kept getting skipped.
  `index unreachable` claims a failure and `skipped — <reason>` claims a policy
  bound; use whichever is true.
- **The gate enforces the first complete declaration per session.** Later Mode 2
  routes re-declare by protocol, but the hook does not re-police them per task — it
  is a discipline net with a kill switch, not a security boundary.
- **Mode 1 is expensive, Mode 2 is cheap.** Don't re-orient on every prompt.
