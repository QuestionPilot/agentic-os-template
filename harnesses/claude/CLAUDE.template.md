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

**Catalog:** `@@CLAUDE_CONFIG_DIR@@/SKILLS.md` — the routing table, the build-generated table of the OS's own capabilities (`session-agent`, `closeout`, `self-audit`), and the live inventory of built-in + operator-installed skills. Open on demand; this file does not repeat it.

**`session-agent` is the spine.** The framework SessionStart hook directs you to invoke `session-agent` as the first action of every session — Mode 1 (kickoff orient: memory + Linear + vault + reconciliation) then route the user's first prompt. On every subsequent non-trivial prompt, re-invoke `session-agent` (Mode 2: route only — orient is already live in context). One capability, two modes; the body teaches both. A PreToolUse hook on Write/Edit/NotebookEdit enforces the gate before file edits as a safety net.

### Quick-reference

Only the rows that decide a route on their own; everything else is in the `SKILLS.md` routing table.

| Surface | Primary route |
| --- | --- |
| Failing test, error, regression, defect | `@@AI_CONFIG_DIR@@/playbooks/root-cause-debugging.md` first — demonstrate the root cause before editing (an operator debugging skill, if installed, implements it) |
| Pre-PR review of local changes | `code-review` (built-in) |
| Security-sensitive change | `security-review` (built-in) |
| Anthropic SDK / Claude API code | `claude-api` (built-in) |
| Build / update a Claude Code skill | `@@AI_CONFIG_DIR@@/skills/skill-authoring.md` |
| Ambiguous or multi-surface | `/session-agent` (orchestration sub-routine) |

### OS capability skills

These skills are the agentic OS's own capabilities, generated from `@@AI_CONFIG_DIR@@/capabilities/`. This table is build-generated — do not hand-edit it.

@@CAPABILITY_CATALOG@@

For portable router patterns (orchestration sub-routine, capability families), see `@@AI_CONFIG_DIR@@/skills/`.

## Layer 2 — Active Work (Linear)

Linear holds current tasks, status, blockers, acceptance criteria, and next actions. The framework supports two Linear access surfaces — `linear` CLI and Linear MCP — both first-class. See `@@AI_CONFIG_DIR@@/linear/linear-setup.md` for setup, operating instructions, and the runtime contract. The `session-agent` capability's Mode 1 O3 owns the kickoff query order — see its body for the projects-first ordered cut.

## Layer 3 — Durable Knowledge (Obsidian)

The vault lives at:
`@@OBSIDIAN_VAULT_PATH@@/`

Start with `START.md` inside the vault. Load only the relevant notes — do not load the whole vault. The vault has its own `.claude/skills/` for Obsidian-specific skills.

## Pre-Push

Before opening a PR or pushing a branch with framework changes, run `make verify` from the repo root — fail-fast, in order: the acceptance suite (`tests/run.sh`), static validation (`scripts/validate.sh`), and the manifest drift check across every rendered harness home (`scripts/check-drift.sh --auto`). `make verify` never writes: when the only drift is app-written user-preference keys in a rendered `settings.json`, it fails and prints the one-line cure (`scripts/check-drift.sh --cure-soft-drift --manifest <home>`) — run that, then re-verify. Commit identity: pin every framework commit to your published identity and declare it as `COMMIT_IDENTITY_ALLOWLIST` in the gitignored `local.env` so `scripts/check-clean.sh` can gate author and committer — the how and why are in `@@AI_CONFIG_DIR@@/playbooks/personal-fork.md`.

## Ground Rules

Each rule states its rationale in prose, so it is self-justifying without an external lookup. The originating issue or decision lives out-of-line in the durable vault note's `linear:` frontmatter (see `core/memory-model.md`), not as an inline tracker identifier — framework files carry no private tracker IDs.

- CLI over MCP when both can do the job — CLI burns fewer tokens
- Keep active work in Linear, durable knowledge in Obsidian, operating rules in agentic-os-template
- Do not write local paths, auth state, secrets, or project history into agentic-os-template
- The framework SessionStart hook directs `session-agent` invocation as the first action of every session (Mode 1: orient + route). A PreToolUse hook on Write/Edit/NotebookEdit enforces this as a safety net before any file edit.
- Multi-step or multi-session work goes into Linear before execution (routing protocol step 4); session todos (TodoWrite) track only the steps *within* an issue being actively executed.
- Before closing any meaningful session, classify lessons through `core/self-improvement.md`. Invoke the `closeout` skill manually to walk this — it is manual-fire; no hook enforces it (the Stop-hook gate was removed because it re-fired on closeout's own writes).
- When the session creates/closes/changes a Linear project, or creates a new durable on-disk artifact directory, the closeout block MUST include a `## State Deltas` section AND the memory write must happen during closeout — not deferred. The `state-delta` lesson class in `core/self-improvement.md` is the canonical destination.
