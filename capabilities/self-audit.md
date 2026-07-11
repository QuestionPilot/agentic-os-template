---
name: self-audit
summary: Score the agentic OS on five leverage-weighted pillars (cross-layer handoffs / memory hygiene / folder hygiene / verification coverage / closeout + spine discipline), surface the top-3 gaps with concrete fixes. Read-only diagnostic — never auto-remediates. The third native spine capability after session-agent + closeout.
triggers: [user says /self-audit or "audit the framework", periodic framework-hygiene checks, before claiming the framework is "in good shape", after a wave of merges to confirm nothing thinned out, debugging "why does this still feel rough"]
verification: self-audit
harnesses: [claude, codex, hermes]
kind: native
lifecycle: shipped
---

# Self-Audit — Framework Health Scorecard

The framework already has PASS/FAIL gates: `bash scripts/validate.sh`,
`bash scripts/check-drift.sh --manifest "$CLAUDE_CONFIG_DIR"`, and — where the
upstream acceptance suite is present — `bash tests/run.sh`. They answer "is
anything broken?" — they do not answer
"where are we thinning out?" Self-audit closes that gap with a five-pillar
leverage-weighted scorecard against the framework's own state across all three
layers (agentic-os-template / Linear / vault).

The capability is **read-only**. It never auto-fixes. The output is a scorecard
+ a ranked list of gaps + concrete next steps; gap closure is the operator's
call.

## When to invoke

- The operator types `/self-audit` (or invokes the `self-audit` skill).
- After a wave of merges, before claiming "in good shape".
- Periodic hygiene — weekly or monthly.
- When something feels rough but no PASS/FAIL gate catches it.

It is **not** auto-fired. Of the three spine capabilities, only `session-agent`
carries a session-start directive; `closeout` and `self-audit` are invoked
manually (closeout's `Stop` gate was removed because it re-fired on closeout's own writes).

## The five pillars

Each pillar is scored 0–20. Total is 0–100. Below ~80 is "actively thinning";
~80–95 is "healthy with named gaps"; ~95–100 is "actually in good shape".

**UNSCORED pillars depress the total by design.** A pillar whose surface is not
configured (no Linear/`lineark`, no memory dir, no vault) cannot be measured, so it
is **floored to 0 and flagged `UNSCORED`** — never left at the seeded 20. This
follows `core/verification.md`: a check that cannot run must fail, never pass.
Consequence: a fresh clone with operator surfaces unwired lands well below 95 (e.g.
two UNSCORED pillars cap the total at 60), and the scorecard prints a one-line
`N of 5 pillars UNSCORED` banner. Do **not** read a number near the bottom of the
range as "thinning" when the cause is UNSCORED pillars — wire the surface and
re-audit to score them. The bands above describe a fully-measured run.

| Pillar | What it scores |
| --- | --- |
| **1. Cross-layer handoffs** | Each Active Linear project (≥1 open issue — closed-out projects with all issues Done/Canceled are skipped) has a project-type memory note (frontmatter `metadata.type: project`) + a vault Handshake note (`linear:` frontmatter); MEMORY.md cross-references resolve to real files |
| **2. Memory hygiene** | MEMORY.md index has a one-line entry per memory file (no orphans); index byte-size stays under the recall cap (~24400); the per-session **injection surface** — the largest store's MEMORY.md + the rendered `$CLAUDE_CONFIG_DIR/CLAUDE.md` + the vault `START.md` + the operator-identity note it names (the first `[[wikilink]]` before `## Read Order`) — stays under the soft `INJECTION_SURFACE_WARN_KB` budget (default 32 KB). Crossing the budget is a 2-pt **warn, never a hard cap** (a design panel rejected one — a large surface can be deliberate); components that do not resolve are skipped by name |
| **3. Folder hygiene** | No empty dirs in framework-tracked surfaces; no anti-pattern names (`tmp/`, `misc/`, `notes/`, `scratch/`, `junk/`); `lifecycle: superseded` files cite their successor; `lifecycle: sunset` files explain why |
| **4. Verification coverage** | Every capability's `verification:` value resolves to an existing recipe; every `verification/*.md` recipe is referenced **by name** in a routing surface — a capability's `verification:` frontmatter, the `session-agent` R3 gate list, or a playbook/core routing doc (a heuristic check: an incidentally-named recipe counts as referenced, so only a recipe named nowhere flags as orphan); the operator's `$CLAUDE_CONFIG_DIR` build manifest is fresh against source |
| **5. Closeout / spine discipline** | Native spine count is symmetric across harnesses (each harness a capability declares in its `harnesses:` frontmatter — claude, codex, hermes — carries every `kind: native` capability); project-type memory notes modified in the last 7 days carry a `## State Deltas` section |

**Out of scope for v1 (deferred to future PRs, when Linear is reachable from the audit run):** state-delta memory writes matched against Linear comments; project memory headline reconciled against Linear state; "recent Linear activity" cross-referenced with "recent file mtime". These are non-trivial to score deterministically and the cost outweighs the v1 benefit; the rubric checks only what the local filesystem can prove today.

**Companion qualitative check — vault-promotion lag (Pillar 2).** Beyond the scored index hygiene, when running `/self-audit` also judge whether durable lessons are *reaching the durable-knowledge vault* or only accumulating in local auto-memory. Compare the newest durable-class memory write against the newest vault Lesson/Decision note: a multi-day gap means the closeout `obsidian` promotion step has lapsed and durable knowledge is stranded in the disposable cache. This stays qualitative (not part of the 0–100 score) because most auto-memory is correctly local — only the operator-durable subset should ever be promoted, so a raw count would be noise. If the operator ships a promotion-sweep helper, run it; otherwise eyeball the newest memory mtimes against the vault index dates. Flag a stale lag as a Pillar-2 gap and name the un-promoted candidates.

**Companion qualitative check — recall efficacy (Pillar 2).** The scored checks and the promotion-lag check above are all **write-side**; a store can score 100 while sessions still skip recorded rules — the read-side failure an operator experiences as "I keep re-teaching things." Judge the read side from two signals: (a) **recall failures recorded** — scan the newest ~10 vault session logs (`30-Archive/Sessions/`, ordered by the timestamp in the FILENAME, never mtime — the vault is cloud-synced) for closeout Q1a recall-failure entries (operator re-taught an existing rule); any hit in the window is a Pillar-2 gap naming the failed surface (not-loaded vs loaded-but-ignored). (b) **Recall surfaces intact** — spot-check that the session-agent orient is actually reading the vault lesson index (O4). For the per-harness autoloaded indexes, check first for **actively-misleading entries** (facts that are now provably false — the failure that matters), and only secondarily for age: a cache whose newest content lags the vault by weeks is a weaker signal now that every orient reads the vault lesson index directly, and harness caches are separate stores that need not mirror each new lesson. Stays qualitative (not part of the 0–100 score): session-log text and content dates cannot be scored deterministically without brittle parsing. Flag findings as Pillar-2 gaps with the concrete fix (store placement, trigger rephrasing, cache rebuild).

**Companion qualitative check — skill/capability authoring quality (Pillar 4).** Beyond the scored
recipe-coverage check, when auditing skill or capability quality judge it against the authoring
standard in `$AI_CONFIG_DIR/skills/skill-authoring.md`: a skill that bloats its
body with conditional content (multiplicative cost), buries a load-bearing rule behind a reference,
re-implements deterministic processing the model should offload to a script, or asserts prose instead
of structure is *thinning* even when no PASS/FAIL gate fires — which is exactly the kind of erosion
this scorecard exists to catch. This stays qualitative (not part of the 0–100 score) because authoring
quality is a judgment, not a deterministic count.

The pillars are scored by `scripts/self-audit.sh`. The script is the source of
truth for the rubric — this prose describes what the rubric checks, but the
script's penalty rules are the canonical scoring.

## Procedure

1. **Run the scoring script:**
   ```bash
   bash scripts/self-audit.sh
   ```
   With no flags it **reads `local.env`** (the same file `bootstrap.sh` /
   `install.sh` use) and resolves three optional surfaces from it: the memory
   dir under `$CLAUDE_CONFIG_DIR/projects/*/memory/`, the vault at
   `$OBSIDIAN_VAULT_PATH`, plus `lineark` if installed. It **parses just the
   four config keys as data** (those two paths, `CLAUDE_PRIMARY_MEMORY_DIR`,
   and `INJECTION_SURFACE_WARN_KB`) rather than sourcing the file — both twins
   (`self-audit.sh`, `self-audit.ps1`) read the keys without executing
   `local.env`, so a hostile or malformed file can neither run code nor poison
   the `lineark`/`jq`/`git` lookups. Reading `local.env`
   rather than the ambient environment is what makes the score **reproducible** —
   two shells score the same repo identically whether or not they happened to
   export those vars. `local.env` wins over ambient env; explicit
   `--config-dir` / `--vault-dir` / `--memory-dir` flags still win over
   `local.env`. When several `projects/*/memory/` dirs exist (a multi-project
   `$CLAUDE_CONFIG_DIR`), the script scans **all** of them and attributes each
   gap to the store it fired in — a hygiene signal in a small secondary store
   counts the same as one in the main store. (The old primary-store picker
   scored only the dir with the most project-typed notes, so every other store
   went silently unscanned — and the pick could flip stores when note counts
   shifted, emitting pillar demands against the wrong store.) Set
   `CLAUDE_PRIMARY_MEMORY_DIR` in `local.env` to pin scoring to a single store;
   the explicit `--memory-dir` flag likewise means exactly one store. Each surface
   is optional — the script degrades gracefully and notes "skipped: <surface> not
   configured" in the output. Pass `--repo-root <path>` to point at a different
   agentic-os-template checkout (the test suite uses this).

   The injection-surface budget (Pillar 2 sub-check) is tunable: precedence is
   the `--injection-warn-kb <n>` flag > `INJECTION_SURFACE_WARN_KB` in
   `local.env` > the ambient env var > the 32 KB default. The value is whole
   KB; a non-positive or non-integer value silently falls back to the default
   (the check is advisory, so a bad knob must not break the audit).

2. **Read the scorecard.** The script's default output is human-readable
   markdown. The top-of-output total + per-pillar scores are the answer; the
   "Top gaps" section below ranks the most leverage-bearing gaps with concrete
   next-step commands.

3. **For each surfaced gap, decide:** fix now (small, in-scope), file a Linear
   issue (multi-step), or accept-with-rationale (cost > benefit). The audit
   does not make the decision.

4. **Optional persistence.** Run with `--save audits/<date>.md` to write the
   scorecard to a tracked file (operator can diff against a previous audit to
   see trend). Without `--save`, the audit is transcript-only.

5. **Record the run for trend tracking.** Pipe the run's `--json` output into
   the history helper so the per-pillar scores accumulate over time:
   ```bash
   bash scripts/self-audit.sh --json | bash scripts/self-audit-history.sh append
   ```
   This appends ONE record to the operator-local history store (see
   [Trend tracking](#trend-tracking) below). It does not touch the framework
   tree — the only file written is the gitignored store. Skip this step for a
   throwaway audit; run it whenever you want the run to count toward the trend.

6. **Re-audit after fixes** to confirm the score moved. A pillar's score not
   moving despite a "fix" is a signal the fix did not address the rubric.

## Trend tracking

The scorecard above is point-in-time. To see whether the framework is
*improving or thinning over time*, self-audit keeps a per-run score history and
a trend view across the last N runs.

History is **runtime, per-operator state**, so it is NOT committed to the
agentic-os-template repo (no repo churn; portable across operators). It persists in an
operator-local JSONL store keyed off `$CLAUDE_CONFIG_DIR`, defaulting to:

```
$CLAUDE_CONFIG_DIR/self-audit-history.jsonl
```

This matches the existing convention for operator-local runtime artifacts
(`cross-model-out/`, `$CLAUDE_CONFIG_DIR/.build-manifest.json`). The store is
gitignored (`self-audit-history.jsonl`) so it can never be staged even if an
operator's `$CLAUDE_CONFIG_DIR` happens to point inside a checkout. Each line is
one record:

```json
{"timestamp":"2026-05-30T18:00:00Z","total":94,"overall":94,"pillars":{"cross-layer-handoffs":20,"memory-hygiene":20,"folder-hygiene":20,"verification-coverage":14,"closeout-spine-discipline":20}}
```

The capability stays **read-only with respect to the framework tree** — the
only file ever written is the operator-local store, via the dedicated helper
`scripts/self-audit-history.{sh,ps1}` (bash + PowerShell twins). The scoring
script `self-audit.sh` itself never writes the store; appending is an explicit,
opt-in pipe step the operator runs.

**Append a run** (step 5 of the Procedure):

```bash
bash scripts/self-audit.sh --json | bash scripts/self-audit-history.sh append
```

`append` validates the piped `--json` scorecard (a malformed or `--json`-failed
producer has no numeric `.total`, so the helper refuses to write a junk record)
and appends exactly one record. It is append-only — N runs leave N records.
Pass an explicit store path as the first argument to target a non-default store
(the test suite uses a temp store; never the operator's real one).

**View the trend** over the last N runs (default 5):

```bash
bash scripts/self-audit-history.sh trend            # last 5 runs
bash scripts/self-audit-history.sh trend "" 10      # last 10 runs
```

The trend view prints a per-pillar table — one column per recorded run, one row
per pillar (plus a Total row) — with a `Δ (latest)` column showing the
newest-run-vs-prior delta per pillar. A pillar trending *down* across columns is
the framework thinning out in that dimension even if no PASS/FAIL gate fired. An
absent or empty store degrades gracefully with a one-line "no history yet" note
and instructions to append the first run.

## Leverage weighting

The script ranks each gap by a leverage score so that *what to fix first* is
not the same as *which pillar lost the most points*. Today's v1 implementation
uses **class-based leverage** — each gap class has a fixed weight reflecting
how widely a gap of that class radiates through the framework:

| Class | Leverage |
| --- | --- |
| Spine asymmetry (a `kind: native` capability missing a harness realization) | 10 |
| Active Linear project with no memory file | 8 |
| Capability declares `verification:` pointing at a missing recipe | 8 |
| Active Linear project with no vault handshake | 6 |
| Build manifest drift in `$CLAUDE_CONFIG_DIR` | 6 |
| MEMORY.md over recall cap | 5 |
| Anti-pattern dir name in repo | 5 |
| Broken MEMORY.md link | 4 |
| Recent project memory missing `## State Deltas` | 4 |
| Injection surface over the soft `INJECTION_SURFACE_WARN_KB` budget | 4 |
| Orphan memory file (no MEMORY.md entry) | 3 |
| Orphan `verification/*.md` (no capability consumer) | 3 |
| `lifecycle: superseded` artifact missing successor reference | 3 |
| Empty dir in repo | 2 |

The top-3 gaps are leverage-ranked, not penalty-amount-ranked. A pillar can
score 18/20 (small absolute penalty) and still surface its single gap as the
top finding if that gap has high leverage.

**Out of scope for v1:** dynamic reference-counted leverage (e.g. "this stale
memory is named by 5 active wiki-links, so its leverage is 5 + base"). The v1
class-weights approximate this well enough for actionable triage; the dynamic
version is a future enhancement when the script accumulates a known false-rank
case.

## Output

The script emits a markdown scorecard. Its skeleton:

```
# /self-audit scorecard — <YYYY-MM-DD>

Total: <N>/100

> **<N> of 5 pillars UNSCORED** — surface not configured … (only when N > 0)

| Pillar | Score | Notes |
| --- | --- | --- |
| 1. Cross-layer handoffs            | <N>/20 or UNSCORED | <one line> |
| 2. Memory hygiene                  | <N>/20 or UNSCORED | <one line> |
| 3. Folder hygiene                  | <N>/20 | <one line> |
| 4. Verification coverage           | <N>/20 | <one line> |
| 5. Closeout / spine discipline     | <N>/20 | <one line> |

## Injection surface

- <component>: <bytes> bytes (<path>)      (one line per resolved component)
- skipped: <component>, <component>        (only when some components skipped)
Total: <bytes> bytes — soft threshold <K> KB (OK|OVER)

## Top gaps (leverage-weighted)

1. [Pillar N] <one-sentence gap> — leverage <N>
   Fix: <one concrete next-step command or edit>
2. ...
3. ...

## Skipped surfaces

- <surface>: <reason> (e.g. "lineark not installed; cross-layer Linear checks skipped")
```

The `## Injection surface` section lists each resolved component with its byte
size, names any component that could not resolve on a `skipped:` line, and
closes with the total against the soft threshold. When no component resolves at
all it reads `_(not measured — no injection-surface component resolved)_`.

If `--json` is passed, the script emits a structured JSON object with
`{total, unscored_count, pillars[name].score, pillars[name].unscored,
pillars[name].notes, injection_surface, gaps[] }` — used by the upstream
acceptance suite's `tests/self-audit.test.sh` to assert against specific scores.
An UNSCORED pillar reports `score: 0, unscored: true`; the history helper
records that 0 truthfully. `injection_surface` is `null` when no component
resolved, else `{total_bytes, threshold_kb, warned, components[{name, path,
bytes}], skipped[]}`.

## Limits

- **No auto-remediation.** Self-audit never edits framework files, never
  posts to Linear, never modifies the vault. The model invoking `/self-audit`
  has only `Read`, `Bash`, `Glob` in its tool envelope — `Write`/`Edit` are
  deliberately excluded. The scoring script writes a tracked artifact only when
  `--save <path>` is passed explicitly; absent that flag, the audit is
  transcript-only. The only other write surface is the trend-history `append`
  step, which writes solely to the gitignored, operator-local history store
  (never the framework tree) — see [Trend tracking](#trend-tracking). Gap
  closure is the operator's call.
- **Not a substitute for the PASS/FAIL gates.** `validate.sh`,
  `check-drift.sh`, and — where the upstream acceptance suite is present —
  `tests/run.sh` catch hard breakage. Self-audit catches thinning. Run both.
- **Graceful degradation.** Missing `lineark`, missing `OBSIDIAN_VAULT_PATH`,
  missing `$CLAUDE_CONFIG_DIR` are skipped with a one-line note — the audit
  scores what it can see and tells you what it could not.
- **Operator-local state.** The scorecard reflects the operator's local
  installed state (memory files, vault notes, Linear). Two operators of the
  same agentic-os-template repo will see different scores.

## Notes

- The capability **does not auto-fire**. Only the session-start hook for
  `session-agent` fires automatically; `/self-audit` is opt-in.
- The verification gate `self-audit` (in `verification/self-audit.md`) covers
  the meta-question "does the audit produce a sane, actionable scorecard?"
  — answered by running the script against fixtures.
- The capability is the framework's third `kind: native` spine entry. Spine
  symmetry — every native capability has a realization for each harness it
  declares in its `harnesses:` frontmatter (claude, codex, hermes) — is itself
  one of the things Pillar 5 scores.
