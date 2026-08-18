# Cursor — Harness Adapter

This file is the **single declaration** of everything specific to the Cursor
harness (Anysphere) — the Cursor desktop editor, its terminal Agent CLI
(`agent`), and its Cloud Agents. The agnostic core (`core/`, `capabilities/`,
`verification/`, …) carries none of it. The build script (`scripts/install.sh`)
reads this adapter plus the `capabilities/` specs and compiles them into
Cursor's native format — run it with `install.sh --harness cursor`.

`harnesses/` is the **only** quarantined harness-specific zone in this
repository. Harness tool names, hook event names, and harness paths are expected
here and nowhere else (`scripts/check-drift.sh` denies the Cursor token set in
shared dirs).

Verified against **Cursor v3.16.17** (desktop) / Agent CLI
`2026.08.11-e8db854`. **Provenance discipline — every fact below carries one of
two marks:**

- `docs 2026-08-18` — sourced from the official Cursor doc corpus scraped on
  that date (`cursor.com/docs`; every page also serves raw Markdown at
  `<url>.md`).
- `live-verified 2026-08-18` — exercised end-to-end on this machine: macOS,
  headless `agent -p --trust`, a scratch git repo with a project-level
  `.cursor/hooks.json`, marker-file and magic-token proofs.

What remains unproven is enumerated in **UNVERIFIED (documented gap)**, each
with a reproduction recipe. Treat an UNVERIFIED enforcement claim as *expected
but unproven*; treat a `live-verified` one as fact.

The build target is the directory named by the `CURSOR_CONFIG_DIR` variable in
`local.env`. `install.sh` requires it to be set explicitly — the build does not
assume a default.

> **Name-collision note (deliberate).** Cursor's own Agent CLI reads an
> environment variable *literally named* `CURSOR_CONFIG_DIR` to relocate its
> `cli-config.json` (docs 2026-08-18, `cli/reference/configuration.md`). Our
> `local.env` variable of the same name is the **build target** for this harness
> — normally `~/.cursor`. The two coincide **by design**: if an operator
> relocates Cursor's config home, the framework must render into the same place,
> so sharing one variable name keeps them from drifting apart. The build never
> writes `cli-config.json` itself (see Fact 5).

> **Scope note.** This adapter ships the **3 native** capabilities
> (`session-agent`, `closeout`, `self-audit`) — the spine. Operator-local
> (Shape C) skills live under `<config>/skills/<name>/` outside the manifest and
> are preserved across re-renders, exactly as on the other harnesses.

---

## Fact 1 — Skill file & frontmatter schema

*(docs 2026-08-18, `skills.md`.)*

Each capability compiles to one skill file at `<config>/skills/<name>/SKILL.md`.
Cursor auto-discovers skills from four roots — `.cursor/skills/`,
`.agents/skills/` (project) and `~/.cursor/skills/`, `~/.agents/skills/` (user)
— walking each root **recursively**, so any `SKILL.md` under the tree is picked
up and the skill's identity comes from the folder that *contains* `SKILL.md`,
not the parent category.

The format is the **agentskills.io open standard** — the same `SKILL.md` shape
Claude Code, Codex, and Hermes consume, so the compiler emits one frontmatter
shape for all four harnesses:

```yaml
---
name: <capability name>
description: <trigger-rich one-paragraph description — what the skill does and
             when to use it; this is what Cursor matches on to decide relevance>
---
```

- Cursor requires `name` + `description`. `name` must be lowercase letters,
  digits, and hyphens only, **and must match the parent folder name** — which
  the compiler satisfies structurally (it writes `skills/<base>/SKILL.md` with
  `name: <base>`).
- Optional fields Cursor also accepts: `paths` (glob scoping — the spine
  capabilities set none, they are always relevant), `disable-model-invocation`
  (explicit `/name` only — the spine sets none, model-decided invocation is
  wanted), and `metadata`. The legacy `globs` field is accepted as a fallback;
  new skills use `paths`.
- The build keeps `description` concise — the same ~1536-char ceiling the
  compiler warns at for the other harnesses applies as a portability guard.
- The skill body is the capability's harness-neutral body followed by the
  per-harness realization (`harnesses/cursor/capabilities/<name>.md`).

**Compat discovery is real — which makes it a coexistence problem, not a
convenience.** Cursor also auto-loads skills from `.claude/skills/`,
`.codex/skills/`, `~/.claude/skills/`, and `~/.codex/skills/` (docs
2026-08-18), and a project `.claude/skills/` was confirmed discovered
alongside `.cursor/skills/` in the live run (**live-verified 2026-08-18**, V5 —
with a negative control: a non-existent skill was not loaded, and the model
enumerated exactly the planted set).

The build still renders the **native** `<config>/skills/` target. It is
deterministic, manifest-governed, independent of the third-party settings
toggle, and it follows a relocated build target — whereas compat discovery reads
literal home paths, so an operator whose Claude config dir is relocated via
`CLAUDE_CONFIG_DIR` gets nothing from `~/.claude/skills/`.

The consequence to plan around: on a machine with both renders visible in one
project, Cursor sees the same-named spine skills only **once** — precedence is
deterministic and the project `.claude/skills/` copy **shadows** the
`.cursor/skills/` copy (U5, live-verified). Keep the two renders' spine skills
rendered from the same source (the drift gate already enforces this) so the
shadowing is harmless.

## Fact 2 — Hook events, enforcement classes, and the hooks.json block

*(docs 2026-08-18, `hooks.md` + `reference/third-party-hooks.md`.)*

Cursor's hook system spawns processes that speak **JSON over stdio** and runs
them at named agent-loop stages. Hooks are wired in a dedicated, fully-generated
`<config>/hooks.json`:

```json
{
  "version": 1,
  "hooks": {
    "<eventName>": [
      {
        "command": "<absolute path to script>",
        "matcher": "<regex, event-dependent>",
        "timeout": 10,
        "failClosed": true
      }
    ]
  }
}
```

`version` is the config schema version (`1`). Cursor **watches and hot-reloads**
`hooks.json`, so a re-render takes effect without restarting the app. The build
writes absolute `command` paths, which sidesteps the relative-path trap entirely
(user hooks resolve relative paths against `~/.cursor/`, project hooks against
the project root).

**Enforcement-class → hook mapping.** A capability header only *names* an
enforcement class. This adapter maps each class to a real, hand-written hook
script in `harnesses/cursor/hooks/`:

| Enforcement class | Hook event | `matcher` | Hook script | Behavior |
| --- | --- | --- | --- | --- |
| `pre-edit-gate` | `preToolUse` | `Write\|Delete` | `hooks/session-agent.sh` | Blocks the first file-modifying tool use until the session-agent capability has run and a complete routing declaration (`Linear gate:` + `Lessons:` lines) exists for this conversation. Safety net; primary auto-fire is the `sessionStart` directive in `framework-surface.sh`. |

`preToolUse` matchers filter by **tool type**; the documented values are
`Shell`, `Read`, `Write`, `Grep`, `Delete`, `Task`, and `MCP:<tool_name>`
(docs 2026-08-18). A file edit reports `tool_name: "Write"` and a file
deletion reports `tool_name: "Delete"` (**both live-verified 2026-08-18** —
headless runs, observed payloads; see U6 for the `Delete` payload's
relative-path caveat), so `Write|Delete` is the generated matcher.

One deliberate omission:

- **`Shell`** is excluded on purpose, matching the Claude and Codex gates:
  gating every shell command would block the orient itself (the capability's own
  `git`/tracker/vault reads). The consequence is a known **shell-write
  bypass** — an agent can write files through `Shell` without tripping the gate.
  That is the same accepted posture Claude and Codex ship; Hermes is the outlier
  (it gates `terminal` because its local backend has full-filesystem reach).
  Cursor offers a finer instrument the others do not — a dedicated
  `beforeShellExecution` event with a command-text matcher — so a shell-mutation
  gate is *possible* here without gating every shell call. Left as an open
  design question rather than shipped unproven (see the closing section).

The gate is a discipline net with a documented kill switch, not a security
boundary.

The build copies the named hook script into place and merges its `hooks.json`
block. Enforcement is **never code-generated** — the scripts are real files.

**Hook decision format (the adapter-critical divergence).** A `preToolUse` hook
returns, on stdout with exit `0`:

```json
{ "permission": "allow" | "deny", "user_message": "…", "agent_message": "…" }
```

- `"deny"` blocks and `"allow"` proceeds — **live-verified 2026-08-18**: a
  `deny` response really did stop a `Write`; the target file was never created
  and the agent surfaced the hook's `agent_message`.
- **`"ask"` is accepted by the schema but NOT enforced for `preToolUse`**
  (docs 2026-08-18 state this explicitly; it *does* work on the
  `beforeShellExecution` family). So `deny` is the only reliable block on this
  event — never emit `ask` from the gate.
- Exit code `2` also blocks (equivalent to `deny`), matching Claude Code.
- **Any other non-zero exit is FAIL-OPEN by default — the action proceeds.**
  This is the opposite of what a gate wants.

**Fail-closed is a two-layer contract.** Because the default is fail-open, the
gate is hardened on both sides:

1. The generated `hooks.json` entry for `session-agent.sh` sets
   **`"failClosed": true`**, so a crash, timeout, or invalid-JSON response
   blocks instead of passing.
2. The script itself **denies on error** — a missing `jq`, an unreadable
   payload, or an absent conversation id emits an explicit `deny`, never a
   silent exit.

Belt and braces: layer 1 is **live-verified** — Cursor honors `failClosed` on
`preToolUse` (a marker-proven crash blocked the write; see U1/V7); layer 2
alone would depend on the script always reaching its own deny path.

**Context injection.** `sessionStart` fires when a new composer conversation is
created and returns `{"additional_context": "…"}` (it may also return
`{"env": {…}}`, whose values are passed to every later hook in that session).
**This is the auto-fire channel and it is live-verified 2026-08-18** — a magic
token placed in `additional_context` came back out of the model, so the
injection reaches the conversation, not just a log. Input is `{session_id,
is_background_agent, composer_mode}` plus the base fields; `session_id` is the
same value `preToolUse` calls `conversation_id`. The event is explicitly
**fire-and-forget** — the agent loop does not wait for or enforce a blocking
response, and `continue: false` does not block session creation. That is
exactly what the framework needs from it: the hook only *surfaces* context; the
`preToolUse` gate is the enforcement half.

**Non-capability hook.** One hook is a standalone harness feature, not tied to
any capability: `hooks/framework-surface.sh` runs on `sessionStart` (no matcher
— `sessionStart` has no documented matcher field) and surfaces two context
blocks as `additional_context`: (a) recent `agentic-os-template` framework
commits, and (b) the session-agent invocation directive (the auto-fire mechanism
for the spine capability — see `capabilities/session-agent.md` Mode 1). The
build wires it unconditionally.

**Kickoff reconciliation contract.** The hook's commit window is the freshness
signal at session start; memory captures what was true when written, the commit
log captures what is true now. The contract requiring the model to cross-check
workspace-prefix issue identifiers (`<PREFIX>-<number>`) in the surfaced commits
against memory headlines lives in the `session-agent` capability's Mode 1 orient
(sub-step O2, `capabilities/session-agent.md`). It is a model-behavior contract
documented in the capability body, not a hook behavior.

**`jq` runtime contract.** Every hook script needs `jq` on the hook PATH. The
behavior when `jq` is absent is split by hook role: the **gate** hook
(`session-agent.sh`) fails **closed** — it emits a static `{"permission":"deny"}`
string, so a broken environment cannot silently disable enforcement; the
**surfacing** hook (`framework-surface.sh`) fails **open** — it exits silently,
since missing injected context is not a safety risk. The per-gate kill switch
still bypasses the gate before the `jq` check is reached.

**Configuration precedence.** All matching hooks from every source run; on
conflict the higher-priority source wins. Order (highest → lowest): Enterprise
(MDM, `/Library/Application Support/Cursor/hooks.json` on macOS) → Team
(dashboard-distributed) → Project (`<project>/.cursor/hooks.json`) → User
(`<config>/hooks.json`). The framework renders the **User** layer, so a project
or enterprise policy can override it — expected and correct.

**Third-party (Claude Code) hook compat — not the framework's channel.** With
*Include third-party Plugins, Skills, and other configs* enabled, Cursor also
loads hooks from `.claude/settings(.local).json` and `~/.claude/settings.json`,
mapping event names (`PreToolUse`→`preToolUse`, `SessionStart`→`sessionStart`,
`UserPromptSubmit`→`beforeSubmitPrompt`, `Stop`→`stop`) and tool names
(`Bash`→`Shell`, `Edit`→`Write`; `Glob`/`WebFetch`/`WebSearch` unmapped), and
honoring both the nested `hookSpecificOutput` and flat output shapes plus exit-2
blocking. `Notification` and `PermissionRequest` are unsupported. The framework
does **not** route through this: it depends on a settings toggle, reads literal
home paths (so a relocated `CLAUDE_CONFIG_DIR` is invisible), and would make the
spine's two harness renders shadow each other. Native `hooks.json` only.

**Enforcement parity — surface-dependent.** The framework's design anticipated a
harness with no lifecycle interception, on which a hard gate degrades to a
strong instruction in the entrypoint. Cursor does not degrade uniformly; it
degrades **per surface**:

| Surface | `sessionStart` (auto-fire) | `preToolUse` (gate) |
| --- | --- | --- |
| Agent CLI headless (`agent -p --trust`) | **fires — live-verified** | **fires and blocks — live-verified** |
| Agent CLI (`agent`, interactive) | expected — **UNVERIFIED** | expected — **UNVERIFIED** |
| Desktop IDE / Agent Chat | expected — **UNVERIFIED** (U3) | expected — **UNVERIFIED** (U3) |
| **Cloud Agents** | **never fires** (documented) | project hooks only |

Note the shape of that table: it is the **inverse** of the Codex situation. On
Codex the interactive TUI is the documented-but-unproven surface and
`codex exec` provably runs no hooks at all; on Cursor the **headless lane is the
proven one** and the interactive/IDE surfaces are the ones still to confirm. A
Cursor automation lane therefore has full enforcement parity today — the
opposite of the caveat a reader carrying Codex habits would expect. Do not
copy the Codex "headless runs no hooks" warning onto this harness.

Cloud Agents are the documented hard gap: they run **project**
(`.cursor/hooks.json`, in-repo) command hooks plus team/enterprise-managed hooks
on Enterprise plans, and **never** user-level hooks, `sessionStart`,
`sessionEnd`, MCP hooks, Tab hooks, `workspaceOpen`, or prompt-type hooks. Cloud
Agents also ignore Run Modes entirely. So in a Cloud Agent the `pre-edit-gate`
class degrades to **soft enforcement** — the capability bodies and `AGENTS.md`
still instruct the protocol, but nothing this build renders blocks a violation.
This is the design's documented fallback for a hook-less surface; for Cursor it
is reached **per surface**, not per harness. (An operator who wants the gate in
the cloud must commit a project-level `.cursor/hooks.json` into the target
repository — deliberately out of scope for a user-level render.)

**Workspace trust.** Project hooks run only in a **trusted workspace** (the
standard workspace-trust prompt; the CLI takes `--trust`). There is no
per-hook trust review step like Codex's `/hooks`. User-level `hooks.json` — what
this build writes — sits outside the workspace-trust question per the docs.
The live run passed `--trust` explicitly and used a **project** hooks file, so
it settled neither the prompting behavior without `--trust` nor whether an
untrusted workspace suppresses user-level hooks too — both stay **UNVERIFIED**
(U4).

## Fact 3 — Capability invocation convention and the gate marker

*(docs 2026-08-18, `skills.md` + `hooks.md`.)*

Cursor has **no `Skill` tool**. Skills are discovered from the skill roots and
their descriptions are presented to the agent, which decides when they are
relevant; a capability is also reachable explicitly by typing `/<name>` in Agent
chat. So the enforcement hook cannot detect a capability ran the way Claude's
hooks do (matching a `Skill` tool invocation in the transcript).

`preToolUse` input carries a `transcript_path`, and the transcript does exist:
JSONL under `<config>/projects/<slug>/agent-transcripts/<id>/<id>.jsonl`
(**live-verified 2026-08-18**). So a transcript-parsing marker — the Codex
approach — is *possible* on this harness. It is deliberately not used: the file
format is undocumented (an unannounced change would silently break the gate),
and the framework already has a marker channel three harnesses implement. The
gate therefore uses the **gate-file channel**, the portable marker Claude and
Hermes already share:

- The `session-agent` realization instructs the model to write its R5 routing
  declaration — including the `Linear gate:` and `Lessons:` lines — to
  `<config>/agentic-os/gate-<conversation_id>`.
- The hook allows exactly that write through pre-gate (structured match on the
  tool input: the gate path plus both declaration lines, line-anchored,
  case-sensitive, each requiring a non-empty value after the colon), then treats
  the file on disk as the open-gate marker for every later tool call in the same
  conversation.
- `conversation_id` is stable across turns of one conversation (docs
  2026-08-18), which is exactly the keying the marker needs. Stale markers older
  than 7 days are reaped on each run.

**Observed `preToolUse` payload (live-verified 2026-08-18).** A headless `Write`
delivered `tool_name`, `tool_input.file_path`, `tool_input.content`,
`tool_use_id`, `cwd`, `workspace_roots`, `session_id`, `conversation_id`, and
`transcript_path`. That settles the shape the hook actually sees today.

**Why the hook still matches schema-agnostically.** The corpus documents
`tool_input` concretely only for `Shell` (`{"command", "working_directory"}`),
so `file_path`/`content` is observed behavior, not a contract — an IDE-side
build or a future release could differ. The hook therefore matches over **every
string value in `tool_input`** (`jq '[.tool_input | .. | strings]'`): a call is
a gate-declaration write when some string carries the gate path, and the
declaration lines are sought across the joined strings. The verified keys are a
strict subset of that sweep, so the hook is correct today and shape-agnostic
tomorrow — and it degrades safely: a payload it cannot read produces a deny with
an explanatory `agent_message`, never a silent allow.

The marker is structural and name-keyed: a capability's `name` must not change
without updating the matching hook script.

## Fact 4 — Entrypoint filename & durable-memory location

*(docs 2026-08-18, `rules.md` + `cli/reference/configuration.md`.)*

- Cursor's plain-markdown instruction file is **`AGENTS.md`**, read from the
  project root and from nested subdirectories (nested files merge; most-specific
  wins). The build generates `<config>/AGENTS.md` from the template
  `harnesses/cursor/AGENTS.template.md`: the template is mostly hand-maintained
  prose, and the build resolves its `@@PLACEHOLDER@@` tokens and injects an
  `@@CAPABILITY_CATALOG@@` table derived from the `capabilities/` specs. The
  generated file is build output — never hand-edited.
- **How project-level pickup works.** The docs describe `AGENTS.md` discovery
  from the *project* tree. A **user-level** `<config>/AGENTS.md` is not
  documented as auto-loaded — see the UNVERIFIED block. The reliable
  project-level channel is to place (or symlink) a thin project `AGENTS.md` at a
  repository root that points into this checkout; the framework already ships
  exactly such a file at the root of this repository, and
  `playbooks/harness-entrypoints.md` covers the per-project pattern. The rendered
  `<config>/AGENTS.md` is the canonical global text either way: it is what a
  project entrypoint points at, and what the operator copies from.
- **Do not double-inject.** Cursor's Agent CLI also reads a project-root
  `CLAUDE.md` and applies it as rules alongside `AGENTS.md` and `.cursor/rules`
  (docs 2026-08-18). On a machine where the claude render already maintains a
  project `CLAUDE.md`, a project `AGENTS.md` carrying the same instructions
  would be injected twice. The cursor template is therefore deliberately
  **thin**: it orients, names the entrypoint chain, and states the spine
  contract — it does not restate what the claude render's `CLAUDE.md` already
  injects.
- **Rules directory.** `.cursor/rules/*.mdc` is the project-rule channel;
  plain `.md` files in `rules/` are **ignored** by Cursor. User Rules are stored
  in the app, not on disk, so they are not a render target. The build writes no
  rules — `AGENTS.md` is the framework's slot.
- **Durable memory.** Per the design's locked decisions the durable source of
  truth for lessons is the knowledge vault, not any harness-local store — the
  `closeout` capability routes lessons there.

## Fact 5 — Files the build must never touch

*(docs 2026-08-18, `reference/sandbox.md` + `cli/reference/configuration.md`.)*

- `cli-config.json` (Agent CLI settings: `permissions`, `approvalMode`,
  `sandbox`, `attribution`, display toggles) is **user-owned** and is not
  build-managed. Note for operators who commit from a Cursor session:
  `attribution.attributeCommitsToAgent` defaults **on**, adding a
  "Made with Cursor" trailer — turn it off where framework commits are
  identity-pinned.
- `permissions.json`, `sandbox.json`, and `mcp.json` are user/team-owned; the
  build writes none of them.
- Cursor's own agent can never write `.cursor/*.json` from inside a session
  (protected paths — `hooks.json`, `cli.json`, `sandbox.json` are tamper-proof
  from the model side, along with `.claude/*.json`, `.vscode/**`,
  `.git/hooks/**`, `.git/config`, `.cursorignore`). Writable exceptions are
  `.cursor/rules|commands|worktrees|skills|agents/`. This is a *helpful*
  property for the framework: the generated `hooks.json` cannot be edited away
  by an agent mid-session — but it also means an operator repairing the render
  must do so outside a Cursor session (or re-run `install.sh`).
- `<config>/.gitignore` carries a Cursor-managed block the app maintains — the
  build never writes there.

---

## Live verification (2026-08-18)

One headless run settled the load-bearing questions. Setup: macOS, Cursor Agent
CLI `2026.08.11-e8db854`, `agent -p --trust` against a scratch git repo carrying
a project-level `.cursor/hooks.json`, with marker-file and magic-token probes.
What it proved:

| # | Claim | Result |
| --- | --- | --- |
| V1 | Hooks fire in headless `agent -p --trust` | **Yes** — both `sessionStart` and `preToolUse` ran (marker-file proof) |
| V2 | `{"permission":"deny",…}` on `preToolUse` really blocks | **Yes** — the `Write` was stopped, the file was never created, and the agent surfaced `agent_message` |
| V3 | Tool name for a file edit | `Write`; payload carried `tool_input.file_path`, `tool_input.content`, `workspace_roots`, `session_id`, `conversation_id`, `transcript_path` |
| V4 | `sessionStart` `additional_context` reaches the model | **Yes** — magic token round-tripped; input is `{session_id, is_background_agent, composer_mode}`, fire-and-forget |
| V5 | Skill discovery, headless | Project `.cursor/skills/` **and** project `.claude/skills/` both discovered; negative control passed (a non-existent skill was NOT loaded, and the model enumerated exactly the planted set) |
| V6 | Transcripts exist on disk | JSONL under `<config>/projects/<slug>/agent-transcripts/<id>/<id>.jsonl` |
| V7 | `failClosed: true` on a crashed `preToolUse` hook | **Blocks** — marker-proven crash (empty stdout, exit 1) stopped the `Write`; see U1 |
| V8 | Same-name skill in `.cursor/skills/` vs `.claude/skills/` | Deterministic — the `.claude` copy shadows; one catalog entry; swapped-body re-run followed the directory; see U5 |
| V9 | `Delete` fires on `preToolUse` | **Yes** — `tool_name: "Delete"`, `tool_input.file_path` sometimes bare-relative; headless deletes additionally need the CLI's own `-f/--force`; see U6 |

Two consequences worth stating plainly, because they invert the intuition a
reader carrying Codex habits would bring:

- **The headless lane has full enforcement parity today.** Do not write, or
  copy over, a Codex-style "non-interactive runs no hooks" caveat here. On this
  harness the *interactive* surfaces are the unproven ones (U3).
- **Compat skill discovery is real, which makes coexistence the concern, not
  availability.** V5 shows a project `.claude/skills/` is loaded by Cursor. The
  build still renders a **native** `<config>/skills/` target — it is
  deterministic, manifest-tracked, and independent of a settings toggle — but if
  a project also carries a `.claude` render, only one copy is cataloged: the
  project `.claude/skills/` copy deterministically **shadows** the
  `.cursor/skills/` copy (U5, live-verified with swapped-body probes). The
  operating rule: keep the two renders' spine skills rendered from the same
  source — the drift gate already enforces this — so the shadowing is harmless.

## UNVERIFIED (documented gap)

Everything below is documented or expected behavior that the live run did
**not** settle. Each item states what is claimed, why it is still open, and how
to close it. Until an item is closed, do not report the corresponding claim as
proven.

### U1 — `failClosed: true` actually blocking on `preToolUse` — **RESOLVED: honored**

**Verdict (live-verified 2026-08-18, CLI 2026.08.11-e8db854, headless).** A
project-level `preToolUse` entry (`matcher: Write|Delete`,
`failClosed: true`) pointing at a script that appends a marker, prints
nothing, and exits 1 was exercised against a file-write request. The marker
proves the hook fired; the write was **blocked** and the agent reported the
rejection; the file was never created. A crash with empty stdout fails
closed on `preToolUse` when the entry sets `failClosed: true` — the generic
per-script option is honored on this event, not just on the
`beforeShellExecution`-family events the docs illustrate. The in-script
deny-on-error branch (Fact 2, layer 2) remains as defense in depth.
Re-probe on major Cursor releases.

### U2 — User-level `<config>/AGENTS.md` auto-discovery — **RESOLVED: NOT discovered**

**Verdict (live-verified 2026-08-18, CLI 2026.08.11-e8db854, headless).** A
sentinel token planted in `~/.cursor/AGENTS.md` was NOT visible to the agent in
a scratch project (`agent -p --trust` answered `NONE`), while the identical
probe phrasing surfaces tokens that ARE in context (the sessionStart-injection
sentinel from the same session was returned verbatim) — so the instrument can
detect a positive and the negative is real. User-level `<config>/AGENTS.md` is
**not** auto-discovered on this surface.

**Consequence (design question 2 decided).** The rendered `<config>/AGENTS.md`
is a **reference document**, not a live instruction channel. The AUTHORITATIVE
global channel for the spine is the `sessionStart` `additional_context`
injection (live-verified working, V4); project-root `AGENTS.md` remains
first-class for repos that opt in. The template's own framing states this.
Re-probe on major Cursor releases — an IDE-side or future build could change
discovery.

### U3 — Hook firing in the IDE and the interactive CLI

**Claim.** The enforcement-parity table lists the desktop IDE / Agent Chat and
the interactive `agent` TUI as hook-firing surfaces.

**Why it is open.** V1 proved the **headless** lane. The IDE runs a different
process with its own workspace-trust flow and its own settings toggles, and the
interactive TUI was not exercised. A surface that silently skips hooks would
disable the spine with no visible signal — the worst failure mode this adapter
has, and the reason this stays an explicit gap rather than an assumption.

**Reproduction recipe.** With the sandbox render active, append
`date >> /tmp/cursor-hook-fired` to the rendered
`hooks/framework-surface.sh`. (a) Open a workspace in the Cursor desktop app and
start a conversation; (b) run `agent` interactively in the same repo. Check the
marker after each. Then attempt a file edit before invoking `/session-agent` and
confirm the gate denies on each surface.

### U4 — Workspace trust without `--trust`, and user-level hooks

**Claim.** Fact 2 states user-level `hooks.json` is outside the workspace-trust
question; only project hooks require a trusted workspace.

**Why it is open.** The live run passed `--trust` explicitly and used a
**project** `.cursor/hooks.json`, so it settled neither half: not the prompting
behavior without `--trust`, and not whether an untrusted workspace also
suppresses **user-level** hooks. The docs say project hooks "require the
workspace to be trusted to run" and never say user hooks do — an argument from
silence.

**Reproduction recipe.** Open a freshly-cloned, never-trusted directory in
Cursor with the sandbox render active, decline the trust prompt, and start a
conversation; check whether the `sessionStart` marker (U3 step) is written.
Separately, run `agent -p` **without** `--trust` in an untrusted repo and record
what it prompts for and whether hooks fire. Written/fires → user hooks are
trust-independent. Otherwise the framework needs a loud "trust this workspace"
surfaced step, the same shape as the Codex `/hooks`-trust step `install.sh`
already prints.

### U5 — Skill precedence when a `.claude` render is also visible — **RESOLVED: deterministic; `.claude` shadows `.cursor`**

**Verdict (live-verified 2026-08-18, CLI 2026.08.11-e8db854, headless).** Two
same-named skills with distinguishable body tokens were planted under a
project's `.cursor/skills/` and `.claude/skills/`. The agent's catalog listed
the skill **once**, and the body it quoted was the **`.claude/skills/` copy**
— on both the original run and a token-swapped re-run, so the choice follows
the directory, not the content. Precedence is deterministic, and (counter to
intuition) the compat dir outranks the native dir at project level. This is
harmless as long as both renders come from the same source; the drift gate
enforces exactly that.

**User-level half.** On a machine whose Claude config dir is relocated via
`CLAUDE_CONFIG_DIR`, none of the relocated render's skills appeared in
Cursor's catalog, while the native `<config>/skills/` spine skills appeared
in the same listing (the positive control). A relocated claude render is
**invisible** to Cursor — confirming the reason the framework routes through
the native render, never through compat. Whether a *literal* `~/.claude/skills/`
would be compat-discovered at user level stays unprobed (no such dir on the
probe machine), and does not matter to the framework's channel choice.

### U6 — `Delete` as a `preToolUse` matcher value — **RESOLVED: fires; payload recorded**

**Verdict (live-verified 2026-08-18, CLI 2026.08.11-e8db854, headless).** A
logging pass-through hook on `matcher: Write|Delete` captured real `Delete`
events: `tool_name` is exactly `Delete`, and `tool_input` carries a
`file_path` — which was **absolute on some calls and bare-relative
(`victim.txt`) on others**, so the gate must never assume an absolute path
(the marker-path allow compares against an absolute path, so a relative
`file_path` can only fall through to deny — the safe direction). The payload
carries the same envelope fields as `Write` (`conversation_id`,
`hook_event_name`, `workspace_roots`, `cursor_version`, plus a `user_email`
field worth knowing about before shipping hook logs anywhere). The
`Write|Delete` matcher (panel fix A4) is therefore live coverage, not inert
breadth.

**Separate layer discovered.** In headless runs the CLI's own permission
layer rejects deletions (`File deletion rejected`) even when every hook
allows; `agent -p -f/--force` permits them. A hook allow does not override
that native layer — deny-wins composition across the hook layer and the
CLI's own permission config.

## Accepted limitations (documented, not fixed)

- **Ask-mode start loses the directive for that conversation.** `sessionStart`
  fires once per conversation; the surfacing hook suppresses the session-agent
  block in `ask` composer mode, and a later switch to Agent/Edit mode does not
  re-fire the event. Recovery is by design the gate itself: the first denied
  write carries the full declaration instructions, including the exact gate
  path.
- **A trusted project's hooks can outrank the user-level gate.** Cursor merges
  hook responses with project > user priority, so a repo-committed
  `.cursor/hooks.json` that answers `allow` on the same event can override the
  user-level deny. The gate is a discipline net, not a security boundary — same
  posture as every other harness realization, stated here because Cursor is the
  only harness where a repo can structurally outvote the user config.

## Open design questions

Not gaps in knowledge — decisions deliberately left for review:

1. **Should the gate also cover shell-driven mutation?** Cursor has a
   `beforeShellExecution` event whose matcher runs against the **command text**,
   so a targeted gate on write-shaped commands (`>`, `tee`, `rm`, `mv`,
   `install`) is possible without gating every shell call — an instrument the
   other three harnesses do not have. Not shipped: the matcher would be a
   heuristic on shell syntax, and the capability realization deliberately points
   the model at `Shell` as the fallback channel for writing the gate marker, so
   gating it needs a carve-out designed alongside it.
2. **DECIDED (U2 resolved negative, 2026-08-18).** User-level `AGENTS.md` is
   not discovered, so the authoritative global channel is the `sessionStart`
   `additional_context` injection (verified working); the rendered
   `<config>/AGENTS.md` stays as a reference document. A `.cursor/rules/*.mdc`
   `alwaysApply` render remains a possible future addition for IDE sessions if
   U3 verification shows the IDE needs a hook-independent channel.
3. **Should the build offer a project-level render?** Cloud Agents and the
   workspace-trust story both point at `.cursor/hooks.json` committed in-repo as
   the only channel that reaches every surface. That is a different product —
   per-repo, version-controlled, team-visible — and out of scope for a
   user-level install, but it is the natural next target if Cloud Agents matter.
4. **How should the cursor and claude renders coexist in one project?** V5 makes
   this concrete rather than theoretical: Cursor loads a project
   `.claude/skills/` too, so both renders' spine skills can be in the catalog at
   once. U5 has since shown precedence IS deterministic (the `.claude` copy
   shadows, only one is cataloged), which makes option (a) — leave it, with
   both renders built from the same source under the drift gate — the settled
   answer; (c) teach the cursor render to detect and warn remains a possible
   refinement. Nothing extra is shipped for it.

---

## Build path placeholders

Source files in `harnesses/cursor/` must contain no machine-absolute paths
(`scripts/check-drift.sh` enforces this repo-wide). Where a hook script or the
entrypoint template needs an absolute path, it uses a build placeholder that
`install.sh` substitutes from `local.env`. Placeholder convention: the token
name is the env-var name, so `@@NAME@@` resolves to `$NAME`. A path placeholder
in the entrypoint template whose variable is unset/empty **fails the build** — a
generated entrypoint must never carry an empty path.

| Placeholder | Substituted with |
| --- | --- |
| `@@AI_CONFIG_DIR@@` | Absolute path to this `agentic-os-template` checkout. |
| `@@CURSOR_CONFIG_DIR@@` | Absolute path to the Cursor config dir (build target). |
| `@@OBSIDIAN_VAULT_PATH@@` | Absolute path to the durable-knowledge vault. |
| `@@CAPABILITY_CATALOG@@` | Generated markdown table of the `capabilities/` specs (entrypoint template only). |

## Build output map (for `install.sh --harness cursor`)

| Source | Compiled output |
| --- | --- |
| `capabilities/<name>.md` + `harnesses/cursor/capabilities/<name>.md` | `<config>/skills/<name>/SKILL.md` |
| `harnesses/cursor/hooks/<name>.sh` | `<config>/hooks/<name>.sh` + a `hooks.json` hook block |
| generated hook blocks | `<config>/hooks.json` |
| `harnesses/cursor/AGENTS.template.md` + capability catalog | `<config>/AGENTS.md` |

`hooks.json` is fully generated and never hand-edited. `cli-config.json`,
`permissions.json`, `sandbox.json`, `mcp.json`, `commands/`, `agents/`, and
`rules/` are user-owned and are not touched by the build.

**Drift gate.** After any build,
`scripts/check-drift.sh --manifest "$CURSOR_CONFIG_DIR"` verifies the live output
against `.build-manifest.json`. A hand-edit to any generated file (`skills/`,
`hooks/`, `hooks.json`, `AGENTS.md`) is reported as drift. `check-drift.sh
--auto` runs the gate against this render via the `cursor:CURSOR_CONFIG_DIR`
pair; unset skips with a notice. Operator-authored `skills/` subdirs (Shape C)
are untracked by the manifest and preserved across re-renders, the same contract
every other harness render has.
