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

Setting up Linear access is a four-stage walkthrough. The framework targets two first-class surfaces — pick one or install both. The framework prefers the `linear` CLI for token cost (small per-call payloads, no MCP tool-catalog overhead), but does not require either: spine capabilities degrade gracefully when neither is installed.

### 3.1 Choose a Linear access surface

| Surface | Best when | Setup effort |
| --- | --- | --- |
| **Option A — `linear` CLI (schpet/linear-cli)** | Default; lower per-call token cost; native binaries for macOS, Linux, AND Windows; works in every harness | Pinned installer + one auth login |
| **Option B — Linear MCP** | You prefer the MCP transport, or you already have it wired for other tools | Per-harness setup — different paths for Claude Code vs Codex |

Both surfaces give the same Linear access semantics; the framework's capability bodies are surface-agnostic and execute against whichever is available.

### 3.2 Option A — install the `linear` CLI

`linear` is the CLI from [github.com/schpet/linear-cli](https://github.com/schpet/linear-cli) (TypeScript/Deno, compiled per-platform binaries; ~160 MB with the embedded runtime; ~200 ms cold start). Upstream documents brew/npm installs; the framework does not use them. Install with the framework's pinned installer instead, from the cloned repo root:

```bash
bash scripts/install-linear-cli.sh
```

PowerShell form (Windows-native, also fine on macOS/Linux):

```powershell
pwsh -NoProfile -File scripts/install-linear-cli.ps1
```

**What it does.** It installs one pinned release tag, verifies the downloaded archive's sha256 against [`scripts/linear-cli-checksums.sha256`](../scripts/linear-cli-checksums.sha256) *before* extraction, extracts in a throwaway dir, hashes the extracted binary, moves it to `~/.local/bin/linear` (`linear.exe` on Windows), re-verifies the moved file against the extraction-time hash before it is ever executed, then runs `linear --version` and requires it to report **exactly** the pinned version. A tag with no entry in the checksum file is an **unvetted release**: the installer refuses it outright rather than downloading on trust. Two entries for the same tag and asset with differing hashes are also a refusal — the pin file would no longer say which artifact is vetted. On any checksum or version mismatch nothing is left installed.

Upstream publishes a `sha256.sum` manifest per release; the framework still maintains its own reviewed pin file — the trust root is repo review, not upstream's manifest (a compromised release would compromise its manifest too).

**Environment overrides** (all optional):

| Variable | Default | Use |
| --- | --- | --- |
| `LINEAR_CLI_VERSION` | the pinned tag | Install a different vetted tag — also the rollback lever. Must match `^v?[A-Za-z0-9._-]+$` |
| `LINEAR_CLI_CHECKSUM_FILE` | `scripts/linear-cli-checksums.sha256` | Point at a different reviewed pin file |
| `LINEAR_CLI_BASE_URL` | upstream GitHub releases base | Install from a mirror. Only `https://` and `file://` are accepted |
| `LINEAR_CLI_INSTALL_DIR` | `~/.local/bin` | Install somewhere else |

Setting `LINEAR_CLI_CHECKSUM_FILE` or `LINEAR_CLI_BASE_URL` moves the trust root off the repo's reviewed defaults, so each prints a `WARNING non-default trust root:` line before anything is downloaded. Installing any tag other than the current default prints a `note: installing non-default tag …` line, so a downgrade onto an older release is never silent.

Exit codes: `0` installed and verified, `1` refused or failed (unvetted tag, conflicting pin entries, checksum mismatch, download/extract failure, smoke mismatch), `2` usage or configuration error, `3` unsupported platform. Upstream ships binaries for Linux x86_64/aarch64, macOS x86_64/arm64, and Windows x86_64 — on anything else the installer exits 3 and names the alternatives: the npm package (`npm install -g @schpet/linear-cli`) or the Linear MCP surface (§3.3).

Confirm the result:

```bash
linear --version
# expect: linear 2.x.y
```

If `~/.local/bin` is not on your PATH, the installer prints the line to add.

#### Updating / re-vetting a new release

New upstream releases are adopted deliberately, never automatically. The sequence is vet → pin → checksum → smoke:

1. **Review** the upstream release: read the release notes and the diff since the currently pinned tag. An unreviewed release is not a candidate.
2. **Download** each published platform archive for the new tag from the official release page.
3. **Compute** each asset's sha256 locally — `sha256sum <asset>` on Linux, `shasum -a 256 <asset>` on macOS, `Get-FileHash -Algorithm SHA256 <asset>` in PowerShell — and cross-check upstream's published `sha256.sum` manifest. Both must agree.
4. **Append** one `<sha256>  <tag>/<asset>` line per asset to `scripts/linear-cli-checksums.sha256`. Keep the existing entries: old tags are what make rollback work.
5. **Bump** the default pin (`LINEAR_CLI_DEFAULT_VERSION` in `scripts/install-linear-cli.sh`, its variable twin in the `.ps1`) to the new tag.
6. **Re-run** the installer, confirm `linear --version` reports the new tag, and re-run the usage-fixture drift check (`tests/linear-cli-usage.test.sh`) — a new release may add or rename commands, and the fixture in [`linear-cli-usage.md`](linear-cli-usage.md) must be updated in the same change.

**Rollback.** Old entries are *kept* in the checksum file on purpose, so reinstalling a previous tag is one command — no edit required:

```bash
LINEAR_CLI_VERSION=<previously-vetted-tag> bash scripts/install-linear-cli.sh
```

A tag installs only if it is already listed in the checksum file; if it is not, vet and pin it first with the same procedure.

**Revocation.** Removing an entry from `scripts/linear-cli-checksums.sha256` is the revocation mechanism, and the only one. When a release is withdrawn upstream or found vulnerable, delete its lines: the installer then refuses that tag as an unvetted release, so nobody can roll back onto it by accident. Deleting an entry is a deliberate security action rather than tidying — record the reason in the commit message.

**Authenticate.** Create a personal API key in Linear (Settings → Security & access → Personal API keys), then run — in your own terminal, interactively:

```bash
linear auth login
```

The key is stored in the OS keyring (Windows Credential Manager / macOS Keychain / libsecret), never in a plaintext file. For **headless contexts** (agents, CI, harness subprocesses) set the `LINEAR_API_KEY` environment variable instead — it takes precedence over stored credentials. Multi-workspace setups: `linear auth login` once per workspace, `linear auth default <slug>` to pick, `--workspace <slug>` per call.

Verify auth:

```bash
linear auth whoami
# expect: workspace, user, display name, role
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

**Removing the `linear` CLI.**

```bash
# Remove the binary (the installer's default destination is ~/.local/bin;
# adjust if you set LINEAR_CLI_INSTALL_DIR). linear.exe on Windows.
rm -f ~/.local/bin/linear
```

Then remove the stored credential from the OS keyring: `linear auth logout` **before** deleting the binary, or remove the entry via the OS keyring UI afterwards. Config/metadata lives at `~/.config/linear/credentials.toml` — remove it too if you don't plan to reinstall.

**Removing the Linear MCP connector.** Disconnect through the harness's MCP panel (Claude Code app's MCP connectors, or the Codex plugin manager). No per-machine config dirs to sweep — both connectors store auth state inside the harness's own state dir.

**Removing a previously-installed Linear CLI not currently maintained as a framework surface.** If you previously installed and have since retired any other Linear CLI (e.g. `pp-linear`), uninstall it explicitly to keep PATH and home-dir hygiene tight. Example for an npm-installed Linear CLI that creates a per-machine config stub:

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
command -v linear   # expect: empty (no output)
linear --version    # expect: command not found
```

For the MCP surface, verify the harness no longer lists the Linear connector — open the Claude Code app's MCP connectors panel (or run `codex plugins list` for Codex) and confirm the Linear connector is absent.

The framework spine capabilities (session-agent, closeout, self-audit) treat a missing Linear surface as a one-line warning rather than a failure — work continues with memory + vault context only.

## 4. Operating Instructions

Both surfaces expose the same Linear semantics; the syntax differs.

### 4.1 Common commands — `linear` CLI

**Before guessing any subcommand or flag, read [`linear-cli-usage.md`](linear-cli-usage.md)** — the framework's static, drift-checked command reference (under 1k tokens). Reach for `linear <cmd> --help` only for long-tail detail *after* the fixture has shown you the command exists; do **not** re-derive the surface by trying per-subcommand `--help` and inferring from failures. Three shapes that bite when guessed: subcommand groups are **singular** (`issue`/`project`/`team`/`label`/`document` — not plurals), every query needs a **team scope** (`--team <KEY>` or `--all-teams`), and `issue query` returns **all states by default** — pass `-s triage -s backlog -s unstarted -s started` for the open-work cut.

```bash
# All projects — the list payload INCLUDES each project's status object
linear project list --json                      # rows at .nodes[]; state at .status.name

# Issues in a specific project, open states only
linear issue query --all-teams --project <PROJECT_UUID> \
  -s triage -s backlog -s unstarted -s started --limit 250 --json

# ALL open issues — any project or none, any assignee (the session-agent O3
# global sweep; the only cut that surfaces a projectless Backlog issue)
linear issue query --all-teams -s triage -s backlog -s unstarted -s started --limit 250 --json

# Issues assigned to a user (display name from `linear auth whoami`)
linear issue query --all-teams --assignee <displayName> -s started --json

# Read full issue detail (state/assignee arrive as objects here)
linear issue view TEAM-NN --json

# Create an issue — full metadata at create time, per linear/issue-template.md
linear issue create -t "Title" --team <TEAM_KEY> --project <PROJECT> \
  --label "label-a" --priority 3 --assignee <user> -d "Markdown body"

# Comment on an issue (stdin body: --body -)
linear issue comment add TEAM-NN -b "Markdown comment"

# Update issue state, title, etc.
linear issue update TEAM-NN --state started

# Relations (dependencies)
linear issue relation add TEAM-X blocked-by TEAM-Y
linear issue relation list TEAM-X
linear issue relation delete TEAM-X blocked-by TEAM-Y

# Escape hatch — anything without a named command, via raw GraphQL
linear api '<graphql query>'
linear schema        # prints the GraphQL schema
```

`--json` is what scripts and agents should use; bare invocation produces human-readable output.

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

**`linear` CLI shapes — verified on v2.5.0:**

| Call | Payload | Notes |
| --- | --- | --- |
| `project list --json` | `{nodes:[…], pageInfo}` | rows carry `slugId` (camelCase) and a `.status` **object** (`.status.name`) |
| `issue query … --json` | `{nodes:[…]}` | `.state` is an **object** (`.state.name`); `.assignee` an object or null; `.priority` a **number** with sibling `.priorityLabel` string |
| `issue view TEAM-NN --json` | one issue **object** (not nodes-wrapped) | same field shapes as query rows |

Two contracts to respect in every script: **unwrap `.nodes`** on list payloads, and **name the open states explicitly** — `issue query` has no hiding default; without `-s` filters, Done and Canceled rows ride along. The Linear MCP returns its own nested shapes — query them per its tool catalog. Cross-check the usage fixture and `linear <cmd> --help` when a documented shape errors; upstream iterates independently and the fixture drift check (`tests/linear-cli-usage.test.sh`) is the tripwire.

## 5. How the AI Uses Linear at Runtime

> **Summary — canonical source is [`capabilities/session-agent.md`](../capabilities/session-agent.md) (session kickoff + routing) and [`capabilities/closeout.md`](../capabilities/closeout.md) (closeout pass).** This section names the durable contract — what an AI agent reads, what it proposes — so a Linear author can reason about the agent's behavior without opening capability bodies. For current mechanics (which sub-steps fire when, which tools are called, which hooks enforce), the linked capabilities are the source of truth.

**Session kickoff — read.** When the harness has either Linear surface installed, the agent's session kickoff runs the projects-first ordered cut:

1. List all Linear projects to surface fresh-spawned work. (`linear project list --json` carries each project's status in the list payload; the Linear MCP can pre-filter to Active + Planned.)
2. For each project, list its open issues to catch backlog items not yet assigned (open states passed explicitly — see §4.1).
3. As a tertiary check, list personally-assigned issues that are In Progress.

This order matters: an assignee-first cut alone misses brand-new projects whose issues are still Backlog and unassigned. See `capabilities/session-agent.md` Mode 1 O3 for the canonical order; `scripts/orient.sh` (PowerShell twin available) runs the whole cut deterministically and emits one `orient/v1` JSON document.

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

The `labels.md` file documents the standard label set for an agentic-OS Linear workspace. The [`linear-cli-usage.md`](linear-cli-usage.md) fixture is the static command reference agents load at runtime (§4.1).

## 7. Failure Modes

Common ways the Linear layer degrades, and what to do.

- **Auth missing or expired.** `linear auth whoami` returns an auth error; MCP returns 401. Re-issue the key from Linear Settings → Security & access; re-run `linear auth login` (interactive), or update `LINEAR_API_KEY` in headless contexts.
- **Headless keyring miss.** An agent or CI runner cannot pop the OS keyring prompt. Set `LINEAR_API_KEY` in that context's environment — it takes precedence over stored credentials by design. Never write the key into a tracked file.
- **No team scope.** `issue query` fails with "No default team configured and no team scope provided". Pass `--team <KEY>` or `--all-teams` — framework scripts always do.
- **Workspace mismatch.** Credentials authenticate against a different workspace than the agent is querying. Verify `linear auth whoami` shows the expected workspace; check `LINEAR_WORKSPACE_URL` in `local.env`; use `--workspace <slug>` or `linear auth default <slug>` on multi-workspace machines.
- **MCP silent-empty-tools.** The Linear MCP connector reports `Connected` but exposes 0 tools on session load. Reconnect from the harness MCP panel. If the silent failure persists, fall back to the `linear` CLI.
- **Surface-doc mismatch.** This guide or the usage fixture cites commands the installed binary does not expose. The pinned version and the docs move together (§3.2 re-vetting step 6); `tests/linear-cli-usage.test.sh` is the drift tripwire. Cross-check `linear <cmd> --help` when a documented command errors.
- **Done/Canceled rows in an "open" cut.** `issue query` returns ALL states by default — there is no hiding default to rely on. Any open-work sweep must pass `-s triage -s backlog -s unstarted -s started` explicitly. A script that forgets this over-counts open work rather than erroring, so it can sink an orient or audit conclusion silently.
- **`.nodes` unwrap missed.** Every list payload is an object `{nodes:[…]}`. Piping it straight into an array filter (`.[]`, `length`) errors or miscounts. Unwrap `.nodes` first; `issue view` is the exception (a single object).
- **Issue not found.** `linear issue view TEAM-NN` returns not-found despite the issue existing. Common cause: the issue lives in a project the key's user cannot access; verify by viewing the issue in the Linear UI under the same account that owns the key.
- **Free-plan issue cap.** Linear's Free plan caps a workspace at **250 active (non-archived) issues**; `Done` and `Canceled` issues still count, and once the cap is hit, creating new issues is blocked. The fix is to **archive** closed issues — archived issues are retained but no longer count toward the cap — not to delete them. Watch one masking effect: a `--limit`-bounded query can hide the true active total on a large workspace; page with `--limit 0` (unlimited) or through GraphQL `issues(first: 250, after: $cursor)` for an accurate count.
- **Archived issues invisible.** List and view calls exclude archived issues, so reading an archived issue returns *not found* even though its data is intact. Read it via the `linear api` escape hatch with a GraphQL `issues(filter: …, includeArchived: true)` connection query (the flag is a connection argument — the singular `issue(id:)` query doesn't accept it), or through the Linear UI's Archive view. Bulk archive: drive the GraphQL `issueArchive(id: <issue UUID>) { success }` mutation per issue, sequentially to respect the rate limit below (the `id` is each issue's internal `.id`, not its `TEAM-NN` key).
- **Rate limit.** Linear's GraphQL API has request-per-minute limits. The CLI surfaces this as an error; back off and retry after the documented window. Agents should batch reads (one `project list` then iterate locally) rather than per-issue calls.
