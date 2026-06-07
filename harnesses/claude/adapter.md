# Claude Code — Harness Adapter

This file is the **single declaration** of everything specific to the Claude Code
harness. The agnostic core (`core/`, `capabilities/`, `verification/`, …) carries
none of it. A build script (`scripts/install.sh`, added in M5.2) reads this
adapter plus the `capabilities/` specs and compiles them into Claude Code's native
format.

`harnesses/` is the **only** quarantined harness-specific zone in this repository.
Harness tool names, hook event names, and harness paths are expected here and
nowhere else.

**Multi-harness build (as of M5.4).** The build is no longer Claude-only:
`install.sh --harness <name>` compiles the same `capabilities/` specs against the
adapter under `harnesses/<name>/`. `--harness claude` is the default and uses
this file; a sibling adapter `harnesses/codex/adapter.md` declares the Codex CLI
target. Each harness names its build target via a different env var in
`local.env` — `CLAUDE_CONFIG_DIR` here, `CODEX_HOME` for Codex. The two adapters
are independent declarations; nothing in this file is shared with Codex's, and
the agnostic core stays harness-neutral.

---

## Fact 1 — Skill file & frontmatter schema

Each capability compiles to one skill file at
`<config>/skills/<name>/SKILL.md`, where `<config>` is the directory named by the
`CLAUDE_CONFIG_DIR` environment variable.

`SKILL.md` begins with YAML frontmatter:

```yaml
---
name: <capability name>
description: <trigger-rich one-paragraph description — derived from the capability
             header's summary + triggers; this is what the harness router matches on>
allowed-tools: <comma-separated tool list, when the capability restricts tools>
---
```

- `description` is capped at roughly 1536 characters by the harness router
  (`skillListingMaxDescChars`) — content past the cap is silently dropped, so the
  build must keep descriptions within it.
- The skill body is the capability's harness-neutral body followed by the
  per-harness realization (`harnesses/claude/capabilities/<name>.md`).
- `allowed-tools`, when a capability restricts tools, is declared as optional YAML
  frontmatter at the top of `harnesses/claude/capabilities/<name>.md` (the
  per-harness realization). It is harness-specific — Claude tool names — so it
  cannot live in the agnostic `capabilities/` header. The build lifts it into the
  generated `SKILL.md` frontmatter and strips it from the concatenated body.
- Vendored capabilities (`kind: vendored`) are **not** compiled from a neutral
  body — their existing skill directory is installed as-is. See
  `harnesses/claude/capabilities/<name>.md` for each one's live location.

## Fact 2 — Hook events, enforcement classes, and the settings block

Claude Code runs hooks at named lifecycle events. Hooks are wired in
`settings.json` under a top-level `hooks` key. Each entry has this shape:

```json
{
  "hooks": {
    "<EventName>": [
      {
        "matcher": "<tool-name regex, or empty>",
        "hooks": [
          { "type": "command", "command": "<absolute path to script>", "args": [], "timeout": 10 }
        ]
      }
    ]
  }
}
```

Notes that have bitten past sessions:
- `args: []` is required when the command path contains spaces.
- Any event entry needs a `matcher` key (use `""` when none) and the nested
  `hooks` array.
- Saving `settings.json` mid-session hot-reloads hooks — they apply on the next
  matching tool call, no restart.

**Enforcement-class → hook mapping.** A capability header only *names* an
enforcement class. This adapter maps each class to a real, hand-written hook
script in `harnesses/claude/hooks/`:

| Enforcement class | Hook event | `matcher` | Hook script | Behavior |
| --- | --- | --- | --- | --- |
| `pre-edit-gate` | `PreToolUse` | `Write\|Edit\|NotebookEdit` | `hooks/session-agent.sh` | Blocks the first file-modifying tool use until the session-agent capability has run and a `Linear gate:` line was declared. Safety net; primary auto-fire is the SessionStart directive in `framework-surface.sh`. |

(The `session-end-gate` class — a `Stop` hook for `closeout` — was removed in
<TEAM>-211; `closeout` is now manual-fire. `pre-edit-gate` is the only
capability-declared enforcement class today.)

The build copies the named hook script into place and merges its `settings.json`
block. Enforcement is **never code-generated** — the scripts are real files.

**Non-capability hook.** One hook is a standalone harness feature, not tied to any
capability: `hooks/framework-surface.sh` runs on `SessionStart`
(`matcher: "startup|clear|compact"`) and surfaces three context blocks as
`additionalContext`: (a) recent `ai-config` framework commits, (b) the
<TEAM>-59 MCP-health probe, and (c) the <TEAM>-71 session-agent invocation directive
(the auto-fire mechanism for the spine capability — see
`capabilities/session-agent.md` Mode 1). The build wires it unconditionally.

**Kickoff reconciliation contract.** The hook's commit window is the freshness
signal at session start; memory captures what was true when written, the
commit log captures what is true now. The contract that requires the model
to cross-reference `QUE-\d+` patterns in the surfaced commits against memory
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
injected context is not a safety risk. The per-gate kill switches still bypass
the gate before the `jq` check is reached.

**Soft-enforcement note.** Hooks are *hard* enforcement — they synchronously block
or inject. Harnesses without lifecycle interception cannot hard-enforce; on those
the same enforcement class degrades to a strong instruction. The build must emit a
loud warning whenever a capability declares enforcement a target harness cannot
hard-enforce.

## Fact 3 — Capability invocation convention

Claude Code invokes a capability through the **`Skill` tool**, with the
capability's `name` as the argument. A capability is also reachable as the slash
command `/<name>`. Enforcement hooks detect that a capability ran by matching a
`Skill` invocation of that name in the session transcript — so a capability's
`name` must not change without updating the matching hook script.

## Fact 4 — Entrypoint filename & durable-memory location

- The harness instruction entrypoint is `CLAUDE.md` (in `CLAUDE_CONFIG_DIR` for
  the global entrypoint; in a repo root for project entrypoints). The build
  generates the global `CLAUDE.md` and the skill catalog `SKILLS.md` from the
  templates `harnesses/claude/CLAUDE.template.md` and `SKILLS.template.md`. Each
  template is mostly hand-maintained prose (the rich routing tables and
  marketplace-skill inventory are not derivable from the capability set); the
  build resolves its `@@PLACEHOLDER@@` tokens and injects an
  `@@CAPABILITY_CATALOG@@` table derived from the `capabilities/` specs. Both
  generated files are build output — never hand-edited.
- The harness keeps a per-project auto-memory folder under `CLAUDE_CONFIG_DIR`
  (`projects/<project-slug>/memory/`, indexed by `MEMORY.md`). Per the design's
  locked decisions this folder is a **disposable cache** — the durable source of
  truth for lessons is the knowledge vault, not this folder.

---

## Build path placeholders

Source files in `harnesses/claude/` must contain no machine-absolute paths
(`scripts/check-drift.sh` enforces this repo-wide). Where a hook script or an
entrypoint template needs an absolute path, it uses a build placeholder that
`install.sh` substitutes from `local.env`. Placeholder convention: the token
name is the env-var name, so `@@NAME@@` resolves to `$NAME`. A path placeholder
in an entrypoint template whose variable is unset/empty **fails the build** — a
generated entrypoint must never carry an empty path.

| Placeholder | Substituted with |
| --- | --- |
| `@@AI_CONFIG_DIR@@` | Absolute path to this `ai-config` checkout. |
| `@@CLAUDE_CONFIG_DIR@@` | Absolute path to the harness config dir (build target). |
| `@@OBSIDIAN_VAULT_PATH@@` | Absolute path to the durable-knowledge vault. |
| `@@CAPABILITY_CATALOG@@` | Generated markdown table of the `capabilities/` specs (entrypoint templates only). |

## Build output map (for `install.sh`, M5.2)

| Source | Compiled output |
| --- | --- |
| `capabilities/<name>.md` + `harnesses/claude/capabilities/<name>.md` | `<config>/skills/<name>/SKILL.md` |
| `harnesses/claude/hooks/<name>.sh` | `<config>/hooks/<name>.sh` + a `settings.json` hook block |
| `harnesses/claude/settings.base.json` + generated hook blocks | `<config>/settings.json` |
| `harnesses/claude/CLAUDE.template.md` + capability catalog | `<config>/CLAUDE.md` |
| `harnesses/claude/SKILLS.template.md` + capability catalog | `<config>/SKILLS.md` |

`settings.json` is fully generated and never hand-edited. User-owned settings live
in `harnesses/claude/settings.base.json`; the build merges generated hook blocks
into a copy of it.

**Drift gate.** After any build, `scripts/check-drift.sh --manifest "$CLAUDE_CONFIG_DIR"`
verifies the live output against `.build-manifest.json`. A hand-edit to any
generated file (`skills/`, `hooks/`, `settings.json`, `CLAUDE.md`, `SKILLS.md`)
is reported as drift.
