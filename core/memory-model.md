# Memory Model

The memory system is the core of the Agentic OS. Its job is to let different AI systems resume work, improve behavior, and coordinate execution without turning one file, repo, chat thread, or tool into a junk drawer.

The theory is simple: separate rules, active work, durable knowledge, and raw evidence. Agents should know where to look, where to write, and what not to duplicate.

## Goals

- Give every agent a small, reliable startup path.
- Keep active work visible to humans and other agents.
- Preserve durable lessons, decisions, and project memory without storing chatter.
- Make repeated work faster through prep artifacts, audits, and verification recipes.
- Prevent stale local context from overriding current project files, Linear state, or live evidence.

## Structure

Use three tiers plus a data-readiness layer. Keep their responsibilities separate.

## Tier 1: AI Config

`agentic-os-template` is the operating framework. It stores:

- global rules
- self-improvement standards
- verification expectations
- lightweight playbooks
- skill catalog entries
- harness entrypoints

It should not store active task chatter, project backlog, durable project memory, secrets, local paths, or raw transcripts.

## Tier 2: Linear

[Linear](https://linear.app) is the active-work layer. It stores the execution ledger for what is happening now:

- active tasks
- projects, milestones, and dependencies
- owner and status
- acceptance criteria
- blockers
- follow-ups
- links to PRs, deploys, or artifacts

This is current state, not long-term knowledge. If a task is open, blocked, sequenced, assigned, or acceptance-gated, it belongs in Linear or in a Linear-ready draft when write access is unavailable.

Use the native Linear skill, connector, app, API, CLI, or browser UI when available. If no write-capable access exists, produce Linear-ready markdown using `linear/`.

## Tier 3: Long-Term Knowledge

Obsidian, or an approved equivalent durable vault, stores long-term knowledge:

- durable lessons
- decisions and rationale
- project memory
- wiki and research notes
- source summaries

This is knowledge, not the current task queue. The durable vault should explain what is true, why it matters, and where the source lives. It should not become a duplicate Linear backlog.

### Issue ↔ Knowledge Handshake

A durable note records its originating tracker issue out-of-line, in the note's
frontmatter — not as an inline identifier in framework rule prose. The canonical
form is a `linear:` (or generic tracker-URL) frontmatter key linking the note to
its issue:

```yaml
---
title: <note title>
linear: https://<tracker>/issue/ABC-123
---
```

This is the canonical issue→knowledge home: it keeps private tracker identifiers
out of public framework files while preserving auditable lineage for anyone with
vault access. Framework rules state their rationale in prose (see the Ground
Rules in the harness entrypoint); the originating issue link lives here. Any
tracker and any vault that supports frontmatter works — `linear:` is the default
example, not a requirement.

### Harness-Neutral Note Schema — Scope as a Retrieval Filter

When more than one harness reads the same vault, two frontmatter keys carry
audience and provenance:

```yaml
---
title: <note title>
harness: all            # audience scope: all | <one harness name>
learned_by: <harness>   # provenance: which harness's session produced the note
linear: https://<tracker>/issue/ABC-123
---
```

- **`harness:` is an audience scope, enforced as a retrieval filter.** At
  orient, a harness loads only notes carrying `harness: all` or its own name.
  A missing `harness:` key means `all` (back-compatible default). The filter
  exists because a label alone does not stop a model that has already read a
  note from following it — scope must be enforced mechanically at the
  retrieval layer, before the note enters context, not by the label.
- **The mechanical enforcement point is the generated index.** Each harness's
  index view of the vault is *generated* from note frontmatter —
  deterministically (stable sort, stable format), never hand-edited. A note
  scoped to one harness simply does not appear in another harness's view, so
  an orient that starts from the view cannot load it. Generating the index
  also removes the shared-index write hot-spot: regeneration replaces
  append-and-consolidate. The generator and the audit check that re-derives
  the views and fails on drift ship in the vault scaffolding's `bin/`
  (`obsidian/vault-scaffolding/bin/`).
- **`learned_by:` is cheap provenance, never a filter.** It records which
  harness's session produced the note so a future reader can weigh
  harness-specific advice; it has no retrieval effect.
- **The scope filter applies to vault notes only.** Harness-native memory
  stores and per-machine memory are local caches outside the shared-memory
  surface (see the Cache Contract below) — the schema, the filter, and the
  vault audit never reach them.

The per-harness index views are vault-level retrieval surfaces; the
harness-native autoloaded index keeps its own caps and enforcement (see Index
Size + Per-Entry Caps below) — the two indexes are different layers and do not
share tooling.

## Data Readiness Layer

Data readiness sits between raw sources and agent reasoning.

Use the pantry, prep, plate model:

- Pantry: raw systems, exports, files, APIs, transcripts, and source folders.
- Prep: deterministic summaries, source indexes, converted markdown, and silver platter briefs.
- Plate: human-facing briefs, decisions, recommendations, reports, and active-work follow-ups.

Agents should read prep artifacts before raw sources when the question is repeated, the raw source is large, or the source needs boundaries.

Raw sources are evidence, not memory. Prep artifacts are source-derived knowledge. Decisions and lessons become durable memory only after promotion.

## Per-Harness Memory Index

Some harnesses maintain a per-session memory index that gets autoloaded into
context at session start (e.g. Claude Code's `MEMORY.md`, sitting alongside
per-fact memory files). The headline-vs-body contract below was introduced as
the per-session memory-index discipline and extended with the
bodies-age clause.

When such an index exists:

- **The index is a search index, not the source of truth.** Its entries are
  one-line headlines pointing at memory files. Headlines are a search aid for
  deciding which files to open, not a complete description of current state.
- **The file body is the source of truth.** For any memory file referenced in
  the index that names an active or recently-active workstream — typically the
  project/state pointers — the model must open the file body before acting on
  the headline. A headline written one session ago may have gone stale; the
  body reveals whether the headline is current.
- **Bodies age too — verify cross-issue claims against the active-work layer.**
  Bodies are MORE authoritative than headlines for the file's *own* state, but
  for claims about *other* issues' Linear states (status, gates, approval)
  embedded inside an active-project memory body, verify against Linear at
  kickoff regardless. Memory bodies were written one session ago; the other
  issue's state may have shifted since, and cross-issue claims aren't
  self-correcting at the body-read step. This applies whether the claim
  appears in the headline (autoloaded) or the body (read on demand) — both
  age.
- **Headline drift is a closeout-write-side problem.** When a session creates
  or closes a project, changes its status, or creates a new durable on-disk
  artifact directory, that delta belongs in the body of the relevant memory
  file AND in the index — written DURING that session's closeout, never
  deferred. The `state-delta` lesson class in `core/self-improvement.md` is
  exactly this guarantee.
- **Reconcile against fresh signal.** If a harness surfaces fresh signal at
  session start (e.g. recent commit log, current Linear state), the model
  reconciles that signal against memory-index claims and digs when they
  contradict. Memory captures what was true when written; signal captures what
  is true now.

### Cache Contract — Harness-Native Stores Are Local Caches

Harness-native memory stores (a harness's autoloaded memory directory and
index, its native per-agent memory files, any per-machine memory) are **local
caches**, not durable storage. Three rules keep the tiers from bleeding into
each other:

- **Durability flows only through the vault.** Cross-machine and cross-harness
  durability is achieved by promoting lessons, decisions, and project memory
  through closeout into the durable vault (Tier 3) — never by treating a
  harness's local store as the long-term record.
- **Never sync caches machine-to-machine.** A cache is rebuilt from the vault,
  the active-work tracker, and the repo; syncing one machine's cache to another
  creates a second source of truth and invites split-brain.
- **Never impose vault schema or protocols on a native store.** Each harness's
  native memory keeps its own format, size caps, and conventions; the vault's
  note schema, frontmatter contracts, and audit apply to vault notes only.
- **A per-machine projection of a vault master is a thin offline fallback, not a
  mirror.** When the durable vault holds a master note the orient loads every
  session (e.g. an operator-identity / "soul" note read explicitly at
  session-agent O4) *and* a harness keeps a per-machine cache of it, that cache
  exists only to keep a cold or vault-unreachable session (Drive/VPN down) from
  flying blind — not every harness has one, and the orient must degrade without it.
  Keep any such cache lean — a pointer to the master plus the few load-bearing
  facts — never a full duplicate that drifts against it. The vault master is
  authoritative whenever both are in context.

### Index Size + Per-Entry Caps (enforced)

The index autoloads into context at session start, so it competes for the same
budget every other memory tier draws on. Two caps keep it a fast, reliable
startup path instead of a junk drawer — both are enforced by tooling, not just
convention.

- **`MEMORY_INDEX_SIZE_CAP_BYTES` = 24400.** The harness truncates memory recall
  around this size; an index that crosses it silently drops its tail entries and
  loses recall. The constant matches the observed truncation limit surfaced in
  the autoloaded-index system reminder (~24.4 KB).
- **`MEMORY_INDEX_LINE_CAP_CHARS` = 300.** Index entries are one-line headlines
  pointing at memory files; a line well over this is detail that belongs in the
  named topic body, not the index. The cap is 300 rather than a tighter number
  because a *well-formed* one-line entry carries ~100–130 chars of fixed
  markdown-link overhead (`[Title](file.md)`) before its hook text even starts,
  so a legitimate one-liner can reach ~250–260 chars without being bloated. 300
  still catches genuine paragraph bloat (multi-sentence entries that should be
  graduated to a topic file) without false-flagging well-formed one-liners. The
  24400-byte `MEMORY_INDEX_SIZE_CAP_BYTES` above is the hard recall guard; this
  per-line cap is the scannability guard. Over-long entries inflate the index
  toward the size cap and degrade scannability.

When the index crosses either cap, the fix is the same: shorten the longest
one-line entries and move the detail into the named topic file (or graduate a
durable lesson to the vault per the Write Rule below). `consolidate-memory` is
the capability that does this.

Enforcement lives in two places, both additive and read-only-diagnostic:
`scripts/check-memory-drift.{sh,ps1}` checks `<memory-dir>/MEMORY.md` against
both caps and exits non-zero on a violation, and the `self-audit`
memory-hygiene pillar deducts + surfaces an over-cap / over-line-length gap.
A memory write that crosses either cap therefore trips an automated failure.

The harness entrypoint specifies the concrete index location and any read
contract specific to that harness.

### Note Discoverability + Frontmatter Contract

Two contracts keep per-fact memory notes loadable and discoverable.

- **Discoverability — every note is indexed.** A memory note that no index entry
  points to is invisible to a fresh session: recall starts from the autoloaded
  index, so an un-indexed note compounds zero value. After writing or renaming a
  note, confirm the index carries a one-line pointer to it; after deleting a
  note, remove its index line. This is the per-harness memory index contract.
  The check is a closeout write-side step (the writer confirms the index at write
  time).
- **Kind is carried by frontmatter `metadata.type`, not the filename.** A note's
  memory kind — `project` / `feedback` / `reference` / `decision` / `user` — lives
  in its frontmatter `metadata.type` (a top-level `type:` is also accepted), NOT in
  a filename prefix. The framework scanners that act per-kind
  (`scripts/self-audit.{sh,ps1}` Pillar 1 + Pillar 5,
  `scripts/check-memory-drift.{sh,ps1}` headline-drift,
  `scripts/check-distillation-completeness.{sh,ps1}`) detect a note's kind by
  reading `metadata.type`, so the auto-memory store's kebab-case filenames
  (`project-web-monorepo.md`, `home-repo.md`) are first-class — no
  `project_*.md` underscore prefix is required. What IS load-bearing is that every
  note sets `metadata.type`: a note that omits it is invisible to the per-kind
  scanners — the same silent-drop the filename glob used to have, re-keyed to
  frontmatter. Filenames elsewhere in this doc written `project_*.md` are a
  conventional illustration of a project note, not a detection contract.
- **Frontmatter parser-safety.** Each note opens with a YAML frontmatter block
  (`name:`, `description:`, a nested `metadata:` block) closed by a `---` line. A
  strict YAML parser silently misreads two scalar shapes, so neither is allowed
  unquoted in a TOP-LEVEL scalar value: ` #` (space-then-hash — YAML drops the
  rest of the value as a comment) and `: ` (colon-space — YAML may read it as a
  nested mapping). Quote any top-level value containing either; single-quoting is
  simplest (only an internal `'` needs doubling). This is a narrow parser-safety
  rule, NOT schema validation — it does not check required fields or enum values.
  Enforced by the frontmatter class in `scripts/check-memory-drift.{sh,ps1}`,
  which skips already-quoted, nested, and block-scalar values (see that script's
  header for the accepted false-negatives).
- **Injection-defense on agent-written notes.** A memory note is autoloaded or
  recalled into a future agent's context, so a prompt-injection payload copied
  verbatim from untrusted tool/web output into a note becomes a hijack vector for
  whoever reads it next. The injection class in
  `scripts/check-memory-drift.{sh,ps1}` flags a small set of high-signal payloads
  — chat-role spoofs (`<system>`, `system:`), ignore/forget/override-previous-
  instructions, persona flips, future-agent targeting, memory-write directives,
  and prompt exfil — but ONLY when one sits as a BARE, LINE-LEADING directive,
  the shape verbatim-copied hostile text takes. To document any of these patterns
  in a note (security references legitimately do), put them inside a fenced code
  block, blockquote, inline code, or indented code — the scan skips those, and
  fencing IS the documented escape. It is a conservative hazard heuristic, not an
  exhaustive filter: multi-line, obfuscated, or non-line-leading payloads are out
  of scope, and credential-string exfil is the outbound-content scan's job
  (`core/tool-use.md`), not this class's.

### Timestamped Artifact Ordering

Order timestamped session/checkpoint artifacts — cross-model-review run
directories (`YYYY-MM-DD-slug`), dated plan/spec files, any "latest checkpoint"
selection — by the timestamp EMBEDDED IN THE FILENAME, never by filesystem mtime.
A durable store synced through a cloud provider (a cloud-synced vault, a
network-drive mount) rewrites mtime on sync, so an `ls -t` / mtime-latest pick
silently selects the wrong file. Filename order is stable across machines and
syncs.

This is an ordering rule, not a blanket ban on mtime. A recency *window* over a
purely-local directory (for example `find -mtime -7` to list recently-touched
local notes) is a different operation and stays correct: it asks "changed
recently?" on a non-synced path rather than "which is newest?" on a synced store.

## Memory Maintenance Lifecycle

Memory notes drift as the work moves on: paths rename, a decision is superseded,
two notes converge on one fact. Left unmaintained, the store fills with half-true
guidance that costs more than it saves. When writing a new note — or sweeping the
store — classify each related existing note into exactly one outcome (the
compound-engineering refresh model, adapted to per-fact memory notes).

- **Keep** — accurate and still useful; no edit.
- **Update** — references drifted but the core fact still holds; fix in place.
- **Consolidate** — two notes overlap; merge the unique content into the
  canonical one, delete the subsumed note, and drop its index line.
- **Replace** — the guidance is now misleading; write a successor, delete the old.
- **Delete** — the subject is gone and no other note substantively links to it;
  remove the file (git history / the vault is the archive) and drop its index
  line. Decorative `[[links]]` are fine to clean up; a substantive inbound link
  downgrades the action to Replace or Update.

`closeout` applies this per-write — when a lesson routes to a memory note, refresh
the related ones rather than blindly appending. `consolidate-memory` applies it as
a periodic sweep across the whole store. Both share this vocabulary so a note one
refreshes stays legible to the other.

This curated, human-reviewed lifecycle is deliberately chosen over automated
confidence-decay or trust-scoring machinery: aging is handled by the Keep /
Update / Consolidate / Replace / Delete pass at write time plus periodic sweeps,
not by per-entry decay counters. The one trust rule that applies is a precedence
rule, not a score — curated memory is advisory: live repo state, the active-work
tracker, CI, and source artifacts override it, and a stale or cross-project note
never authorizes an action on its own (see Failure Modes). This keeps the store
boring and legible rather than adding policy weight a human-curated store does not
need.

## Retrieval Rule

Agents should retrieve the smallest useful slice:

1. harness entrypoint
2. relevant core rule
3. relevant Linear issue if present
4. relevant prep artifact or source-derived summary
5. relevant Obsidian note only when needed

Do not load the whole knowledge base by default. Do not turn this repository into a duplicate Linear backlog, daily log, or Obsidian vault.

## Write Rule

Write to the layer that owns the fact:

| Change | Destination |
| --- | --- |
| Operating rule, verification pattern, skill guidance | `agentic-os-template` |
| Active task, blocker, acceptance criteria, follow-up | Linear |
| Durable lesson, decision, project memory, source-derived note | Obsidian or equivalent |
| Source code, product docs, deploy config | Project repo |
| Raw export, transcript, source file | Raw source area until promoted |

If a write would fit multiple layers, split it. For example: put the active follow-up in Linear, the durable lesson in Obsidian, and the reusable operating rule in `agentic-os-template`.

## Failure Modes

These anti-patterns are founding. Avoid them.

- Treating `agentic-os-template` as project memory.
- Treating Linear as a knowledge base.
- Treating the durable vault as an active task tracker.
- Copying raw transcripts into durable memory.
- Letting stale notes override current repo, Linear, or live-system evidence.
- Installing many skills without a router and then loading too much context by default.
