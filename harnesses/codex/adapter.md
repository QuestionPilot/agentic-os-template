# Codex CLI — Harness Adapter

This file is the **single declaration** of everything specific to the Codex CLI
harness. The agnostic core (`core/`, `capabilities/`, `verification/`, …) carries
none of it. The build script (`scripts/install.sh`) reads this adapter plus the
`capabilities/` specs and compiles them into Codex's native format — run it with
`install.sh --harness codex`.

`harnesses/` is the **only** quarantined harness-specific zone in this repository.
Harness tool names, hook event names, and harness paths are expected here and
nowhere else.

Verified against **Codex CLI v0.132.0**. The build target is the directory named
by the `CODEX_HOME` environment variable. Codex itself defaults `CODEX_HOME` to
`~/.codex`, but `install.sh` requires it to be set explicitly in `local.env` — the
build does not assume the default.

> **Scope note (M5.4).** This adapter
> ships the **3 native** capabilities (`session-agent`, `closeout`, `self-audit`) — the spine
> per the 3-shape
> skill model. `route` + `skill-orchestrator` were consolidated into
> `session-agent`.
> `cross-model-review` was removed from agentic-os-template and now lives as a
> Shape C operator-local skill in each operator's harness config dir, never in
> the framework. Any ex-vendored tool capabilities are operator-managed Shape C if retained at `$CLAUDE_CONFIG_DIR/skills/<name>/`.
> agentic-os-template now authors exactly 3 spine capabilities × 3 harnesses
> (claude, codex, hermes; symmetric 3/3).

---

## Fact 1 — Skill file & frontmatter schema

Each capability compiles to one skill file at `<config>/skills/<name>/SKILL.md`,
where `<config>` is the directory named by the `CODEX_HOME` environment variable.
Codex discovers skills under `$CODEX_HOME/skills/` automatically (its own bundled
skills live at `$CODEX_HOME/skills/.system/`).

`SKILL.md` begins with YAML frontmatter:

```yaml
---
name: <capability name>
description: <trigger-rich one-paragraph description — derived from the capability
             header's summary + triggers; this is what Codex matches on to decide
             relevance>
allowed-tools: <comma-separated tool list, when the capability restricts tools>
---
```

- Codex requires `name` + `description`; it also accepts `metadata`, `license`,
  and `allowed-tools`. This is effectively the same schema as Claude Code's
  `SKILL.md`, so the compiler emits one frontmatter shape for both harnesses.
- The build keeps `description` concise — the same ~1536-char ceiling the
  compiler warns at for Claude applies as a portability guard.
- The skill body is the capability's harness-neutral body followed by the
  per-harness realization (`harnesses/codex/capabilities/<name>.md`).
- `allowed-tools`, when a capability restricts tools, is declared as optional
  YAML frontmatter at the top of `harnesses/codex/capabilities/<name>.md` (the
  per-harness realization). The build lifts it into the generated `SKILL.md`
  frontmatter and strips it from the concatenated body.
- Vendored capabilities (`kind: vendored`) are out of scope for the Codex target
  in M5.4 — see the scope note above.

## Fact 2 — Hook events, enforcement classes, and the hooks.json block

Codex's hook system runs hooks at named lifecycle events and, per the v0.132
docs and config schema, **can block** at them in the interactive `codex` TUI —
it is not a prose-only harness. (Interactive blocking is documented but not yet
verified end-to-end here; `codex exec` does not fire hooks at all — see the
enforcement-parity note at the end of this Fact.) Events: `SessionStart`,
`PreToolUse`, `PermissionRequest`,
`PostToolUse`, `UserPromptSubmit`, `Stop`. Hooks are wired in a dedicated,
fully-generated `<config>/hooks.json`. Each entry has this shape:

```json
{
  "hooks": {
    "<EventName>": [
      {
        "matcher": "<tool-name regex, or empty/'*' for all>",
        "hooks": [
          { "type": "command", "command": "<absolute path to script>", "timeout": 10 }
        ]
      }
    ]
  }
}
```

This is structurally identical to Claude Code's `settings.json` `hooks` object —
the compiler emits the same block, written to a standalone `hooks.json` instead
of merged into a settings file. Codex auto-loads `$CODEX_HOME/hooks.json`.
`config.toml` is **user-owned** (personality, trust, projects) and is *not*
build-managed; `[features] hooks = true` is Codex's default, so no `config.toml`
change is needed.

**Enforcement-class → hook mapping.** A capability header only *names* an
enforcement class. This adapter maps each class to a real, hand-written hook
script in `harnesses/codex/hooks/`:

| Enforcement class | Hook event | `matcher` | Hook script | Behavior |
| --- | --- | --- | --- | --- |
| `pre-edit-gate` | `PreToolUse` | `apply_patch` | `hooks/session-agent.sh` | Blocks the first file-modifying tool use until the session-agent capability has run and a `Linear gate:` line was declared. Codex file edits report `tool_name: "apply_patch"`. Safety net; primary auto-fire is the SessionStart directive in `framework-surface.sh`. |

(The `session-end-gate` class — a `Stop` hook for `closeout` — was removed;
`closeout` is now manual-fire. `pre-edit-gate` is the only
capability-declared enforcement class today.)

The build copies the named hook script into place and merges its `hooks.json`
block. Enforcement is **never code-generated** — the scripts are real files.

**Hook decision formats.** A `PreToolUse` block uses
`{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny",
"permissionDecisionReason":"…"}}` **or** the legacy top-level
`{"decision":"block","reason":"…"}` form (or a hard `exit 2` with the reason on
stderr) — Codex honors **both** shapes on `PreToolUse`. This is a genuine
**divergence from Claude Code**, where the legacy top-level `decision` is silently
ignored on `PreToolUse` (only `hookSpecificOutput.permissionDecision` blocks — a
documented Codex `PreToolUse` defect). **Verified against Codex CLI v0.132.0** (2026-06-06) from three
independent sources: (1) the bundled Rust binary's embedded
`pre-tool-use.command.output` JSON schema declares `decision` (enum `approve|block`,
via `PreToolUseDecisionWire`) and `reason` as first-class **top-level** properties
of the PreToolUse output wire, *alongside* the nested
`hookSpecificOutput.permissionDecision` (enum `allow|deny|ask`); (2) the source
parser `codex-rs/hooks/src/engine/output_parser.rs::parse_pre_tool_use` falls back
to `decision == Block` (with a non-empty top-level `reason`) to block when no
`hookSpecificOutput` permission decision is present; (3) the official hooks docs
(`developers.openai.com/codex/hooks`) state Codex "also accepts this older block
shape." So the Codex twin's legacy fail-closed emission (Fact 2 `jq` contract below)
genuinely blocks — do **not** retrofit the Claude fix for that defect onto it. Context
injection uses `hookSpecificOutput.additionalContext`, or plain stdout for
`SessionStart` and `UserPromptSubmit`.

**Non-capability hook.** One hook is a standalone harness feature, not tied to
any capability: `hooks/framework-surface.sh` runs on `SessionStart`
(`matcher: "startup|clear|compact"`) and surfaces two context blocks as
`additionalContext`: (a) recent `agentic-os-template` framework commits, and (b) the
session-agent invocation directive (the auto-fire mechanism for the
spine capability — see `capabilities/session-agent.md` Mode 1). The build
wires it unconditionally.

**Kickoff reconciliation contract.** The hook's commit window is the freshness
signal at session start; memory captures what was true when written, the
commit log captures what is true now. The contract that requires the model
to cross-reference workspace-prefix issue identifiers (`<PREFIX>-<number>`,
where `<PREFIX>` is the workspace's tracker prefix — `TEAM` is only the
documentation placeholder) in the surfaced commits against memory
headlines for the same project (flagging contradictions when a project memory
says `COMPLETE` but recent commits still reference its issues) lives in the
`session-agent` capability's Mode 1 orient — specifically sub-step O2,
`capabilities/session-agent.md`. This is a model-behavior contract documented
in the capability body, not a new hook behavior.

**`jq` runtime contract.** Every hook script needs `jq` on the hook PATH. The
behavior when `jq` is absent is split by hook role: the **gate** hook
(`session-agent.sh`) fails **closed** — it emits a block decision,
so a broken environment cannot silently disable enforcement; the **surfacing** hook
(`framework-surface.sh`) fails **open** — it exits silently, since missing
injected context is not a safety risk. `session-agent.sh`'s `deny()` helper
itself needs `jq`, so the fail-closed path emits the legacy
`{"decision":"block"}` shape as a static string — which (per the **Hook decision
formats** verification above) genuinely blocks on Codex `PreToolUse`, unlike Claude
Code, whose twin's fail-closed path must use the
`hookSpecificOutput.permissionDecision` shape. The per-gate kill switches
still bypass the gate before the `jq` check is reached.

**Hook trust — a required manual step.** Codex does not run a non-managed
`hooks.json` until the user explicitly **trusts** it. After `install.sh` writes
`$CODEX_HOME/hooks.json`, the user must run the interactive `/hooks` command once
to review and trust the generated hooks; the trust decision is persisted. The
build cannot trust hooks on the user's behalf — `install.sh` surfaces this as a
manual step, and the bootstrap smoke test calls it out. Hook trust only applies
to the interactive TUI; `codex exec` does not run `hooks.json` hooks at all
(verified — see the enforcement-parity note below), so its
`--dangerously-bypass-hook-trust` flag changes nothing about hook firing.

**Enforcement parity — interactive TUI only.** The framework's design
anticipated a harness with *no* lifecycle interception, on which a hard hook
gate would degrade to a strong instruction in the entrypoint and the build
would emit a loud warning.
Codex CLI v0.132's blocking hook system reaches **enforcement parity with Claude
Code in the interactive `codex` TUI** — and only there.

**`codex exec` runs no hooks (verified).** Non-interactive `codex exec` does
*not* fire `hooks.json` hooks. This was confirmed empirically against v0.132: a
minimal marker-writing hook never ran across repeated `codex exec` invocations,
including with `--enable hooks` and `--dangerously-bypass-hook-trust`. The
official docs are silent on exec-mode hooks; hook firing appears to be
interactive-TUI-only. So under `codex exec` the `pre-edit-gate` enforcement
class degrades to **soft enforcement** — the capability bodies and `AGENTS.md`
still instruct the protocol, but nothing blocks a violation. This is exactly the
design's documented fallback for a hook-less harness; for Codex it is reached
**per run mode**, not per harness.

**Interactive `codex` TUI hook firing — UNVERIFIED (documented gap).** The
v0.132 docs and config schema state hooks block in the interactive TUI, and the
build emits a trusted `hooks.json` for it, but this has **not** been confirmed
end-to-end — it cannot be exercised headlessly (no automated test can drive an
interactive TUI). Treat TUI enforcement as *expected but unproven* until a live
session verifies it. Reproduction recipe:

1. `bash scripts/install.sh --harness codex --out /tmp/codex-verify` — a sandbox
   `CODEX_HOME`, so `~/.codex` is not clobbered.
2. Launch `codex` against a scratch git repo with `CODEX_HOME=/tmp/codex-verify`.
3. Run the interactive `/hooks` command once to review and **trust** the
   generated `hooks.json`.
4. `pre-edit-gate` — attempt an `apply_patch` edit before invoking `session-agent` →
   expect a `PreToolUse` **deny**.

This is pending verification. Once verified, replace this note with the confirmed
result.

## Fact 3 — Capability invocation convention

Codex has **no `Skill` tool**. Skills are discovered from `$CODEX_HOME/skills/`
and their descriptions are injected into context (implicit invocation is on by
default); a capability is also reachable explicitly as `$<name>`. When a
capability is invoked, Codex reads its `SKILL.md` body on demand via a shell
command.

Because there is no `Skill`-tool call, the enforcement hooks cannot detect a
capability ran the way Claude's hooks do (matching a `Skill` invocation in the
transcript). Instead, the Codex hooks detect a capability ran by matching the
literal substring **`skills/<name>/SKILL.md`** in the session transcript — the
capability's body was read. This marker is structural and name-keyed, so a
capability's `name` must not change without updating the matching hook script.

## Fact 4 — Entrypoint filename & durable-memory location

- The harness instruction entrypoint is `AGENTS.md`. The global entrypoint is
  `$CODEX_HOME/AGENTS.md`; Codex also merges a project-root → CWD chain of
  `AGENTS.md` files, with a combined ~32 KB cap. The build generates the global
  `AGENTS.md` from the template `harnesses/codex/AGENTS.template.md`: the
  template is mostly hand-maintained prose, and the build resolves its
  `@@PLACEHOLDER@@` tokens and injects an `@@CAPABILITY_CATALOG@@` table derived
  from the `capabilities/` specs. The generated file is build output — never
  hand-edited. Keep the template well under the 32 KB cap.
- Codex keeps a `$CODEX_HOME/memories/` folder. Per the design's locked decisions
  the durable source of truth for lessons is the knowledge vault, not any
  harness-local memory folder — the `closeout` capability routes lessons to the
  vault.

---

## Build path placeholders

Source files in `harnesses/codex/` must contain no machine-absolute paths
(`scripts/check-drift.sh` enforces this repo-wide). Where a hook script or the
entrypoint template needs an absolute path, it uses a build placeholder that
`install.sh` substitutes from `local.env`. Placeholder convention: the token
name is the env-var name, so `@@NAME@@` resolves to `$NAME`. A path placeholder
in the entrypoint template whose variable is unset/empty **fails the build** — a
generated entrypoint must never carry an empty path.

| Placeholder | Substituted with |
| --- | --- |
| `@@AI_CONFIG_DIR@@` | Absolute path to this `agentic-os-template` checkout. |
| `@@CODEX_HOME@@` | Absolute path to the Codex config dir (build target). |
| `@@OBSIDIAN_VAULT_PATH@@` | Absolute path to the durable-knowledge vault. |
| `@@CAPABILITY_CATALOG@@` | Generated markdown table of the `capabilities/` specs (entrypoint template only). |

## Build output map (for `install.sh --harness codex`)

| Source | Compiled output |
| --- | --- |
| `capabilities/<name>.md` + `harnesses/codex/capabilities/<name>.md` | `<config>/skills/<name>/SKILL.md` |
| `harnesses/codex/hooks/<name>.sh` | `<config>/hooks/<name>.sh` + a `hooks.json` hook block |
| generated hook blocks | `<config>/hooks.json` |
| `harnesses/codex/AGENTS.template.md` + capability catalog | `<config>/AGENTS.md` |

`hooks.json` is fully generated and never hand-edited. `config.toml` is
user-owned and is not touched by the build.

**Drift gate.** After any build, `scripts/check-drift.sh --manifest "$CODEX_HOME"`
verifies the live output against `.build-manifest.json`. A hand-edit to any
generated file (`skills/`, `hooks/`, `hooks.json`, `AGENTS.md`) is reported as
drift.

**`.agents` co-render (Gemini overlay).** When `AGENTS_DIR` is set in
`local.env`, the codex build additionally mirrors its compiled spine skills
into `<AGENTS_DIR>/skills/` byte-identically and writes an `"agents"`-labeled
manifest there (`install.sh` `corender_agents` / `install.ps1`
`Invoke-AgentsCorender`). Rationale: Codex ≥0.14x discovers repo-root
`.agents/skills` alongside `$CODEX_HOME/skills`, so a divergent same-name copy
makes which-skill-wins ambiguous; byte-identity keeps the duplication harmless
while Gemini (agy/Antigravity) keeps its workspace skills. Non-spine subdirs in
the overlay are operator content — preserved, never clobbered, exempt from the
manifest gate (the same Shape C contract as `$CODEX_HOME/skills`).
`check-drift.sh --auto` runs the manifest gate against the overlay via the
`agents:AGENTS_DIR` pair; unset skips with a notice.
