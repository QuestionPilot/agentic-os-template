# Global Claude Code Entrypoint

Every session starts here. Read in order, load only what is relevant to the task.

## Layer 1 — Operating Framework (always read first)

The agentic OS lives at:
`@@AI_CONFIG_DIR@@/`

Start with `README.md`, then load only the relevant files from `core/`, `verification/`, `playbooks/`, and `skills/`. Do not load the whole framework by default.

Key files for most sessions:
- `core/operating-system.md` — how to operate
- `core/memory-model.md` — what goes where across the three layers, including the per-harness memory index contract
- `core/tool-use.md` — CLI over MCP, smallest capable route
- `core/routing.md` — when to escalate or delegate

## Skills

**Catalog:** `@@CLAUDE_CONFIG_DIR@@/SKILLS.md` — full live inventory by family + candidates. Open on demand.

**`session-agent` is the spine.** The framework SessionStart hook directs you to invoke `session-agent` as the first action of every session — Mode 1 (kickoff orient: memory + Linear + vault + reconciliation) then route the user's first prompt. On every subsequent non-trivial prompt, re-invoke `session-agent` (Mode 2: route only — orient is already live in context). One capability, two modes; the body teaches both. A PreToolUse hook on Write/Edit/NotebookEdit enforces the gate before file edits as a safety net.

### Quick-reference

The framework itself ships only the spine capabilities (table below). Everything else routes to Claude Code built-ins or to operator-installed skills — the build-generated `@@CLAUDE_CONFIG_DIR@@/SKILLS.md` Live Inventory is the source of truth for what is actually installed here.

| Surface | Primary skill |
| --- | --- |
| Pre-PR review of local changes | `review` (built-in) |
| Security-sensitive change | `security-review` (built-in) |
| Anthropic SDK / Claude API code | `claude-api` (built-in) |
| Build / update a Claude Code skill | `@@AI_CONFIG_DIR@@/skills/skill-authoring.md`; operator skill-creation tooling if installed |
| Active work tracking | See `@@AI_CONFIG_DIR@@/linear/linear-setup.md` for the lineark CLI / Linear MCP setup options |
| Data analysis / document artifacts (deck, doc, sheet, PDF) | operator-installed skills, if present — see the `SKILLS.md` Live Inventory |
| Engineering workflows (debug, plans, TDD, parallel work, branch closeout) | see `SKILLS.md` Live Inventory |
| Ambiguous or multi-surface | `/session-agent` (orchestration sub-routine) |

### OS capability skills

These skills are the agentic OS's own capabilities, generated from `@@AI_CONFIG_DIR@@/capabilities/`. This table is build-generated — do not hand-edit it.

@@CAPABILITY_CATALOG@@

For portable router patterns (orchestration sub-routine, capability families), see `@@AI_CONFIG_DIR@@/skills/`.

## Layer 2 — Active Work (Linear)

Linear holds current tasks, status, blockers, acceptance criteria, and next actions. The framework supports two Linear access surfaces — `lineark` CLI and Linear MCP — both first-class. See `@@AI_CONFIG_DIR@@/linear/linear-setup.md` for setup, operating instructions, and the runtime contract. The `session-agent` capability's Mode 1 O3 owns the kickoff query order — see its body for the projects-first ordered cut.

## Layer 3 — Durable Knowledge (Obsidian)

The vault lives at:
`@@OBSIDIAN_VAULT_PATH@@/`

Start with `START.md` inside the vault. Load only the relevant notes — do not load the whole vault. The vault has its own `.claude/skills/` for Obsidian-specific skills.

## Pre-Push

Before opening a PR or pushing a branch with framework changes, run `make verify` from the repo root. It runs the verification gates in order, failing fast on first non-zero exit: the acceptance suite (`tests/run.sh`) when present, static validation (`scripts/validate.sh`), and the manifest-based drift check across every rendered harness home (`scripts/check-drift.sh --auto` — the claude, codex, and hermes renders; a home that is unset or not yet rendered is skipped with a notice). These are the same gates a future-Claude or future-operator runs when picking up the change.

Commit identity: a clone with no repo-local git identity derives the operator's personal name and machine hostname into public history on a plain commit. Pin every framework commit to your published identity (`git -c user.name=… -c user.email=…`, or a repo-local `git config`). Declare that identity as `COMMIT_IDENTITY_ALLOWLIST` in the gitignored `local.env` (comma-separated exact `Name <email>` entries) and `scripts/check-clean.sh` fails any branch commit whose author or committer is off-list — the content scans cannot see commit metadata, so this is the gate that covers it.

## Ground Rules

Each rule states its rationale in prose, so it is self-justifying without an external lookup. The originating issue or decision lives out-of-line in the durable vault note's `linear:` frontmatter (see `core/memory-model.md`), not as an inline tracker identifier — framework files carry no private tracker IDs.

- CLI over MCP when both can do the job — CLI burns fewer tokens
- Keep active work in Linear, durable knowledge in Obsidian, operating rules in agentic-os-template
- Do not write local paths, auth state, secrets, or project history into agentic-os-template
- The framework SessionStart hook directs `session-agent` invocation as the first action of every session (Mode 1: orient + route). A PreToolUse hook on Write/Edit/NotebookEdit enforces this as a safety net before any file edit.
- Multi-step or multi-session work goes into Linear before execution (routing protocol step 4); session todos (TodoWrite) track only the steps *within* an issue being actively executed.
- Before closing any meaningful session, classify lessons through `core/self-improvement.md`. Invoke the `closeout` skill manually to walk this — it is manual-fire; no hook enforces it (the Stop-hook gate was removed because it re-fired on closeout's own writes).
- When the session creates/closes/changes a Linear project, or creates a new durable on-disk artifact directory, the closeout block MUST include a `## State Deltas` section AND the memory write must happen during closeout — not deferred. The `state-delta` lesson class in `core/self-improvement.md` is the canonical destination.
