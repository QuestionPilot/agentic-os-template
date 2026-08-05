---
allowed-tools: Read, Bash
lifecycle: shipped
---
## Claude realization — session-agent

- **Invocation:** the `Skill` tool with name `session-agent`, or `/session-agent`.
- **Auto-fire:** the SessionStart hook
  (`$CLAUDE_CONFIG_DIR/hooks/framework-surface.sh`, matcher
  `startup|clear|compact`) injects a directive into `additionalContext` telling the
  model to invoke `session-agent` as its first action (Mode 1). One trigger per
  session.
- **Enforcement:** class `pre-edit-gate` → the `PreToolUse` hook
  `hooks/session-agent.sh`, matcher `Write|Edit|NotebookEdit`. Blocks the first
  file-modifying tool use unless a `Skill` invocation of `session-agent` appears in
  the transcript **and** both declaration lines — `Linear gate:` and `Lessons:` —
  were declared. Safety net, not the primary trigger. Kill switch: env
  `CLAUDE_SKIP_SESSION_AGENT=1`.
- **Declaration channels:** either opens the gate; both require the `Skill`
  invocation in the transcript first.
  1. **Gate marker** — after emitting the R5 declaration, write it (including the
     `Linear gate:` and `Lessons:` lines) to
     `$CLAUDE_CONFIG_DIR/agentic-os/gate-<session_id>`. A `Write` to that exact path
     is allowed through the gate (a Bash heredoc works too). This is the ONLY
     channel on harness variants (desktop/SDK) whose transcript does not persist
     assistant text blocks; elsewhere it is a harmless extra write. Markers older
     than 7 days are reaped by the hook.
  2. **Transcript** — assistant-authored text blocks carrying the line-anchored
     `Linear gate:` and `Lessons:` declarations (the two lines may land in different
     assistant messages).
- **Mode marker:** the hook and the Mode-1-vs-Mode-2 logic both detect prior
  invocation by matching the literal `"skill":"session-agent"` in the transcript
  JSON. The capability name must stay in sync with `hooks/session-agent.sh` and
  `hooks/framework-surface.sh`.
- **Catalog inputs (R2):** `$CLAUDE_CONFIG_DIR/SKILLS.md` (build-generated) and the
  quick-reference table in `$CLAUDE_CONFIG_DIR/CLAUDE.md`; the routable capabilities
  are the compiled skills under `$CLAUDE_CONFIG_DIR/skills/`.
