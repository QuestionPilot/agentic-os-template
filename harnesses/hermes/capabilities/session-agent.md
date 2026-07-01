---
lifecycle: shipped
---

## Hermes realization — session-agent

- **Invocation:** the `/session-agent` slash command. Hermes auto-converts the
  skill at `$HERMES_HOME/skills/session-agent/SKILL.md` into the slash command
  and injects its body on invocation (skill-read marker:
  `skills/session-agent/SKILL.md`).
- **Auto-fire:** the framework `pre_llm_call` hook
  (`$HERMES_HOME/hooks/framework-surface.sh`) injects a directive into the
  first turn's user message on every new session telling the model to invoke
  `/session-agent` as its first action (Mode 1: kickoff orient). It rides
  `pre_llm_call` — **not** `on_session_start`, whose return Hermes discards
  (see `adapter.md` Fact 2) — and self-gates to the first turn via
  `.extra.is_first_turn`, so the directive fires exactly once per session.
- **Orient (Mode 1) memory pathing — Hermes-specific.** Hermes injects its
  native memory (`$HERMES_HOME/memories/MEMORY.md` + `USER.md`) as a frozen
  snapshot into the system prompt at session start — it is ALREADY in your
  context. For O1, read that injected snapshot; do **not** `read_file` a bare
  `MEMORY.md` path or `search_files` for it (there is no repo-root `MEMORY.md`,
  and a filesystem search times out). Hermes has no Claude-style
  `<config>/projects/<slug>/memory/` project-type memory notes — durable project memory
  lives in the vault, so satisfy O1's project-body reads inside the O4 vault
  orient (read the relevant `01-Projects/` notes) instead of chasing on-disk
  memory files.
- **O4 operator-identity read — Hermes-specific.** The operator-identity master
  ("Operator Soul") is ALREADY in your context: `install.sh --harness hermes`
  splices a lean projection of it (`SOUL_IDENTITY_PATH`) into `SOUL.md`, injected
  as identity slot #1 every session. So O4's explicit identity sub-step is already
  satisfied for working-style/identity without a vault round-trip — read the vault
  identity master note only when you need the full version beyond the lean
  projection.
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
