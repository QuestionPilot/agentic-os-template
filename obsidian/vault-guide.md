# Vault Guide — Durable-Knowledge Layer Setup, Structure, and Runtime Contract

`obsidian/` is the canonical pointer surface for the agentic OS's Tier 3 durable-knowledge layer. This guide explains the model, walks an operator through first-time setup, names the folder structure and recommended system notes, and documents how AI agents interact with the vault at runtime.

## 1. Purpose and Audience

This document has two audiences:

- **An operator setting up the framework on a fresh machine** — read end-to-end. §3 walks first-time vault creation step-by-step; §§4-5 specify the target folder + system-note shape; §7 points at copy-paste templates.
- **An AI agent reading at runtime** — load only the relevant slice. §2 names what belongs in the vault vs other layers; §8 documents the runtime contract (what the agent reads, what it proposes to write).

The vault stores durable knowledge: lessons, decisions, project memory, source-derived summaries, curated outputs. It is not the active-work tracker (that is Linear), the operating framework (that is `agentic-os-template`), or the raw-source store (that is the vault's `20-Raw/` folder kept separate from distilled notes).

## 2. Role in the Agentic OS

The framework uses three memory tiers. Each layer owns one class of fact; writes go to the layer that owns the change.

> **Summary — canonical source is [`core/memory-model.md`](../core/memory-model.md).** This section recaps the three-tier model so a fresh reader can use vault-guide standalone. For the full taxonomy, the data-readiness layer, and the per-harness memory index contract, read [`core/memory-model.md`](../core/memory-model.md) directly.

| Tier | Layer | Owns |
| --- | --- | --- |
| 1 | `agentic-os-template` | Operating rules, verification expectations, capability specs, skill catalog, harness entrypoints. |
| 2 | Linear | Active tasks, projects, owners, status, acceptance criteria, blockers, follow-ups. |
| 3 | Durable vault (Obsidian or equivalent) | Durable lessons, decisions and rationale, project memory, wiki notes, source-derived summaries. |

The vault sits at Tier 3. It is knowledge — what is true, why it matters, where the source lives. It is not a duplicate Linear backlog and not a daily journal.

**Write rule (recap from `core/memory-model.md`):**

| Change | Destination |
| --- | --- |
| Operating rule, verification pattern, skill guidance | `agentic-os-template` |
| Active task, blocker, acceptance criteria, follow-up | Linear |
| Durable lesson, decision, project memory, source-derived note | The vault |
| Raw export, transcript, source file | The vault's `20-Raw/` until promoted |

If a write would fit multiple layers, split it. Put the active follow-up in Linear, the durable lesson in the vault, and the reusable operating rule in `agentic-os-template`.

## 3. First-Time Setup

Setting up the durable vault is a five-stage walkthrough. The framework's automated fresh-clone path (`scripts/bootstrap.sh` + `templates/local.env.example` + `playbooks/new-machine-bootstrap.md`) handles repo + harness wiring; this section handles the vault layer.

### 3.1 Create an Obsidian-compatible Markdown vault

The framework targets the Obsidian vault format — a plain directory of Markdown files, no proprietary database. Any tool that reads or writes that shape works (Obsidian, `nvim` with the right plugins, `vscode` with the right extensions, raw editing in any text editor).

**Recommended app:** the Obsidian desktop application. Free for personal use, cross-platform, handles the wiki-style `[[link]]` syntax this guide assumes. Install from `https://obsidian.md/`.

**Not required:** Obsidian the application. The format is portable; if you prefer another editor, the framework's expectations still hold as long as the directory and file shapes match §4 + §5.

### 3.2 Choose a storage location

Common options:

- **Local-only folder** (e.g. under your home directory) — simplest, no cross-device sync, no sync conflicts.
- **iCloud Drive** — macOS-native, fast on Apple devices, opaque on non-Apple.
- **Google Drive** (via Google Drive for desktop) — cross-platform, requires the local cache to be fully synced before AI agents read.
- **Dropbox** — cross-platform, similar caveat to Google Drive.

**Sync-conflict caveat:** cloud-storage providers handle simultaneous writes from multiple devices differently. Files like `START (conflict copy).md` or `decision-yyyy-mm-dd (1).md` appearing in the vault indicate an unresolved conflict; §9 covers the failure mode.

Pick one and commit. The vault path is single-valued in `local.env`; switching later means moving the directory + updating one env var.

### 3.3 Create the top-level folder structure

From the chosen storage location, create the recommended folder tree. This is a one-shot copy-paste — the framework ships no folder-creation script (per the no-scripts constraint).

```bash
# Adjust the parent directory before running. Quote if the path contains spaces.
cd "<your chosen storage location>"
mkdir -p "<vault name>"
cd "<vault name>"
mkdir -p \
  00-System \
  01-Projects \
  02-Areas \
  03-Decisions \
  04-Lessons \
  10-Wiki \
  20-Raw \
  30-Archive \
  40-Observability \
  50-Outputs \
  80-Templates \
  90-Indexes \
  95-Views
```

§4 names what belongs in each.

#### Optional: copy from `obsidian/vault-scaffolding/`

The framework bundles a reference scaffolding at `obsidian/vault-scaffolding/` — a complete vault structure with system notes, templates, indexes, and view definitions. Operators who want a richer starting point can copy it in lieu of the bare `mkdir` above:

```bash
: "${OBSIDIAN_VAULT_PATH:?Set OBSIDIAN_VAULT_PATH first (see §3.4 below)}"
mkdir -p "$OBSIDIAN_VAULT_PATH"
cp -R obsidian/vault-scaffolding/. "$OBSIDIAN_VAULT_PATH/"
```

The scaffolding ships generic — every reference uses placeholder names ("Memory Vault") that operators rename to their own. The tree pre-populates `00-System/`, `01-Projects/`, `02-Areas/`, `10-Wiki/`, `80-Templates/`, `90-Indexes/`, and `95-Views/` with the shapes §4 describes, plus a `bin/memory-vault-audit.js` health-check helper.

### 3.4 Wire `OBSIDIAN_VAULT_PATH` into `local.env`

The framework reads the vault location from `local.env`. From the cloned `agentic-os-template` repo root:

```bash
# Edit local.env (created by bootstrap.sh from templates/local.env.example).
# Set OBSIDIAN_VAULT_PATH to the absolute path of the vault directory you
# created in 3.3. Quote the value if the path contains spaces — local.env
# is sourced, and an unquoted space-bearing path fails to round-trip.
OBSIDIAN_VAULT_PATH="<absolute path to your vault directory>"
```

Re-run `bash scripts/install.sh --harness claude --harness codex` after editing `local.env` so the compiler picks up the new path. The compiler substitutes `$OBSIDIAN_VAULT_PATH` into the generated harness entrypoint.

### 3.5 Create the `00-System/` notes

Each note in `00-System/` carries one piece of operator-defined working state. §5 names the entry point (`START.md`, required) plus 9 recommended supplementary notes — their purposes and creation order. Start with `START.md` (the kickoff entry point) and the rest can be added incrementally as you accumulate working rules.

**Minimum viable vault for AI orient:** `START.md` alone is enough to satisfy the kickoff contract (§7 names the minimum-contract sections). The other system notes are recommended but optional at setup time.

## 4. Folder Structure

The 13 top-level folders, each with a one-line purpose:

| Folder | Purpose |
| --- | --- |
| `00-System/` | Operator-defined working rules (read by AI at kickoff). `START.md` lives here. |
| `01-Projects/` | One folder per active project; durable project memory + handshake notes. |
| `02-Areas/` | Standing concerns that are not project-shaped (e.g. "Finance", "Health"). |
| `03-Decisions/` | One note per durable decision; uses `decision-template.md` shape. |
| `04-Lessons/` | One note per durable lesson; uses `lesson-template.md` shape. |
| `10-Wiki/` | Cross-cutting reference notes (people, concepts, glossary). |
| `20-Raw/` | Raw sources awaiting promotion — transcripts, exports, screenshots. Not durable memory yet. |
| `30-Archive/` | Closed projects, retired decisions, superseded lessons. Also holds `Sessions/` — append-only per-session closeout logs (the durable session-narrative tier; see `capabilities/closeout.md` → Session-log drain). |
| `40-Observability/` | Dashboards, health checks, audit notes. |
| `50-Outputs/` | Curated artifacts (briefs, reports, data maps). §6 details what belongs. |
| `80-Templates/` | Operator-authored templates beyond the four shipped in `obsidian/`. |
| `90-Indexes/` | Manually-curated index notes (e.g. "All Open Decisions", "Lessons by Class"). |
| `95-Views/` | Saved Obsidian queries or dataview views, if you use them. |

Numbered prefixes (`00-`, `01-`, …) give a stable ordering in any file browser. The two-digit + dash convention is operator-friendly; the framework does not parse the digits.

## 5. `00-System/` Notes

Recommended system notes. Obsidian convention is title-case with spaces (e.g. `Memory Core.md`, not `memory-core.md`); this is different from the framework's kebab-case for `agentic-os-template` content. Adopt the title-case convention inside the vault so wiki-style `[[Memory Core]]` links work without escaping.

Creation-order recommendation: start with `START.md`. Add `Memory Core.md` and `Linear Handshake.md` next (they ground the kickoff orient). The rest are optional — add them as you accumulate working state worth naming.

| # | File | Purpose | Required? |
| --- | --- | --- | --- |
| 1 | `START.md` | Kickoff entry point — agents read this every session to ground orient. Minimum contract in §7. | **Required** |
| 2 | `Memory Core.md` | The single sentence that names your operating principle this quarter. | Recommended |
| 3 | `Source of Truth.md` | One-line pointers at the canonical source for each major class of fact (where Linear lives, where the vault lives, where code lives, who owns what). | Recommended |
| 4 | `Retrieval Routes.md` | Common query paths an agent should walk for recurring questions (e.g. "where is X documented", "what's the status of Y"). | Optional |
| 5 | `Fresh Start Policy.md` | How you re-enter work after a gap. What to re-read, what to skip. | Optional |
| 6 | `Data Readiness.md` | Per the pantry-prep-plate model in `playbooks/data-readiness-map.md`. Names which sources have prep artifacts and where they live. | Optional |
| 7 | `Goal Run Standard.md` | The default bounds for autonomous or recurring work. Cross-references `playbooks/goal-run.md`. | Optional |
| 8 | `Dream Review.md` | A space for unstructured big-picture reflection. Operator territory; AI does not write here. | Optional |
| 9 | `Linear Handshake.md` | A single entry point that lists active Linear projects + their handshake-note bidirectional links. See `handshake-template.md`. | Recommended |
| 10 | `Health Check.md` | A bash one-liner or checklist an operator runs to confirm vault sync + structural integrity. Operator-defined. | Optional |

`START.md` is the only hard requirement. Without it, the framework's kickoff orient degrades gracefully (with a one-time warning); other system notes' absence is silent.

## 6. `50-Outputs/` Convention

Curated artifacts only. Use subfolders by output kind:

```text
50-Outputs/Data Maps/
50-Outputs/Silver Platters/
50-Outputs/Briefs/
50-Outputs/Reports/
```

**Belongs here:**

- Briefs an operator hands to a stakeholder.
- Silver-platter summaries from `silver-platter` runs.
- Data-readiness maps from `playbooks/data-readiness-map.md` runs.
- Final-form reports an external reader will consume.

**Does NOT belong here:**

- Raw exports (`20-Raw/`).
- Auth files, API tokens, machine-specific config (never in the vault — `local.env` lives in `agentic-os-template`).
- Disposable traces, screenshots, run logs (not durable memory).
- Working drafts (use a project folder under `01-Projects/`).

The outputs folder is for things you would willingly hand to someone else.

## 7. Templates

Four templates ship in `obsidian/`. Copy them into your vault's `80-Templates/` folder (or reference them directly) when authoring a new note of that shape.

| Template | Use when |
| --- | --- |
| `start-template.md` | Initial creation of `00-System/START.md`. Carries the minimum-contract sections named below. |
| `handshake-template.md` | Each new note under `01-Projects/<project>/` that mirrors a Linear project or issue. |
| `decision-template.md` | Each durable decision in `03-Decisions/`. |
| `lesson-template.md` | Each durable lesson in `04-Lessons/`. The classification field uses the 11-class taxonomy from `core/self-improvement.md`. |

### START.md minimum contract

`START.md` is read at kickoff. The agent expects the following H2 sections (named exactly):

- `## Read Order` — numbered list of `00-System/` notes the agent should consult next.
- `## Working Rule` — one or two sentences capturing the current operating principle (mirrors `Memory Core.md` content).
- `## Linear Boundary` — what belongs in Linear vs the vault. References the handshake template.
- `## Closeout` — reminder to classify lessons via the canonical taxonomy before writing durable memory.
- `## Health Check` — an operator-defined audit command or checklist.

**Graceful degradation:** if a required section is absent, the kickoff orient still proceeds — the agent emits a one-time warning naming the missing section, then continues. A `START.md` that is completely missing degrades to a no-vault-orient kickoff; the framework does not block the session.

## 8. How the AI Uses the Vault at Runtime

> **Summary — canonical source is [`capabilities/session-agent.md`](../capabilities/session-agent.md) (session kickoff + routing) and [`capabilities/closeout.md`](../capabilities/closeout.md) (closeout pass).** This section names the durable contract — what an AI agent reads, what it writes, what it proposes — so a vault author can reason about the agent's behavior without opening capability bodies. For current mechanics (which sub-steps fire when, which tools are called, which hooks enforce), the linked capabilities are the source of truth.

**Session kickoff — read.** When the harness is configured with `OBSIDIAN_VAULT_PATH`, the agent's session kickoff reads `$OBSIDIAN_VAULT_PATH/START.md` to ground orient. The agent loads only that file and any system notes `START.md` explicitly points at — never the whole vault. If the vault is unreachable (path missing, network volume offline, sync incomplete), kickoff orient continues without it and warns once.

**Scope filter — multi-harness vaults.** Notes carry a `harness:` audience key (`all` or one harness name; absent = `all`) and a `learned_by:` provenance key — see the schema contract in [`core/memory-model.md`](../core/memory-model.md) § Harness-Neutral Note Schema. At orient and on-demand retrieval, an agent loads only notes scoped `all` or to itself. Enforcement is mechanical: per-harness index views under `90-Indexes/` are *generated* from note frontmatter by `bin/generate-harness-index.js` (shipped in the scaffolding), and the vault audit fails when a view drifts from what regeneration produces. The filter applies to vault notes only — harness-native memory stores are local caches outside this contract.

**Routing — refer.** When the agent routes a task and a relevant project handshake note exists under `01-Projects/`, the agent may read that one note for durable rationale Linear does not capture. Cross-cutting reference notes under `10-Wiki/` are loaded on demand by name.

**Closeout — propose (curated notes).** At session end, the closeout pass classifies each meaningful lesson into one of 11 classes (`rule`, `check`, `script`, `linear`, `obsidian`, `playbook`, `skill`, `data-readiness`, `goal-run`, `no-action`, `state-delta`). For the `obsidian` class, the agent **proposes** a note path and body to the operator — it does not write to the vault directly. The operator's review-and-paste step preserves the vault as operator-curated durable memory.

**Closeout — write-through (the session log).** The one exception to propose-don't-write is the durable **per-session log**. On every meaningful close, closeout writes an append-only, uniquely-named file to `30-Archive/Sessions/` (see [`capabilities/closeout.md`](../capabilities/closeout.md) → Session-log drain). Because it is a brand-new file that never edits a curated note, it is safe to write directly — and it is what lets a fresh machine reconstruct the session without the transcript. The log is treated as **untrusted, mixed-origin evidence**: observations carry provenance labels, quoted tool/external text is quarantined under a `## Raw observations` section and is never auto-promoted into a curated note, and the draft is run through the injection scan (`scripts/check-memory-drift.sh --injection-scan`) before it is written. Curated durable memory (decisions, lessons, project notes) still follows propose-don't-write above.

**Decisions and lessons — propose.** Same principle: when a session surfaces a decision worth recording in `03-Decisions/` or a lesson worth recording in `04-Lessons/`, the agent proposes the note shape (using the matching template) and the operator decides whether and how to commit it.

**Linear handshake — bidirectional, manual.** A handshake note under `01-Projects/<project>/` links out to its Linear project/issue URL; the Linear project/issue links back to the vault note (operator-maintained, no auto-sync). Linear owns active status; the vault note owns durable rationale, decisions, and lesson references.

## 9. Failure Modes

Common ways the vault layer degrades, and what to do.

- **Raw sources in durable memory.** A transcript, screenshot, or export landed in `01-Projects/` or `03-Decisions/` instead of `20-Raw/`. Move it to `20-Raw/` and create a distilled note in the right folder if the content warrants durable memory.
- **Vault used as a task tracker.** Open tasks accumulate as bullets in vault notes instead of Linear issues. Migrate the tasks to Linear; keep durable rationale in the vault, link the two.
- **`START.md` missing.** The kickoff orient degrades gracefully but loses the operator's working-state grounding. Author `START.md` from `start-template.md`; the next session picks it up.
- **Sync-conflict files.** Files like `START (conflict copy 2).md` or `decision-yyyy-mm-dd (1).md` indicate a cloud-storage provider could not merge simultaneous writes. Resolve them manually (pick the canonical version, delete the conflict copy) before the next session. Different providers name the conflict copies differently; the pattern is always "original name + provider-specific suffix".
- **Stale memory body overrides current fact.** A note authored months ago claims something that is no longer true. The retrieve-smallest-useful-slice rule applies: prefer fresh signal (current Linear state, current repo state) over old memory; treat stale memory as a hypothesis to verify, not a fact.
- **Vault path mismatch across sessions.** The operator changed `OBSIDIAN_VAULT_PATH` without re-running `install.sh`, so the harness entrypoint points at the old path. Re-run `bash scripts/install.sh --harness claude --harness codex` to re-substitute the new path.

For deeper failure-mode coverage of the memory model overall, see `core/memory-model.md` § Failure Modes.
