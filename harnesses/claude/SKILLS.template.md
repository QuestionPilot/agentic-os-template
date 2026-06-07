# Skills — Claude Code Harness Catalog

> **Canonical source:** the live capability catalog table inside this file is build-generated from `@@AI_CONFIG_DIR@@/capabilities/` and `@@AI_CONFIG_DIR@@/harnesses/claude/capabilities/` by `@@AI_CONFIG_DIR@@/scripts/install.sh` (which substitutes the capability-catalog placeholder token in this template). Do not edit directly — the next `install.sh` re-render will clobber hand-edits to that table.
>
> This template ships ONLY the spine: the routing method, a spine-only routing table, the generated capability catalog, and the built-in harness skills. Everything operator-specific (plugin/skill families, MCP doc-lookup connectors, local CLIs) lives in a local **skills overlay** that `install.{sh,ps1}` append at the operator-overlay marker below — set `SKILLS_OVERLAY_PATH` in `local.env` to point at it. The overlay is operator-local and is never shipped in the framework.
>
> Single source of truth for skills installed and available in **this** Claude Code harness.
> Last verified: 2026-06-07

## How to use this file

1. Start with the **Routing Layer** for non-trivial work.
2. Use the **Live Inventory** to confirm a skill is actually installed before claiming it.
3. Promote from **Candidates** only when a concrete workflow needs the capability.
4. Don't load whole families — pick the smallest useful chain.
5. CLI over MCP when both can do the job (see `@@AI_CONFIG_DIR@@/core/tool-use.md`).

Slash-invoke any skill below as `/<skill-name>` or `/<plugin>:<skill-name>` (the leading slash works the same way in Claude Code).

---

## Routing Layer — "Start Here"

Adapted from the session-agent orchestration sub-routine (`@@AI_CONFIG_DIR@@/capabilities/session-agent.md`) for the skills actually installed here.

**First minute on non-trivial work:**

1. Classify the surface: review-only, planning, implementation, publish/live, ops, durable-memory.
2. Pick **one** primary skill.
3. Add secondary skills only for evidence, risk, or output format.
4. Name the verification gate before claiming completion.
5. Default route: see `@@AI_CONFIG_DIR@@/linear/linear-setup.md` for the Linear surface (lineark CLI or Linear MCP); Obsidian (see `@@AI_CONFIG_DIR@@/obsidian/vault-guide.md`) for durable knowledge; ai-config for operating rules.

### Routing table

| Task surface | Primary route | Add when needed |
| --- | --- | --- |
| Routing ambiguity, multiple skills might apply | `/session-agent` (orchestration sub-routine; this table is the fallback) | see `@@AI_CONFIG_DIR@@/skills/skill-authoring.md` to author a missing capability |
| Pre-PR review of local changes | `review` (built-in) | `security-review`, `simplify` |
| Risky path edit (auth, billing, migrations, deploy, secrets) | `security-review` | `@@AI_CONFIG_DIR@@/verification/high-risk.md` |
| Security audit / sensitive change | `security-review` (built-in) | `@@AI_CONFIG_DIR@@/verification/high-risk.md` |
| Anthropic API / SDK code | `claude-api` | `claude-api` also covers MCP-server patterns |
| UI verification (browser-rendered, headless, cross-browser) | operator's browser-automation tool, if installed | `@@AI_CONFIG_DIR@@/verification/ui-browser.md` |
| Build / update a Claude Code skill | `@@AI_CONFIG_DIR@@/skills/skill-authoring.md` (TDD authoring guidance) | operator skill-creation tooling if installed |
| Verification before claiming completion | task-specific gate under `@@AI_CONFIG_DIR@@/verification/*.md` | operator accelerant skills if installed |
| Active work tracking | See `@@AI_CONFIG_DIR@@/linear/linear-setup.md` for the lineark CLI / Linear MCP setup options | a local TASKS.md for non-Linear tracking |
| Recurring task / interval poll | `loop` (built-in) | `schedule` (built-in) for cron-style remote |

_Routes that need operator-installed plugins/CLIs are listed in the operator overlay below (present only when one is installed)._

### Top recommendations

- **Active work first:** check Linear before non-trivial work. See `@@AI_CONFIG_DIR@@/linear/linear-setup.md` §4 for the per-surface commands (lineark CLI or Linear MCP).
- **CLI > MCP:** before reaching for an MCP tool, check if `gh`, `curl`, `git`, `rg`, or a project script does the job. Token-cheap and faster.
- **Built-ins are skills too:** `review`, `security-review`, `simplify`, `init`, `loop`, `schedule`, `claude-api`, `update-config`, `keybindings-help`, `fewer-permission-prompts` are first-class — prefer them over reinventing.
- **Verification before completion:** every meaningful change ends with a check from `@@AI_CONFIG_DIR@@/verification/` (code-change, ui-browser, deploy-live, high-risk).

---

## Live Inventory

### Agentic OS capabilities

The agentic OS's own capabilities, generated from `@@AI_CONFIG_DIR@@/capabilities/` by `install.sh`. This table is build-generated — do not hand-edit it.

@@CAPABILITY_CATALOG@@

### Built-in / harness skills

| Skill | Purpose | Use when |
| --- | --- | --- |
| `init` | Initialize Claude Code in a project | First time setting up in a repo |
| `review` | Review the current branch / specified diff | Local pre-PR review |
| `security-review` | Security-focused review | Before merging auth, billing, secrets, or migration changes |
| `simplify` | Review changed code for reuse, quality, efficiency | After implementation — find duplicated logic or dead code |
| `loop` | Run a prompt or slash command on an interval | Polling status; recurring local task |
| `schedule` | Create / manage recurring remote agents | Cron-style remote runs, one-off scheduled actions |
| `claude-api` | Build, debug, optimize Anthropic SDK / Claude API code | Editing `anthropic` / `@anthropic-ai/sdk` code, prompt caching, model migration |
| `update-config` | Configure Claude Code via `settings.json` | Permissions, hooks, env vars, automated behaviors |
| `keybindings-help` | Customize keyboard shortcuts | Rebinding keys, chord shortcuts |
| `fewer-permission-prompts` | Scan transcripts, propose `.claude/settings.json` allowlist | Reduce permission prompts for routine commands |

@@OPERATOR_SKILLS_OVERLAY@@

---

## Candidates — not installed, evaluate before adding

_No open candidates. A UI/UX design front door is an operator-local choice — install the UI-skill stack you prefer at operator discretion; the framework ships no UI tool opinion._

---

## MCP connectors

MCP connectors are operator-local — connect the servers this harness needs at your own discretion; the framework ships no connector inventory. The active-work tracker contract is documented in `@@AI_CONFIG_DIR@@/linear/linear-setup.md`.

CLI-first rule: before reaching for an MCP tool, check `gh`, `git`, `curl`, `rg`, `psql`, etc. See `@@AI_CONFIG_DIR@@/core/tool-use.md`.

---

## Maintenance

**When to update this file:**

- A new plugin is installed or a marketplace install adds skills.
- A skill is removed or deprecated.
- Routing decisions in the table prove wrong in practice (correct them).
- A Candidate is promoted to installed, or rejected.

**How to keep it accurate:**

1. Truth-check against the system reminder's "skills available for use with the Skill tool" block at the start of any session where you suspect drift.
2. For added skills, copy the description from the harness's catalog and condense to one line per cell.
3. Don't expand the catalog into upstream documentation — link out.
4. Periodically prune: if a family hasn't been used in 90 days, ask whether to keep it visible at top of file vs collapsed.

**Pruning rules:**

- Remove anything not actually installed.
- Collapse a family to a one-line summary if the leaves are rarely used.
- Don't dump every interesting Anthropic Marketplace plugin — install with intent.

**Relationship to ai-config:**

- `@@AI_CONFIG_DIR@@/skills/registry.md` — the shipped spine capabilities + the baseline rule (stay spine-only). Travels to any harness.
- `@@AI_CONFIG_DIR@@/skills/skill-authoring.md` — how to design and author a skill well.
- **`claude-config/SKILLS.md` (this file)** — what's actually installed in **this** harness right now. Day-to-day routing source.

If a skill in the routing table goes stale, fix this file first. If a portable pattern needs updating, propose a change to `@@AI_CONFIG_DIR@@/skills/` and get user approval (per ai-config governance rule).
