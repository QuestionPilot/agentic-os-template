---
lifecycle: shipped
---

## Hermes realization — session-agent

- **Invocation:** the `/session-agent` slash command. Hermes auto-converts the
  skill at `$HERMES_HOME/skills/session-agent/SKILL.md` into the slash command
  and injects its body on invocation (skill-read marker:
  `skills/session-agent/SKILL.md`).
- **Auto-fire:** the framework on_session_start hook
  (`$HERMES_HOME/hooks/framework-surface.sh`) injects a directive into the
  first turn's user message on every new session telling the model to invoke
  `/session-agent` as its first action (Mode 1: kickoff orient). Hermes fires
  on_session_start only on a session's first turn — one trigger per session.
- **Enforcement:** class `pre-edit-gate` → the `pre_tool_call` hook
  `hooks/session-agent.sh`, matcher `write_file|patch|terminal` (`terminal` is
  included because the shell can write files — the Bash-bypass). Blocks the
  first file-modifying tool use of a session unless the gate is open. Safety
  net only — not the primary trigger. Kill switch: env
  `CLAUDE_SKIP_SESSION_AGENT=1` — the same name as on Claude Code and Codex,
  so one kill switch works regardless of harness.
- **Gate declaration (Hermes-specific):** Hermes persists transcripts in
  `state.db`, not files, so the R5 declaration is ALSO written to disk where
  the hook can see it mid-turn. After emitting the R5 routing declaration in
  your response, write the gate file via the `write_file` tool:
  - path: `$HERMES_HOME/agentic-os/gate-<session_id>` (your session id)
  - content: the full R5 declaration block, including the `Linear gate:` line.
  The enforcement hook allows exactly this write through pre-gate and treats
  the file as the open-gate marker for the rest of the session. A read-only
  `state.db` query (skill-read marker + `Linear gate:` line in this session's
  persisted messages) is the multi-turn backstop.
- **Catalog inputs (R2):** the orchestration sub-routine consults the OS
  capability catalog in `$HERMES_HOME/SOUL.md` and the capability specs under
  `$AI_CONFIG_DIR/capabilities/`. The capabilities the sub-routine routes to
  are the compiled skills under `$HERMES_HOME/skills/`.
- **Desktop-app caveat:** the Hermes desktop app's dashboard entrypoint does
  not register `config.yaml` shell hooks natively (verified v0.16.0) — the
  build ships the `agentic-os-hook-bridge` plugin to restore registration in
  the desktop process. If hooks are silent in a GUI session, confirm the
  plugin is enabled in `config.yaml` (`plugins.enabled`).
