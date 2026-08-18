# Hermes Agent — Harness Adapter

This file is the **single declaration** of everything specific to the Hermes
Agent harness (Nous Research). The agnostic core (`core/`, `capabilities/`,
`verification/`, …) carries none of it. The build script (`scripts/install.sh`)
reads this adapter plus the `capabilities/` specs and compiles them into
Hermes's native format — run it with `install.sh --harness hermes`.

`harnesses/` is the **only** quarantined harness-specific zone in this
repository. Harness tool names, hook event names, and harness paths are
expected here and nowhere else (`scripts/check-drift.sh` denies the Hermes
token set in shared dirs).

Verified against **Hermes Agent v0.18.2** (2026-07-12) — hook wire shapes via
`hermes hooks doctor` synthetic-payload checks plus live spine sessions;
desktop-entrypoint behavior and the bridge plugin were verified on v0.16.0
(2026-06-10, live desktop session + source inspection) and dated in-body
citations record that baseline; edit-tool surface via a live CLI session. The build target
is the directory named by the `HERMES_HOME` environment variable in
`local.env`. Point it at a **dedicated profile directory** (e.g.
`~/.hermes/profiles/agentic-os`) for an isolated agentic-os brain, or at
`~/.hermes` to make the global install the brain — the build manages
`skills/` and `plugins/` per-subdir (operator-authored subdirs survive
re-renders) and `hooks/` + `SOUL.md` wholesale in whichever target it is
given, so a dedicated profile is the safe default. A profile isolates
config/memory/skills/sessions via `HERMES_HOME`, but is **NOT a filesystem
sandbox** — the local backend has full user-filesystem access, which is why
the edit-gate matcher includes `terminal`.

---

## Fact 1 — Skill file & frontmatter schema

Each capability compiles to one skill file at `<config>/skills/<name>/SKILL.md`.
Hermes discovers skills under `$HERMES_HOME/skills/` automatically and converts
each into a `/<name>` slash command. The format is the **agentskills.io open
standard** — the same `SKILL.md` shape Claude Code and Codex consume, so the
compiler emits one frontmatter shape for all four harnesses:

```yaml
---
name: <capability name>
description: <trigger-rich one-paragraph description>
---
```

- Harness-specific extensions live under `metadata.hermes.*` when needed; the
  spine capabilities need none.
- Claude's backtick-`!` mid-skill terminal injection does **not** port 1:1 —
  none of the 3 spine capabilities use it. A future capability that does needs
  a Hermes-side adaptation in its `harnesses/hermes/capabilities/<name>.md`
  realization.
- The skill body is the capability's harness-neutral body followed by the
  per-harness realization (`harnesses/hermes/capabilities/<name>.md`).

## Fact 2 — Hook events, enforcement classes, and config.yaml wiring

Hermes has three hook systems; this adapter uses **shell hooks** (the
Claude-Code-compatible system): a `hooks:` block in `config.yaml`, stdin JSON
carrying `hook_event_name` / `tool_name` / `tool_input` / `session_id` / `cwd`
plus an `extra` object of event-specific kwargs (e.g. `pre_llm_call` passes
`extra.is_first_turn`), and Claude-Code-style output. Events: `on_session_start`,
`on_session_end`, `on_session_finalize` / `on_session_reset`,
`pre/post_tool_call`, `pre/post_llm_call`, `subagent_stop`. Only
`pre_tool_call` blocks; `matcher:` (a tool-name regex) applies to
`pre/post_tool_call` only.

**Hook entry wire shape (re-verified against the bundled desktop source,
build 2026-08-18).** Each `hooks:` entry is parsed into `ShellHookSpec`
(`agent/shell_hooks.py`) whose fields are `command` / `matcher` / `timeout` /
`fail_closed` — `command` is **ONE string**, split into argv via
`shlex.split(os.path.expanduser(command))` with `shell=False`. There is **no
`args:` key**: an `args:` list in a hook entry is silently ignored, leaving
only the bare `command` value as the whole argv — the hook then never runs
(`hermes hooks doctor`: "script missing or not executable"). Interpreter
prefixes inside the single string are fine (the script itself needs only read
permission), which is how the Windows render wires `.ps1` hooks:
`command: "pwsh -NoProfile -File '<abs>/hooks/<x>.ps1'"`. Because the string is
shlex-split, any path segment containing a space or apostrophe must be
POSIX-single-quoted inside the YAML double-quoted scalar — both generators do
this (`hermes_hook_command_yaml` in install.sh, `Get-HermesHookCommandYaml` in
install.ps1). An earlier revision of this adapter assumed the Claude-Code
`command` + `args:` shape; that was never valid.

**Hook decision formats (verified v0.16.0).** A `pre_tool_call` block emits the
legacy Claude-Code shape `{"decision":"block","reason":"…"}` — Hermes parses it
natively into its wire shape (`{"action":"block","message":"…"}`).

**Context injection — which events actually inject (verified against the Hermes
source, v0.16.0).** A hook returning `{"context":"…"}` only reaches the model on
**`pre_llm_call`**: `turn_context.py` collects each `pre_llm_call` hook's
`context` and appends it to the **user message** (never the system prompt), once
per model call. **`on_session_start` is fire-and-forget** — `conversation_loop.py`
invokes it but DISCARDS the return, so a `{"context":…}` emitted there never
reaches the model (the event is meant for side effects like cache warming). This
is the trap that silently broke session-agent auto-fire on every model and
entrypoint: the surfacing hook must ride `pre_llm_call`, gated to the first turn.
Verify end-to-end by the model's BEHAVIOR (it invokes `/session-agent`), **not**
by grepping `state.db`: `pre_llm_call` context is injected into the ephemeral
API-call message and is NOT persisted to the transcript, so a transcript grep
shows nothing even when injection works. `hermes hooks test` only proves the hook
*emits* valid JSON, not that Hermes injects it — confirm by behavior, or by
asking the model to echo back its injected context verbatim.

**Enforcement-class → hook mapping.**

| Enforcement class | Hook event | `matcher` | Hook script | Behavior |
| --- | --- | --- | --- | --- |
| `pre-edit-gate` | `pre_tool_call` | `write_file\|patch\|terminal` | `hooks/session-agent.sh` | Blocks the first file-modifying tool use until session-agent ran and a complete routing declaration (`Linear gate:` + `Lessons:` lines) exists. `terminal` is in the matcher because the shell can write files (the Bash-bypass). Safety net; primary auto-fire is the `pre_llm_call` directive in `framework-surface.sh` (see the Fact 2 context-injection note). |

**Gate detection (Hermes-specific).** Hermes persists transcripts in
`$HERMES_HOME/state.db` (SQLite `messages(session_id, role, content)` — schema
pinned at v0.16.0), not in per-session files, and mid-turn assistant text may
not be persisted before `pre_tool_call` fires. The gate therefore uses a
**per-session gate file**: the session-agent realization instructs the model to
write its R5 routing declaration (including the `Linear gate:` and `Lessons:`
lines) to `$HERMES_HOME/agentic-os/gate-<session_id>` via `write_file`; the
hook allows exactly that structured write through pre-gate and treats the file
as the open-gate marker. A read-only `state.db` query (skill-read marker +
`Linear gate:` + `Lessons:` lines) is the multi-turn backstop when `sqlite3`
is available.

**Non-capability hook.** `hooks/framework-surface.sh` runs on **`pre_llm_call`**
(no matcher — matchers apply to tool-call events only) and surfaces recent
framework commits, a config-freshness nudge, and the session-agent invocation
directive as `{"context": …}`. Because `pre_llm_call` fires before every model
call, the hook self-gates to the session's first turn via `extra.is_first_turn`
(falling back to a per-session sentinel under `$HERMES_HOME/agentic-os/` only if
that signal is ever absent), so the directive injects exactly once. Wired
unconditionally by the build.

**`config.yaml` is user-owned — wiring is a surfaced manual step.** The build
cannot write `config.yaml` (it carries operator model/provider/platform
config). Instead it generates `<config>/hooks/hooks.yaml` — the exact `hooks:`
+ `plugins.enabled` block to merge — and prints the step. Consent is also
Hermes-native: shell hooks require first-use approval (TTY prompt,
`--accept-hooks`, or `hooks_auto_accept: true`), recorded mtime-pinned in
`$HERMES_HOME/shell-hooks-allowlist.json`. **Re-running install.sh rewrites the
hook scripts and therefore invalidates prior consent** — re-approve on the
next CLI run.

**Desktop-app gap + the bridge plugin (verified v0.16.0).** Shell-hook
*registration* happens only in the CLI entrypoints and the messaging gateway —
the desktop app's dashboard entrypoint never calls it, so `config.yaml` shell
hooks silently do not fire in GUI sessions. Hook *dispatch* is engine-level
(the plugin manager), and plugins DO load in the desktop process, so the build
ships the **`agentic-os-hook-bridge`** plugin
(`harnesses/hermes/plugins/agentic-os-hook-bridge/`): its `register()` calls
the same registration entrypoint, restoring hook *registration* — and thus the
engine-level `pre_tool_call` / `pre_llm_call` dispatch that runs inside the
shared turn loop — in the desktop app. Note the session-*lifecycle* events
(`on_session_start` / `on_session_end`) are emitted by the entrypoint, not the
engine, so the bridge does not resurrect them in the GUI — a second reason the
surfacing hook rides `pre_llm_call` (which every entrypoint dispatches) rather
than `on_session_start`. Idempotent (double-registration is a no-op) and
consent-preserving (the allowlist still gates; nothing is auto-approved). The
plugin must be enabled via `plugins.enabled` in `config.yaml` — part of the same
surfaced manual step.

**`jq` runtime contract.** Same split as the other harnesses: the **gate**
hook fails **closed** without `jq` (static legacy block shape — natively
parsed); the **surfacing** hook fails **open** (silent).

## Fact 3 — Capability invocation convention

Capabilities are invoked as `/<name>` slash commands; Hermes injects the
`SKILL.md` body into the conversation. There is no `Skill` tool, so the
enforcement hook cannot match a tool call. Detection is two-channel (Fact 2):
the per-session gate file (primary, mid-turn-safe) and the `state.db`
skill-read marker `skills/session-agent/SKILL.md` (backstop). The marker is
structural and name-keyed — a capability's `name` must not change without
updating the matching hook script.

## Fact 4 — Entrypoint file & durable-memory location

- The global instruction entrypoint is **`SOUL.md`** at `$HERMES_HOME/SOUL.md`
  — Hermes loads it as identity slot #1 of the system prompt. The build
  generates it from `harnesses/hermes/SOUL.template.md` (placeholders +
  `@@CAPABILITY_CATALOG@@`). Project-level `CLAUDE.md` / `AGENTS.md` files are
  auto-discovered from the working directory (top-level only, ~100 KB cap with
  head/tail truncation) and compose with it — the same project entrypoints the
  Claude/Codex installs already maintain, so per-project parity is automatic.
- Hermes's native memory (`$HERMES_HOME/memories/` — `MEMORY.md`, hard
  2,200-char cap, + `USER.md`, frozen-snapshot-injected at session start) is a
  **local cache** under the framework cache contract
  (`core/memory-model.md`): the durable source of truth for lessons is the
  knowledge vault; `closeout` routes lessons there. The build never touches
  `memories/`.

---

## Build path placeholders

| Placeholder | Substituted with |
| --- | --- |
| `@@AI_CONFIG_DIR@@` | Absolute path to this `agentic-os-template` checkout. |
| `@@HERMES_HOME@@` | Absolute path to the Hermes config dir / profile (build target). |
| `@@OBSIDIAN_VAULT_PATH@@` | Absolute path to the durable-knowledge vault. |
| `@@CAPABILITY_CATALOG@@` | Generated markdown table of the `capabilities/` specs (entrypoint template only). |

## Build output map (for `install.sh --harness hermes`)

| Source | Compiled output |
| --- | --- |
| `capabilities/<name>.md` + `harnesses/hermes/capabilities/<name>.md` | `<config>/skills/<name>/SKILL.md` |
| `harnesses/hermes/hooks/<name>.sh` | `<config>/hooks/<name>.sh` + an entry in the generated `hooks/hooks.yaml` snippet |
| generated hook wiring | `<config>/hooks/hooks.yaml` (copy-paste snippet — `config.yaml` itself is user-owned) |
| `harnesses/hermes/plugins/agentic-os-hook-bridge/` | `<config>/plugins/agentic-os-hook-bridge/` |
| `harnesses/hermes/SOUL.template.md` + capability catalog | `<config>/SOUL.md` |

**Surfaced manual steps after a build** (install.sh prints them):

1. Merge the generated `hooks/hooks.yaml` block into `$HERMES_HOME/config.yaml`
   (`hooks:` + `plugins.enabled`).
2. Approve the hooks on first use (`hermes --accept-hooks` once, or answer the
   TTY consent prompt; `hermes hooks list` shows consent state). Re-runs of
   install.sh re-render the scripts and require re-approval.

**Drift gate.** After any build,
`scripts/check-drift.sh --manifest "$HERMES_HOME"` verifies the live output
against `.build-manifest.json`. A hand-edit to any generated file (`skills/`,
`hooks/`, `plugins/`, `SOUL.md`) is reported as drift. `config.yaml`,
`memories/`, `sessions/`, and `state.db` are user-owned and never
build-managed.
