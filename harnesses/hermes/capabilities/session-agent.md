---
lifecycle: shipped
---

## Hermes realization — session-agent

- **Invocation:** the `/session-agent` slash command. Hermes auto-converts the
  skill at `$HERMES_HOME/skills/session-agent/SKILL.md` into the slash command
  and injects its body on invocation (skill-read marker:
  `skills/session-agent/SKILL.md`).
- **Auto-fire:** the `pre_llm_call` hook
  (`$HERMES_HOME/hooks/framework-surface.sh`) injects a directive into the first
  turn's user message telling the model to invoke `/session-agent` as its first
  action (Mode 1). It rides `pre_llm_call` — **not** `on_session_start`, whose
  return Hermes discards (`adapter.md` Fact 2) — and self-gates to the first turn
  via `.extra.is_first_turn`, so it fires exactly once per session.
- **Orient (Mode 1) memory pathing — Hermes-specific.** Hermes injects its native
  memory (`$HERMES_HOME/memories/MEMORY.md` + `USER.md`) as a frozen snapshot into
  the system prompt — it is ALREADY in your context. For O1, read that snapshot; do
  **not** `read_file` a bare `MEMORY.md` path or `search_files` for it (there is no
  repo-root `MEMORY.md`, and a filesystem search times out). Hermes has no
  `<config>/projects/<slug>/memory/` project notes — durable project memory lives in
  the vault, so satisfy O1's project-body reads inside the O4 vault orient (the
  relevant `01-Projects/` notes). Run `scripts/orient.sh` without `--memory-dir`.
- **O4 operator-identity read — Hermes-specific.** The operator-identity master
  ("Operator Soul") is ALREADY in your context: `install.sh --harness hermes`
  splices a lean projection (`SOUL_IDENTITY_PATH`) into `SOUL.md`, injected as
  identity slot #1 every session. Read the vault identity master only when you need
  the full version beyond that projection.
- **Enforcement:** class `pre-edit-gate` → the `pre_tool_call` hook
  `hooks/session-agent.sh`, matcher `write_file|patch|terminal` (`terminal` is
  included because the shell can write files — the Bash-bypass). Blocks the first
  file-modifying tool use unless the gate is open. Safety net only. Kill switch: env
  `CLAUDE_SKIP_SESSION_AGENT=1` — same name on every harness.
- **Gate declaration (Hermes-specific):** Hermes persists transcripts in
  `state.db`, not files, so the R5 declaration is ALSO written to disk where
  the hook can see it mid-turn. After emitting the R5 routing declaration in
  your response, write the gate file via the `write_file` tool:
  - path: `$HERMES_HOME/agentic-os/gate-<session_id>` (your session id)
  - content: the full R5 declaration block, including the `Linear gate:` and
    `Lessons:` lines.
  The enforcement hook allows exactly this write through pre-gate and treats
  the file as the open-gate marker for the rest of the session. A read-only
  `state.db` query is the multi-turn backstop: the skill-read marker in this
  session's user/assistant rows plus ASSISTANT-authored `Linear gate:` and
  `Lessons:` declarations at line start (tool-result rows — the injected skill
  body, prior deny text — do not open the gate).
- **Catalog inputs (R2):** the OS capability catalog in `$HERMES_HOME/SOUL.md` and
  the capability specs under `$AI_CONFIG_DIR/capabilities/`; the routable
  capabilities are the compiled skills under `$HERMES_HOME/skills/`.
- **Desktop-app caveat:** the Hermes desktop app's dashboard entrypoint does
  not register `config.yaml` shell hooks natively (verified v0.16.0) — the
  build ships the `agentic-os-hook-bridge` plugin to restore registration in
  the desktop process. If hooks are silent in a GUI session, confirm the
  plugin is enabled in `config.yaml` (`plugins.enabled`).
