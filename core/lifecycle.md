# Lifecycle

Every durable on-disk artifact in this repository carries a YAML `lifecycle:`
field declaring its current state in the artifact's evolution. The convention
catches "is this plan live or stale?" at gate-time and lets the
`/self-audit` capability score artifact hygiene mechanically.

Adapted from the AIS-OS Bike Method `bike-method-phase:` frontmatter pattern
and the AI Memory Framework Stage enum.

## Vocabulary

```yaml
---
lifecycle: experimental    # newly authored, hand-validate, not yet reviewed
                           # | reviewed       — cross-model-reviewed or peer-checked
                           # | shipped        — merged/landed and active
                           # | superseded     — replaced by a later artifact (link to it in body)
                           # | sunset         — explicitly retired, retained for audit only
---
```

Five values. No aliases. `scripts/validate.sh check_lifecycle` enforces the
exact set.

## Advance rules

| From | To | Trigger |
|---|---|---|
| (absent) | `experimental` | First commit of a draft artifact |
| `experimental` | `reviewed` | Cross-model review or peer review applied + reconciled |
| `experimental` / `reviewed` | `shipped` | Merged to main + active (most plans transition `experimental → shipped` at PR merge) |
| `shipped` | `superseded` | A later artifact replaces it (cite the replacement in the body) |
| `shipped` | `sunset` | Explicitly retired without replacement (e.g. descoped scope) |

`superseded` and `sunset` are terminal — the body should explain *why* and
(for `superseded`) point at the replacement.

## Applicability — in scope for enforcement

`validate.sh check_lifecycle` enforces `lifecycle:` presence + valid value on:

- `docs/plans/*.md` — implementation plans
- `docs/specs/*.md` — design specs (if/when root-level specs are adopted)
- Any other `docs/<subdir>/plans/*.md` and `docs/<subdir>/specs/*.md` paths the
  framework adopts — none exist today; the generic predicates in
  `scripts/validate.sh` `check_lifecycle` cover any that appear
- `capabilities/*.md` — agnostic capability bodies
- `harnesses/{claude,codex,hermes,cursor}/capabilities/*.md` — per-harness realizations

`README.md` is excluded across all in-scope dirs — a `README.md` is a directory
introduction, not the lifecycle-tracked artifact it documents. (Mirrors the
`check_capabilities` exclusion pattern in `scripts/validate.sh`.)

## Out of scope for enforcement (and why)

| Surface | Why excluded |
|---|---|
| `core/*.md`, `README.md`, `verification/*.md`, harness templates (`harnesses/*/CLAUDE.template.md` etc.), `harnesses/*/adapter.md` | These *are* the framework. Their lifecycle is the repo's lifecycle. Adding `lifecycle:` to every framework prose doc inflates scope without surfacing useful state — "is this framework doc live?" is answered by "is it on `main`?" |
| Memory files (`$CLAUDE_CONFIG_DIR/projects/.../memory/*.md`) | Operator-local, not tracked in this repo. The memory-model schema already classifies them by `type:` (`reference` / `feedback` / `project` / `runtime` / `user`). |
| Cross-model-out runs (`$CROSS_MODEL_OUT_DIR/<run>/*`) | Gitignored. Not tracked. The scaffold below documents what value a future `log.md` ledger should carry; not retroactively backfilled. |
| Skills authoring (`skills/skill-template.md`, `skills/skill-authoring.md`) | Authoring guidance, not durable artifacts of the framework's evolution; outside the lifecycle-frontmatter scope. |
| Obsidian vault templates (`obsidian/*-template.md`), `linear/issue-template.md`, `templates/*.md` | Templates for operator instances, not durable artifacts of the framework's evolution. |

## Scaffold templates

### Plan file (`docs/plans/<date>-<slug>.md`) opening

```markdown
---
lifecycle: experimental
---

# <issue-id> — <one-line outcome> — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: ...
```

Author starts at `experimental`. Bump to `shipped` in the squash-merge commit
that lands the plan's implementation (or in a follow-on cleanup commit).

### Spec file (`docs/<subdir>/specs/<date>-<slug>.md`) opening

```markdown
---
lifecycle: experimental
---

# <date> — <design title>

**Status:** Draft / Reviewed / Approved
...
```

Author starts at `experimental`. Bump to `reviewed` after cross-model review;
to `shipped` if it lands as part of a PR; to `superseded` if a later spec
replaces it (cite the replacement in the body).

### Capability body (`capabilities/<name>.md`) opening

```markdown
---
name: <name>
summary: <one line>
triggers: [...]
verification: <gate>
harnesses: [claude, codex, hermes, cursor]
kind: native
enforcement: <class>
lifecycle: shipped
---
```

Spine capabilities ship in `main`; bump to `superseded` if replaced; `sunset`
if removed.

### Per-harness realization (`harnesses/<harness>/capabilities/<name>.md`) opening

```markdown
---
lifecycle: shipped
---

## <Harness> realization — <name>
...
```

The claude realization additionally carries an `allowed-tools:` key (a Claude
Code mechanic); codex carries only `lifecycle:`. `check_lifecycle` validates
the `lifecycle:` key only.

### Cross-model-out run ledger (`$CROSS_MODEL_OUT_DIR/<run>/log.md`) opening

NOT enforced (the run directory is gitignored), but the recommended
convention:

```markdown
---
lifecycle: reviewed
---

# <date> — <slug> cross-model review run
...
```

### Memory file types (per `core/memory-model.md` schema)

NOT enforced (memory files are operator-local). For memory-author convention:

- `reference_*.md` — `lifecycle: shipped` (durable facts)
- `feedback_*.md` — `lifecycle: shipped` (lessons that changed behavior)
- `project_*.md` — `lifecycle: shipped` while active; `superseded` when
  project closed-and-replaced; `sunset` when closed-and-not-replaced
- `runtime_*.md` — `lifecycle: shipped` while the runtime artifact exists
- `user_*.md` — `lifecycle: shipped`

## Why this matters

Repeated stale-artifact pain motivated this convention (each incident's full
writeup lives in the operator's durable memory, not in this public file):

- A spec sat untracked in `main`'s workdir with operator paths — nobody knew
  if it was live or stale
- `install.sh` ran from a worktree because nobody could tell the worktree was
  about to die
- Linear flips with no on-disk rationale or lifecycle marker

One YAML key fixes a class of bugs. Linear holds active-work status; Memory
headlines carry implicit lifecycle; on-disk artifacts now declare lifecycle
explicitly.
