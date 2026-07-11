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
  `session-agent` appears in the transcript **and** both declaration lines —
  `Linear gate:` and `Lessons:` — were declared. The hook is a safety net for
  sessions where the SessionStart directive was ignored — not the primary
  trigger. Kill switch: env `CLAUDE_SKIP_SESSION_AGENT=1`.
- **Declaration channels:** the gate accepts the R5 declaration from either
  channel; both require the `Skill` invocation in the transcript first:
  1. **Gate marker** — after emitting the R5 declaration, write it (including
     the `Linear gate:` and `Lessons:` lines) to
     `$CLAUDE_CONFIG_DIR/agentic-os/gate-<session_id>`.
     The exact path is surfaced in the SessionStart directive and repeated in
     the hook's deny message; a `Write` to that exact path is allowed through
     the gate (a Bash heredoc works too). This is the ONLY channel on harness
     variants (desktop/SDK) whose transcript does not persist assistant text
     blocks; elsewhere it is a harmless extra write. Markers older than 7 days
     are reaped by the hook.
  2. **Transcript** — assistant-authored text blocks with the line-anchored
     `Linear gate:` and `Lessons:` declarations (the CLI variant persists
     assistant text, so the declaration alone suffices there; the two lines
     may land in different assistant messages).
- **Mode marker:** the hook + the capability's Mode-1-vs-Mode-2 logic both
  detect prior invocation by matching the literal `"skill":"session-agent"` in
  the transcript JSON. The capability name must stay in sync with
  `hooks/session-agent.sh` and `hooks/framework-surface.sh`.
- **Catalog inputs (R2):** the orchestration sub-routine consults
  `$CLAUDE_CONFIG_DIR/SKILLS.md` (the build-generated catalog) and the
  quick-reference table in `$CLAUDE_CONFIG_DIR/CLAUDE.md`. The capabilities the
  sub-routine routes to are the compiled skills under
  `$CLAUDE_CONFIG_DIR/skills/`.
