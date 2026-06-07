---
allowed-tools: Read, Bash
lifecycle: shipped
---
## Claude realization — session-agent

- **Invocation:** the `Skill` tool with name `session-agent`, or the slash command
  `/session-agent`.
- **Auto-fire:** the framework SessionStart hook
  (`$CLAUDE_CONFIG_DIR/hooks/framework-surface.sh`, matcher
  `startup|clear|compact`) injects a directive into `additionalContext` on every
  session start telling the model to invoke `session-agent` as its first action
  (Mode 1: kickoff orient). One trigger per session — no duplicate firing from
  CLAUDE.md prose or PreToolUse.
- **Enforcement:** class `pre-edit-gate` → the `PreToolUse` hook
  `hooks/session-agent.sh`, matcher `Write|Edit|NotebookEdit`. Blocks the first
  file-modifying tool use of a session unless a `Skill` invocation of
  `session-agent` appears in the transcript **and** a `Linear gate:` line was
  declared. The hook is a safety net for sessions where the SessionStart
  directive was ignored — not the primary trigger. Kill switch: env
  `CLAUDE_SKIP_SESSION_AGENT=1`.
- **Mode marker:** the hook + the capability's Mode-1-vs-Mode-2 logic both
  detect prior invocation by matching the literal `"skill":"session-agent"` in
  the transcript JSON. The capability name must stay in sync with
  `hooks/session-agent.sh` and `hooks/framework-surface.sh`.
- **Catalog inputs (R2):** the orchestration sub-routine consults
  `$CLAUDE_CONFIG_DIR/SKILLS.md` (the build-generated catalog) and the
  quick-reference table in `$CLAUDE_CONFIG_DIR/CLAUDE.md`. The capabilities the
  sub-routine routes to are the compiled skills under
  `$CLAUDE_CONFIG_DIR/skills/`.
