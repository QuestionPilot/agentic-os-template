---
name: self-audit
summary: Score the agentic OS on five leverage-weighted pillars (cross-layer handoffs / memory hygiene / folder hygiene / verification coverage / closeout + spine discipline), surface the top-3 gaps with concrete fixes. Read-only diagnostic — never auto-remediates. The third native spine capability after session-agent + closeout.
triggers: [user says /self-audit or "audit the framework", periodic framework-hygiene checks, before claiming the framework is "in good shape", after a wave of merges to confirm nothing thinned out, debugging "why does this still feel rough"]
verification: self-audit
harnesses: [claude, codex, hermes, cursor]
kind: native
lifecycle: shipped
---

# Self-Audit — Framework Health Scorecard

The framework already has PASS/FAIL gates: `bash $AI_CONFIG_DIR/scripts/validate.sh`,
`bash $AI_CONFIG_DIR/scripts/check-drift.sh --manifest "$CLAUDE_CONFIG_DIR"`, and — where
the upstream acceptance suite is present — `bash tests/run.sh`. They answer "is anything
broken?" — not "where are we thinning out?" Self-audit closes that gap with a
five-pillar leverage-weighted scorecard against the framework's own state across all
three layers (agentic-os-template / Linear / vault).

The capability is **read-only** and never auto-fixes. The output is a scorecard + a
ranked list of gaps + concrete next steps; gap closure is the operator's call.

## When to invoke

- The operator types `/self-audit` (or invokes the `self-audit` skill).
- After a wave of merges, before claiming "in good shape".
- Periodic hygiene — weekly or monthly.
- When something feels rough but no PASS/FAIL gate catches it.

It is **not** auto-fired. Of the three spine capabilities, only `session-agent`
carries a session-start directive; `closeout` and `self-audit` are invoked manually.

## The five pillars

Each pillar is scored 0–20. Total is 0–100. Below ~80 is "actively thinning";
~80–95 is "healthy with named gaps"; ~95–100 is "actually in good shape".

**UNSCORED pillars depress the total by design.** A pillar whose surface is not
configured (no Linear/`linear` CLI, no memory dir, no vault) cannot be measured, so it
is **floored to 0 and flagged `UNSCORED`** — never left at the seeded 20, per
`core/verification.md`: a check that cannot run must fail, never pass. So the bands
above describe a fully-measured run only. A fresh clone with operator surfaces unwired
lands well below 95 (two UNSCORED pillars cap the total at 60) and prints a one-line
`N of 5 pillars UNSCORED` banner — do **not** read that as "thinning"; wire the surface
and re-audit to score it.

| Pillar | What it scores |
| --- | --- |
| **1. Cross-layer handoffs** | Each Active Linear project (≥1 open issue — closed-out projects with all issues Done/Canceled are skipped) has a project-type memory note (frontmatter `metadata.type: project`) + a vault Handshake note (`linear:` frontmatter); MEMORY.md cross-references resolve to real files |
| **2. Memory hygiene** | MEMORY.md index has a one-line entry per memory file (no orphans); index byte-size stays under the recall cap (~24400) and each entry under the ~300-char per-line cap — **both caps apply to the framework's own per-note memory stores only**. Sub-check 2.5, the per-session **injection surface**: the largest per-note store's MEMORY.md + the rendered harness entrypoint + the vault `START.md` + the operator-identity note it names (the first `[[wikilink]]` before `## Read Order`) stays under the soft `INJECTION_SURFACE_WARN_KB` budget (default 32 KB). Crossing it is a 2-pt **warn, never a hard cap** — a large surface can be deliberate — and components that do not resolve are skipped by name. Sub-check 2.6, the **per-note body budget**: the caps above bound the *index*, but nothing bounded the project-type note **bodies** the index points at — exactly what a kickoff orient dereferences — so any project-type note over the soft `PROJECT_NOTE_BODY_WARN_KB` budget (default 16 KB) triggers one aggregate 2-pt warn and a named gap, never a hard cap. The codex-native memory registry (`$CODEX_HOME/memories`) is scored for index **presence** only: it is consolidator-owned and no codex-side size or read-truncation limit exists (verified at upstream tag `rust-v0.144.1`), so its size is **reported informationally** — never deducted, never a gap — and it is excluded from the injection-surface largest-store pick |
| **3. Folder hygiene** | No empty dirs in framework-tracked surfaces; no anti-pattern names (`tmp/`, `misc/`, `notes/`, `scratch/`, `junk/`); `lifecycle: superseded` files cite their successor; `lifecycle: sunset` files explain why |
| **4. Verification coverage** | Every capability's `verification:` value resolves to an existing recipe; every `verification/*.md` recipe is referenced **by name** in a routing surface — a capability's `verification:` frontmatter, the `session-agent` R3 gate list, or a playbook/core routing doc (heuristic: only a recipe named nowhere flags as orphan); the operator's `$CLAUDE_CONFIG_DIR` build manifest is fresh against source |
| **5. Closeout / spine discipline** | Native spine count is symmetric across harnesses (each harness a capability declares in its `harnesses:` frontmatter — claude, codex, hermes, cursor — carries every `kind: native` capability); project-type memory notes modified in the last 7 days carry a `## State Deltas` section |

**Semantic currentness — reported, never scored.** Every pillar above is
**mechanical**: it proves a structural property of the local filesystem. All five
can score 20/20 while a memory note or an active vault project note confidently
asserts a tracker state that changed hours ago — perfectly tidy and materially
wrong at once. `$AI_CONFIG_DIR/scripts/check-state-currentness.sh` (PowerShell twin:
`check-state-currentness.ps1`) closes that: it reconciles tracker-state CLAIMS in
the scanned memory stores and in `status: active` vault project notes against
live tracker state, and flags project-status/child contradictions
(`project-closed-with-open-children`, `project-idle-with-active-children`,
`project-active-with-no-open-children`).

Its findings land in their **own** `## Semantic currentness` markdown section and
their **own** `semantic_currentness` JSON key — never in `total`, a pillar score,
or `gaps`. That separation is the point: an advisory heuristic must not move the
number, and the number must not imply currentness. Undated present-tense
assertions are `stale-claim`; claims under an explicitly dated heading are
`stale-snapshot` (a refresh backlog, not a lie); `## State Deltas` and other
history logs are skipped outright, because a dated record of what was true then
stays correct forever. When the tracker is unreachable, unauthenticated, or no
issue prefix is configured, the check fails **soft** — the section reads
`_(skipped — <named reason>)_` and the filesystem score is untouched.

The extractor is a deliberately restrained heuristic, and **under-reporting is the
chosen bias** — a missed stale claim costs one audit cycle, a false accusation costs
trust in the whole signal. Both twins' tests pin the known false positives as
regression anchors; loosening one twin without the other is twin divergence.

**Operator sub-gates — aggregated and named, never scored.** Operators accumulate
their own semantic checker scripts over time and nothing aggregates them. The failure
mode is quiet: this scorecard reads 100/100 while every operator gate fails, or worse,
while one silently stopped being run at all. Point `AUDIT_SUBGATES_FILE` in `local.env`
at a registry file (one `name = command` per line; `#` comments and blank lines
ignored) and each run executes every registered gate with a bounded timeout (60s per
gate) and reports it in a `## Operator sub-gates` section + an `operator_subgates` JSON
key: name, status (`pass` on exit 0 / `fail` with the exit code / `error` on timeout or
a malformed line), and the first line of output as detail. The registry path must be
**absolute** (a relative one is a named skip, never resolved against the caller's cwd),
at most **64** entries are executed per run (the rest are reported as a named drop
count), and the ceiling is enforced from **outside** the gate — each gate runs in its
own process group and is killed as a group on overrun, so a gate that traps the timeout
signal or spawns workers is still bounded and still cleaned up.

The surface is **informational only** — it never touches `total`, a pillar score, or
`gaps`, the same separation `## Semantic currentness` holds: the framework cannot know
an operator gate's semantics, so it must not price one into the framework's own number;
what it can do is stop the gate from being invisible. An unset key, a missing registry,
an empty registry, or `--no-subgates` all render the section as a **named skip** with
`operator_subgates: null` — a skipped registry is never a clean pass.

> **Security.** The registry is operator-authored **executable** content at the same
> trust level as a harness hook: self-audit runs whatever it names, so review a
> registry exactly as you would review a hook script, and never point the key at a
> file you did not write. The `local.env` posture is unchanged — both twins still
> parse `local.env` keys as *data* and never execute the file itself.

**Still out of scope:** state-delta memory writes matched against Linear closeout comments; "recent Linear activity" cross-referenced with "recent file mtime" — non-trivial to score deterministically, and the cost outweighs the benefit today.

**Companion qualitative check — vault-promotion lag (Pillar 2).** Beyond the scored index hygiene, judge whether durable lessons are *reaching the durable-knowledge vault* or only accumulating in local auto-memory: compare the newest durable-class memory write against the newest vault Lesson/Decision note — via the operator's promotion-sweep helper when one ships, else by mtime. A multi-day gap means the closeout `obsidian` promotion step has lapsed and durable knowledge is stranded in the disposable cache. Stays qualitative (not part of the 0–100 score) because most auto-memory is correctly local — only the operator-durable subset should ever be promoted, so a raw count would be noise. Flag a stale lag as a Pillar-2 gap and name the un-promoted candidates.

**Companion qualitative check — recall efficacy (Pillar 2).** The scored checks and the promotion-lag check above are all **write-side**; a store can score 100 while sessions still skip recorded rules — the read-side failure an operator experiences as "I keep re-teaching things." Judge the read side from two signals. (a) **Recall failures recorded** — `$AI_CONFIG_DIR/scripts/recall-report.sh` (PowerShell twin: `recall-report.ps1`) counts the closeout Q1a recall-failure records across the newest N meaningful session logs in `30-Archive/Sessions/`, ordered by the timestamp in the FILENAME, never mtime (the vault is cloud-synced), and the audit reports its counts in a `## Recall failures` section + a `recall_failures` JSON key. That count is **informational and never scored**, and deliberately not a gap-on-any-hit rule: grading a self-reported miss count makes the honest act — recording the miss — the costly one, and the records stop being written. Read it as a rolling rate over time, and open a Pillar-2 gap only when you can name the *surface* that failed (not-loaded vs loaded-but-ignored) and the concrete fix. An unmeasured window is a NAMED skip, never a clean zero. (b) **Recall surfaces intact** — spot-check that the session-agent orient is actually reading the vault lesson index (O4). For the per-harness autoloaded indexes, check first for **actively-misleading entries** (facts now provably false — the failure that matters) and only secondarily for age: harness caches are separate stores that need not mirror each new lesson now that every orient reads the vault lesson index directly. Stays qualitative — session-log text and content dates cannot be scored deterministically without brittle parsing. Flag findings as Pillar-2 gaps with the concrete fix (store placement, trigger rephrasing, cache rebuild).

**Companion qualitative check — skill/capability authoring quality (Pillar 4).** Beyond the
scored recipe-coverage check, judge skill and capability quality against the authoring standard
in `$AI_CONFIG_DIR/skills/skill-authoring.md`: a body that bloats itself with conditional
content (multiplicative cost), buries a load-bearing rule behind a reference, narrates step
scripts a current model derives on its own, re-implements deterministic processing the model
should offload to a script, or asserts prose instead of structure is *thinning* even when no
PASS/FAIL gate fires — exactly the erosion this scorecard exists to catch. Stays qualitative
because authoring quality is a judgment, not a deterministic count.

The pillars are scored by `$AI_CONFIG_DIR/scripts/self-audit.sh`. The script is the source of
truth for the rubric — this prose describes what the rubric checks, but the
script's penalty rules are the canonical scoring.

## Procedure

1. **Run the scoring script:**
   ```bash
   bash $AI_CONFIG_DIR/scripts/self-audit.sh
   ```
   With no flags it **reads `local.env`** (the same file `bootstrap.sh` /
   `install.sh` use) and resolves three optional surfaces from it: the memory
   dir under `$CLAUDE_CONFIG_DIR/projects/*/memory/`, the vault at
   `$OBSIDIAN_VAULT_PATH`, plus the `linear` CLI if installed. It **parses just the
   four config keys as data** (those two paths, `CLAUDE_PRIMARY_MEMORY_DIR`, and
   `INJECTION_SURFACE_WARN_KB`) rather than sourcing the file, so a hostile or
   malformed file can neither run code nor poison the `linear`/`jq`/`git` lookups.
   Reading `local.env` rather than the ambient environment is what makes the score
   **reproducible** — two shells score the same repo identically whether or not they
   happened to export those vars. Precedence: explicit `--config-dir` /
   `--vault-dir` / `--memory-dir` flags > `local.env` > ambient env. When several
   `projects/*/memory/` dirs exist, the script scans **all** of them and attributes
   each gap to the store it fired in — a hygiene signal in a small secondary store
   counts the same as one in the main store, where the old primary-store picker left
   every other store silently unscanned. Set `CLAUDE_PRIMARY_MEMORY_DIR` in
   `local.env` to pin scoring to a single store; the explicit `--memory-dir` flag
   likewise means exactly one store. Each surface is optional — the script degrades
   gracefully and notes "skipped: <surface> not configured" in the output. Pass
   `--repo-root <path>` to point at a different agentic-os-template checkout (the
   test suite uses this).

   Both soft budgets are tunable with the same precedence and the same silent
   fallback on a non-positive or non-integer value (the checks are advisory, so a
   bad knob must not break the audit): `--injection-warn-kb <n>` >
   `INJECTION_SURFACE_WARN_KB` > ambient env > 32 KB, and
   `--project-note-warn-kb <n>` > `PROJECT_NOTE_BODY_WARN_KB` > ambient env > 16 KB.

2. **Read the scorecard.** Default output is human-readable markdown: the
   top-of-output total + per-pillar scores are the answer, and the "Top gaps"
   section ranks the most leverage-bearing gaps with concrete next-step commands.

3. **For each surfaced gap, decide:** fix now (small, in-scope), file a Linear
   issue (multi-step), or accept-with-rationale (cost > benefit). The audit
   does not make the decision.

4. **Optional persistence.** Run with `--save audits/<date>.md` to write the
   scorecard to a tracked file (operator can diff against a previous audit to
   see trend). Without `--save`, the audit is transcript-only.

5. **Record the run for trend tracking.** Pipe the run's `--json` output into
   the history helper so the per-pillar scores accumulate over time:
   ```bash
   bash $AI_CONFIG_DIR/scripts/self-audit.sh --json | bash $AI_CONFIG_DIR/scripts/self-audit-history.sh append
   ```
   Appends ONE record to the operator-local history store (see
   [Trend tracking](#trend-tracking)); the only file written is the gitignored
   store. Skip it for a throwaway audit.

6. **Re-audit after fixes** to confirm the score moved. A pillar's score not
   moving despite a "fix" is a signal the fix did not address the rubric.

## Trend tracking

The scorecard above is point-in-time. To see whether the framework is
*improving or thinning over time*, self-audit keeps a per-run score history and
a trend view across the last N runs.

History is **runtime, per-operator state**, so it is NOT committed to the
agentic-os-template repo. It persists in an operator-local JSONL store keyed off
`$CLAUDE_CONFIG_DIR`, defaulting to:

```
$CLAUDE_CONFIG_DIR/self-audit-history.jsonl
```

That matches the convention for operator-local runtime artifacts. The store is
gitignored (`self-audit-history.jsonl`) so it can never be staged even if an
operator's `$CLAUDE_CONFIG_DIR` happens to point inside a checkout. Each line is
one record:

```json
{"timestamp":"2026-05-30T18:00:00Z","total":94,"overall":94,"pillars":{"cross-layer-handoffs":20,"memory-hygiene":20,"folder-hygiene":20,"verification-coverage":14,"closeout-spine-discipline":20}}
```

The capability stays **read-only with respect to the framework tree** — the only
file ever written is the operator-local store, via the dedicated helper
`$AI_CONFIG_DIR/scripts/self-audit-history.{sh,ps1}` (bash + PowerShell twins). The scoring
script `self-audit.sh` itself never writes the store; appending is the explicit,
opt-in pipe step at Procedure step 5.

`append` validates the piped `--json` scorecard (a malformed or `--json`-failed
producer has no numeric `.total`, so the helper refuses to write a junk record)
and appends exactly one record. It is append-only — N runs leave N records.
Pass an explicit store path as the first argument to target a non-default store
(the test suite uses a temp store; never the operator's real one).

**View the trend** over the last N runs (default 5):

```bash
bash $AI_CONFIG_DIR/scripts/self-audit-history.sh trend            # last 5 runs
bash $AI_CONFIG_DIR/scripts/self-audit-history.sh trend "" 10      # last 10 runs
```

The trend view prints a per-pillar table — one column per recorded run, one row per
pillar plus a Total row — with a `Δ (latest)` column per pillar. A pillar trending
*down* across columns is the framework thinning out in that dimension even if no
PASS/FAIL gate fired. An absent or empty store degrades gracefully with a "no history
yet" note and instructions to append the first run.

## Leverage weighting

The script ranks each gap by a leverage score, so *what to fix first* is not the
same as *which pillar lost the most points*. v1 uses **class-based leverage** — a
fixed weight per gap class, reflecting how widely a gap of that class radiates:

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
| Project-type note body over the soft `PROJECT_NOTE_BODY_WARN_KB` budget | 4 |
| Orphan memory file (no MEMORY.md entry) | 3 |
| Orphan `verification/*.md` (no capability consumer) | 3 |
| `lifecycle: superseded` artifact missing successor reference | 3 |
| Empty dir in repo | 2 |

The top-3 gaps are leverage-ranked, not penalty-amount-ranked. A pillar can
score 18/20 (small absolute penalty) and still surface its single gap as the
top finding if that gap has high leverage.

**Out of scope for v1:** dynamic reference-counted leverage. The class weights
approximate it well enough for actionable triage; revisit when the script
accumulates a known false-rank case.

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
- codex memory registry (informational, not scored): <bytes> bytes (<path>)
                                           (only when a codex registry resolved)

## Top gaps (leverage-weighted)

1. [Pillar N] <one-sentence gap> — leverage <N>
   Fix: <one concrete next-step command or edit>
2. ...
3. ...

## Skipped surfaces

- <surface>: <reason> (e.g. "linear CLI not installed; cross-layer Linear checks skipped")

## Operator sub-gates

- <name>: pass | fail (exit <N>) | error — <first output line>
_(skipped — <named reason>)_             (when no registry ran)
```

When no injection-surface component resolves at all that section reads
`_(not measured — no injection-surface component resolved)_`. The codex-native
registry is **not** an injection-surface component: when one resolves, its size
follows as a separate non-scoring informational line, outside the total.

If `--json` is passed, the script emits a structured JSON object with
`{total, unscored_count, pillars[name].score, pillars[name].unscored,
pillars[name].notes, injection_surface, gaps[], codex_registry_bytes,
operator_subgates}` — used by the upstream acceptance suite's
`tests/self-audit.test.sh` to assert against specific scores. An UNSCORED pillar
reports `score: 0, unscored: true`; the history helper records that 0 truthfully.
`injection_surface` is `null` when no component resolved, else `{total_bytes,
threshold_kb, warned, components[{name, path, bytes}], skipped[]}`.
`codex_registry_bytes` and `operator_subgates` are appended last so pre-existing
fields keep their positions, and each is `null` when its surface did not run — no
registry or no `MEMORY.md` in it; unset key, missing or empty registry, or
`--no-subgates`. `operator_subgates` otherwise carries `{registry,
timeout_seconds, scored: false, gates[{name, status, exit_code, detail}],
dropped}`. The codex measurement runs outside the memory pillar's scored path, so
a codex-only install (memory pillar UNSCORED) still reports it.

## Limits

- **No auto-remediation.** Self-audit never edits framework files, never posts to
  Linear, never modifies the vault; the model invoking `/self-audit` has only
  `Read`, `Bash`, `Glob` in its tool envelope. Two write surfaces exist, both
  explicit: `--save <path>` writes a tracked scorecard artifact (absent that flag
  the audit is transcript-only), and the trend-history `append` step writes solely
  to the gitignored, operator-local history store — see
  [Trend tracking](#trend-tracking). Gap closure is the operator's call. One
  deliberate exception to "reads only": the operator sub-gate registry
  (`AUDIT_SUBGATES_FILE`) is *executed* — its commands are the operator's own, at
  hook trust level, and `--no-subgates` turns execution off while still rendering
  the section as a named skip.
- **Not a substitute for the PASS/FAIL gates.** `validate.sh`, `check-drift.sh`,
  and — where the upstream acceptance suite is present — `tests/run.sh` catch hard
  breakage. Self-audit catches thinning. Run both.
- **Graceful degradation.** A missing `linear` CLI, `OBSIDIAN_VAULT_PATH`, or
  `$CLAUDE_CONFIG_DIR` is skipped with a one-line note — the audit scores what it
  can see and tells you what it could not.
- **Operator-local state.** The scorecard reflects the operator's local installed
  state, so two operators of the same agentic-os-template repo see different
  scores.

## Notes

- The verification gate `self-audit` (in `verification/self-audit.md`) covers
  the meta-question "does the audit produce a sane, actionable scorecard?"
  — answered by running the script against fixtures.
- The capability is the framework's third `kind: native` spine entry, and spine
  symmetry — every native capability has a realization for each harness it declares
  in its `harnesses:` frontmatter (claude, codex, hermes, cursor) — is itself one of
  the things Pillar 5 scores.
