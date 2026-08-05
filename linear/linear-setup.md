# Linear Setup — Active-Work Layer Setup, Operating Instructions, and Runtime Contract

`linear/` is the canonical pointer surface for the agentic OS's Tier 2 active-work layer. This guide explains the role, walks an operator through first-time setup of either Linear access surface, names the operating commands, and documents how AI agents interact with Linear at runtime.

## 1. Purpose and Audience

This document has two audiences:

- **An operator setting up the framework on a fresh machine** — read end-to-end. §3 walks first-time Linear access setup step-by-step for either surface; §4 names the operating commands; §6 points at the issue and closeout templates.
- **An AI agent reading at runtime** — load only the relevant slice. §2 names what belongs in Linear vs other layers; §5 documents the runtime contract (kickoff query order, Linear gate, status updates).

Linear stores active work: tasks, projects, owners, status, acceptance criteria, blockers, follow-ups, and links to PRs and artifacts. It is not the durable-knowledge store (that is the Obsidian vault), the operating framework (that is `agentic-os-template`), or a raw-source archive.

## 2. Role in the Agentic OS

The framework uses three memory tiers. Each layer owns one class of fact; writes go to the layer that owns the change.

> **Summary — canonical source is [`core/memory-model.md`](../core/memory-model.md).** This section recaps the three-tier model so a fresh reader can use linear-setup standalone. For the full taxonomy, the data-readiness layer, and the per-harness memory index contract, read [`core/memory-model.md`](../core/memory-model.md) directly.

| Tier | Layer | Owns |
| --- | --- | --- |
| 1 | `agentic-os-template` | Operating rules, verification expectations, capability specs, skill catalog, harness entrypoints. |
| 2 | Linear | Active tasks, projects, owners, status, acceptance criteria, blockers, follow-ups. |
| 3 | Durable vault (Obsidian or equivalent) | Durable lessons, decisions and rationale, project memory, wiki notes, source-derived summaries. |

Linear sits at Tier 2. It is the shared execution ledger humans and agents read to know what is being worked on now and what proof will close it. It is not a duplicate vault and not a daily journal.

**Write rule (recap from `core/memory-model.md`):**

| Change | Destination |
| --- | --- |
| Operating rule, verification pattern, skill guidance | `agentic-os-template` |
| Active task, blocker, acceptance criteria, follow-up | Linear |
| Durable lesson, decision, project memory | The vault |

If a write would fit multiple layers, split it. Put the active follow-up in Linear, the durable lesson in the vault, the reusable operating rule in `agentic-os-template`.

## 3. First-Time Setup

Setting up Linear access is a four-stage walkthrough. The framework targets two first-class surfaces — pick one or install both. The framework prefers the `lineark` CLI for token cost (smaller per-call payloads), but does not require either: spine capabilities degrade gracefully when neither is installed.

### 3.1 Choose a Linear access surface

| Surface | Best when | Setup effort |
| --- | --- | --- |
| **Option A — `lineark` CLI** | Default; lower per-call token cost; works in both Claude Code and Codex | One-line install + token drop |
| **Option B — Linear MCP** | You prefer the MCP transport, or you already have it wired for other tools | Per-harness setup — different paths for Claude Code vs Codex |

Both surfaces give the same Linear access semantics; the framework's capability bodies are surface-agnostic and execute against whichever is available.

### 3.2 Option A — install `lineark` CLI

`lineark` is a single-binary Linear CLI maintained at [github.com/flipbit03/lineark](https://github.com/flipbit03/lineark). Install with the curl-to-shell pattern the upstream README documents:

```bash
curl -fsSL https://raw.githubusercontent.com/flipbit03/lineark/main/install.sh | sh
```

The script drops the binary into `~/.local/bin/lineark`. Confirm it is on PATH and reports a 3.x version:

```bash
lineark --version
# expect: lineark 3.x.y
```

**Provide the API token.** `lineark` reads `~/.linear_api_token` by default. Create the token in Linear (Settings → API → Personal API keys) and write it to the file:

```bash
printf '%s' '<YOUR_LINEAR_API_TOKEN>' > ~/.linear_api_token
chmod 600 ~/.linear_api_token
```

Verify auth:

```bash
lineark whoami
# expect: your Linear user info as JSON or human-readable
```

### 3.3 Option B — install Linear MCP

The MCP transport differs per harness.

**Claude Code:** the official Linear MCP connector is Anthropic-managed. Configure it through the Claude Code app's MCP connectors panel. See `linear.app/docs/mcp` for the up-to-date connection flow.

**Codex:** Linear MCP is available via the [openai/plugins linear plugin](https://github.com/openai/plugins/tree/main/plugins/linear). Follow that repo's README for the install + auth flow; on first use it will guide you through the Linear OAuth handshake.

### 3.4 Record the workspace URL

The framework reads the active Linear workspace URL from `local.env`. From the cloned `agentic-os-template` repo root:

```bash
# Edit local.env (created by bootstrap.sh from templates/local.env.example).
# Set LINEAR_WORKSPACE_URL to the absolute https URL of your Linear workspace
# (e.g. https://linear.app/your-workspace). Quote if needed — local.env is
# sourced.
LINEAR_WORKSPACE_URL="https://linear.app/<your-workspace>"
```

Re-run `bash scripts/install.sh --harness claude --harness codex` after editing `local.env` so any compiled harness entrypoint references stay current.

### 3.5 Uninstalling or migrating between surfaces

When swapping Linear access surfaces — or removing one outright — clean up the per-machine artifacts the install flow created. The standard uninstall command typically removes the binary but leaves config dirs, cache dirs, data files, and tokens behind. Stale artifacts accumulate disk weight, confuse future hygiene sweeps, and can mislead drift checks.

**Removing the `lineark` CLI.**

```bash
# Remove the binary (curl-installer puts it in ~/.local/bin)
rm -f ~/.local/bin/lineark
# Remove the API token if you don't plan to reinstall
rm -f ~/.linear_api_token
```

**Removing the Linear MCP connector.** Disconnect through the harness's MCP panel (Claude Code app's MCP connectors, or the Codex plugin manager). No per-machine config dirs to sweep — both connectors store auth state inside the harness's own state dir.

**Removing a previously-installed Linear CLI not currently maintained as a framework surface.** If you previously installed and have since retired any other Linear CLI (e.g. `pp-linear`, `schpet/linear-cli`), uninstall it explicitly to keep PATH and home-dir hygiene tight. Example for an npm-installed Linear CLI that creates a per-machine config stub:

```bash
npm uninstall -g <package-name>
rm -rf ~/.<tool-name> ~/.<tool-name>.* 2>/dev/null    # per-machine config stub
rm -rf ~/.cache/<tool-name> 2>/dev/null               # cache leftover
rm -rf ~/.config/<tool-name> 2>/dev/null              # XDG config variant
rm -rf ~/.local/share/<tool-name> 2>/dev/null         # XDG data variant
```

The standard `npm uninstall` removes the binary but does not always clean up the `~/.<tool-name>/` config stub, the `~/.cache/<tool-name>/` cache, or any XDG-shaped (`~/.config/<tool>/`, `~/.local/share/<tool>/`) state the tool created at first run. Any of these can survive uninstall by hours or days; sweep them in the same operation. Not every CLI uses all four locations — `rm -rf` with the suppressed-error flag is safe on missing dirs.

**Verify the CLI surface is gone.** After uninstall, confirm the CLI is no longer on PATH and that any framework-side adapter references degrade gracefully:

```bash
command -v lineark   # expect: empty (no output)
lineark --version    # expect: command not found
```

For the MCP surface, verify the harness no longer lists the Linear connector — open the Claude Code app's MCP connectors panel (or run `codex plugins list` for Codex) and confirm the Linear connector is absent.

The framework spine capabilities (session-agent, closeout, self-audit) treat a missing Linear surface as a one-line warning rather than a failure — work continues with memory + vault context only.

## 4. Operating Instructions

Both surfaces expose the same Linear semantics; the syntax differs.

### 4.1 Common commands — lineark CLI

**Before guessing any subcommand or flag, run `lineark usage`.** It prints the
entire command surface as one compact LLM-friendly reference — the authoritative
source of truth for what commands and flags exist. Reach for `lineark <cmd>
--help` only for the long-tail detail *after* `usage` has shown you the command
exists; do **not** re-derive the surface by trying per-subcommand `--help` and
inferring from failures. Two shapes that bite when guessed: comments are the
**top-level** `lineark comments create <ISSUE> --body "<text>"` (not
`issues comment`), and the subcommand groups are **plural**
(`projects`/`issues`/`comments`/`labels`/`documents`) — `project-milestones` is
the only hyphenated group. The examples below are the common cuts; `lineark
usage` is the full list.

```bash
# Full command reference — start here when unsure of a flag
lineark usage

# All projects (`projects list` carries no state field or state filter — only --led-by-me;
# read one project's state via `projects read` below)
lineark projects list --format json

# One project's full detail INCLUDING state — the list payload never carries it
lineark projects read <PROJECT_NAME_OR_UUID> --format json   # state at .status.name

# Update a project's state (e.g. close out a finished project)
lineark projects update <PROJECT_NAME_OR_UUID> --status "Completed"

# Issues in a specific project (Done/Canceled hidden by default; --show-done to include)
lineark issues list --project <PROJECT_UUID> --format json

# ALL open team issues — any project or none, any state, any assignee (the
# session-agent O3 global sweep; the only cut that surfaces a projectless
# Backlog/Blocked/unassigned issue)
lineark issues list --format json

# Issues assigned to you, In Progress
lineark issues list --mine --format json
# (on `list`, .state is a bare string — filter on .state == "In Progress")

# Read full issue body + comments
lineark issues read TEAM-NN --format json

# Create an issue — full metadata at create time, per linear/issue-template.md
# (project, deliberate priority, >=1 label, assignee; --parent when decomposing)
lineark issues create "Title" \
  --team <TEAM_KEY> \
  --project <PROJECT_NAME_OR_UUID> \
  --labels "label-a,label-b" \
  --priority medium \
  --assignee <owner> \
  --description "Markdown body per the issue-template.md sections" \
  --format json

# Comment on an issue
lineark comments create TEAM-NN --body "Markdown comment" --format json

# Update issue state, assignee, etc.
lineark issues update TEAM-NN --state "In Progress" --assignee me --format json

# Archive / unarchive an issue (archived issues drop out of list/read/search — see §7)
lineark issues archive TEAM-NN --format json
lineark issues unarchive TEAM-NN --format json

# Add a relation (blocks, blocked-by, related)
lineark relations create TEAM-X --blocked-by TEAM-Y --format json
```

`--format json` is what scripts and agents should use; bare invocation produces human-readable output.

### 4.2 Common commands — Linear MCP

The MCP tool surface varies by client. Both Claude Code's connector and Codex's `openai/plugins` linear plugin expose roughly:

- `list_projects` / `get_project`
- `list_issues` / `get_issue` / `save_issue`
- `list_comments` / `save_comment`
- `list_users` / `get_user`
- `list_teams` / `get_team`

Refer to each plugin's documentation for the exact tool names and argument shapes; both providers update their tool catalogs independently.

### 4.3 JSON response shape

Both surfaces return Linear's underlying object model: `id`, `identifier` (e.g. `ABC-123`), `title`, `description`, `priority`, `assignee`, `team`, `labels`, `url`, plus relations and comments where requested. Scripts should query against `.identifier` for the human-readable issue ID and `.id` (UUID) for relations and update calls.

**`.state` shape varies by `lineark` subcommand — do not assume `.state.name` everywhere.** Verified on `lineark` 3.0.3:

| Call | `.state` shape | Query |
| --- | --- | --- |
| `issues read TEAM-NN` | object `{id, name}` | `.state.name` |
| `issues list` | bare **string** (e.g. `"Backlog"`) | `.state` |
| `projects list` | **absent** — payload is only `id`, `name`, `slug_id`, `lead` | n/a |
| `projects read` | n/a — project state lives in a `.status` object instead | `.status.name` |

So `.state.name` over an `issues list` throws `Cannot index string with string "name"`, and there is **no project-state field to filter on in the list** — `projects list` offers only `--led-by-me`. Project state IS readable and settable per-project, just under a different key: `projects read <name|uuid>` returns it as a `.status` object (`.status.name`), and `projects update --status <name>` sets it (note also that `projects update`'s response echoes only `id`/`name`/`slugId` — read the project back to verify the new state). `issues list` also **hides Done/Canceled by default** (`--show-done` to include), so its raw output is already the open-work cut. The Linear MCP returns richer nested objects (`state.name` consistently, project state available) — query its shapes per its tool catalog. Cross-check `lineark --help` when a documented shape errors; both upstreams iterate independently.

## 5. How the AI Uses Linear at Runtime

> **Summary — canonical source is [`capabilities/session-agent.md`](../capabilities/session-agent.md) (session kickoff + routing) and [`capabilities/closeout.md`](../capabilities/closeout.md) (closeout pass).** This section names the durable contract — what an AI agent reads, what it proposes — so a Linear author can reason about the agent's behavior without opening capability bodies. For current mechanics (which sub-steps fire when, which tools are called, which hooks enforce), the linked capabilities are the source of truth.

**Session kickoff — read.** When the harness has either Linear surface installed, the agent's session kickoff runs the projects-first ordered cut:

1. List all Linear projects to surface fresh-spawned work. (`lineark projects list` returns the full set — no state field or filter in the list; `projects read` exposes a single project's state when needed; the Linear MCP can pre-filter to Active + Planned.)
2. For each project, list its issues to catch backlog items not yet assigned. (`lineark issues list` already hides Done/Canceled.)
3. As a tertiary check, list personally-assigned issues that are In Progress.

This order matters: an assignee-first cut alone misses brand-new projects whose issues are still Backlog and unassigned. See `capabilities/session-agent.md` Mode 1 O3 for the canonical order, including the per-subcommand `.state` shapes (§4.3).

**Linear gate — declare before edits.** Before any file-modifying action in a multi-step or multi-session task, the agent declares the active Linear issue in its routing block:

```
Linear gate: TEAM-NN
```

Single-step trivial changes (e.g. a one-line fix) can declare `Linear gate: none — single-step`. The framework's harness-side enforcement hook checks for this line — together with the routing declaration's `Lessons:` recall line (see `capabilities/session-agent.md` R1a/R5) — before allowing file edits; missing either blocks the edit.

**Closeout — update.** At session end, the closeout pass posts a structured comment to any active Linear issue (Result / Verification / State Deltas / Running State / Residual Risk / Lessons / Pick up here). If the session completes an issue, closeout moves it to Done with the proving artifact link (PR URL, merged commit, deployed change).

**Issue creation — operator-owned workstreams, standard-conforming issues.** The split: the session-agent R4 Linear gate authorizes the agent to create the single issue that gates its own multi-step task (that is the gate working as designed); what stays the operator's call is spawning multi-session WORKSTREAMS — new projects, or issue fan-outs that outlive the session. Agents draft Linear-ready markdown when no write-capable surface is available. Either way, the framework's `linear/issue-template.md` is the canonical issue shape — BOTH halves: the required-metadata checklist (project, deliberate priority, labels, assignee, parent/relations when spawned by other tracked work) and the structured description body. Metadata is set at create time, not deferred — a title + prose-blob issue is nonconforming even when the prose is good. The advisory `scripts/check-linear-hygiene.sh` (PowerShell twin available) sweeps open issues against this standard and WARNs on gaps; it is a soft signal, never a gate, and deliberately not part of `make verify` (issue hygiene is workspace state, not repo state).

**Semantic currentness — do the durable layers still tell the truth?** The sibling advisory `scripts/check-state-currentness.sh` (PowerShell twin available) reads the other direction: it compares issue-state CLAIMS written into memory notes and `status: active` vault project notes against live tracker state, and flags project-status/child contradictions (a Completed project with open children, a Backlog project with In Progress children). It never edits a note or a tracker record. Like the hygiene sweep it is a soft signal and deliberately outside `make verify` — CI has no tracker token. `self-audit` invokes it and reports the result in a section separate from the mechanical pillar scores, so a tidy-but-stale system can no longer present as an unqualified 100/100.

## 6. Templates

Three templates ship in `linear/`. Use them when authoring new issues, project closeouts, or harness-agnostic Linear workflows.

| Template | Use when |
| --- | --- |
| [`issue-template.md`](issue-template.md) | Creating a new actionable issue. The canonical standard: the required-metadata checklist (project / priority / labels / assignee / relations, set at create time) plus the outcome / scope / acceptance-criteria / verification / dependencies / links body. |
| [`closeout-format.md`](closeout-format.md) | Posting a session closeout block as a Linear comment. Includes the Result / Verification / State Deltas / Running State / Residual Risk / Lessons / Pick up here shape. |
| [`tool-agnostic-linear.md`](tool-agnostic-linear.md) | Working with Linear via a harness that has no native skill (markdown-drafts mode). |

The `labels.md` file documents the standard label set for an agentic-OS Linear workspace.

## 7. Failure Modes

Common ways the Linear layer degrades, and what to do.

- **Token missing or expired.** `lineark whoami` returns auth error; MCP returns 401. Re-issue the token from Linear Settings → API; for `lineark`, rewrite `~/.linear_api_token` and re-`chmod 600`.
- **Workspace mismatch.** Token authenticates against a different workspace than the agent is querying. Verify `lineark whoami` shows the expected workspace; check `LINEAR_WORKSPACE_URL` in `local.env`.
- **MCP silent-empty-tools.** The Linear MCP connector reports `Connected` but exposes 0 tools on session load. Reconnect from the harness MCP panel. If the silent failure persists, fall back to `lineark`.
- **Surface-doc mismatch.** This guide cites lineark commands or MCP tool names that the installed binary or connector version does not expose. Both upstreams iterate independently; cross-check `lineark --help` or the MCP plugin's tool catalog when a documented command errors.
- **`.state` shape mismatch (lineark).** A jq filter using `.state.name` over `lineark issues list` errors with `Cannot index string with string "name"`, and a project state-filter over `projects list` silently matches nothing — the LIST payload carries no state field (project state lives in `projects read`'s `.status` object, `.status.name`, and is settable via `projects update --status`). `.state` is an object only on `issues read`; it is a bare string on `issues list` and absent from `projects list`. Query `.state` on a list, `.state.name` on a read; never pre-filter projects by state against `projects list`. Full table in §4.3.
- **`--project` takes a NAME or UUID — never a `slug_id`.** `lineark projects list` prominently shows each project's `slug_id`, but passing that to `issues list --project` silently returns an empty result instead of erroring — which reads as "no open issues in this project" and can sink a whole orient or audit conclusion. Filter by the project's full `id` (UUID) or exact name; treat an unexpectedly-empty project cut as a suspect identifier before trusting it (re-run with the UUID from `projects list`'s `id` field).
- **Issue not found.** `lineark issues read TEAM-NN` returns not-found despite the issue existing. Common cause: the issue lives in a project the token's user does not have access to; verify by viewing the issue in the Linear UI under the same account that owns the token.
- **Free-plan issue cap.** Linear's Free plan caps a workspace at **250 active (non-archived) issues**; `Done` and `Canceled` issues still count, and once the cap is hit, creating new issues is blocked. The fix is to **archive** closed issues — archived issues are retained but no longer count toward the cap — not to delete them. Watch one masking effect: `lineark issues list --limit` tops out at 250, so on a large workspace the visible count can hide the true active total; page through GraphQL `issues(first: 250, after: $cursor)` for an accurate count.
- **Archived issues invisible to `lineark`.** `lineark issues read|list|search` all exclude archived issues, so reading an archived issue returns *not found* even though its data is intact. Read an archived issue's description and comments via a GraphQL `issues(filter: …, includeArchived: true)` connection query (the flag is a connection argument — the singular `issue(id:)` query doesn't accept it), or through the Linear UI's Archive view; `lineark issues unarchive TEAM-NN` restores it to the active set. `lineark` has no bulk-archive command — `lineark issues archive` takes one issue at a time and `batch-update` cannot archive — so to clear many at once, drive the GraphQL `issueArchive(id: <issue UUID>) { success }` mutation per issue, sequentially to respect the rate limit below (the `id` is each issue's internal `.id` from a list/read, not its `TEAM-NN` key).
- **Rate limit.** Linear's GraphQL API has request-per-minute limits. `lineark` surfaces this as an error; back off and retry after the documented window. Agents should batch reads (one `projects list` then iterate locally) rather than per-issue calls.
