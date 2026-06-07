---
lifecycle: shipped
---

## Codex realization — session-agent

- **Invocation:** the `$session-agent` skill. Codex reads
  `$CODEX_HOME/skills/session-agent/SKILL.md` on invocation.
- **Auto-fire:** the framework SessionStart hook
  (`$CODEX_HOME/hooks/framework-surface.sh`, matcher `startup|clear|compact`)
  injects a directive into `additionalContext` on every session start telling
  the model to invoke `$session-agent` as its first action (Mode 1: kickoff
  orient). One trigger per session.
- **Enforcement:** class `pre-edit-gate` → the `PreToolUse` hook
  `hooks/session-agent.sh`, matcher `apply_patch` (Codex file edits report
  `tool_name: "apply_patch"`). Blocks the first file-modifying tool use of a
  session unless a `session-agent` declaration including a `Linear gate:` line
  appears in the transcript. Safety net only — not the primary trigger.
  Kill switch: env `CLAUDE_SKIP_SESSION_AGENT=1` — the same name as on Claude
  Code, so one kill switch works regardless of harness.
- **Mode marker:** Codex has no `Skill` tool — capabilities are
  context-injected. The hook + the Mode-1-vs-Mode-2 logic both detect prior
  invocation by matching the literal substring `skills/session-agent/SKILL.md`
  in the session transcript (the capability body being read). The capability
  name must stay in sync with both hook scripts.
- **Catalog inputs (R2):** the orchestration sub-routine consults the OS
  capability catalog in `$CODEX_HOME/AGENTS.md` and the capability specs under
  `ai-config/capabilities/`. The capabilities the sub-routine routes to are the
  compiled skills under `$CODEX_HOME/skills/`.
