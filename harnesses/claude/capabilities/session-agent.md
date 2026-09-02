---
allowed-tools: Read, Bash
lifecycle: shipped
---
## Claude realization — session-agent

- **Invocation:** the `Skill` tool with name `session-agent`, or `/session-agent`.
- **Auto-fire:** the SessionStart hook (`framework-surface.sh`, matcher `startup|clear|compact`) injects a directive telling the model to invoke `session-agent` as its first action (Mode 1). One trigger per session.
- **Enforcement:** the `PreToolUse` hook `session-agent.sh` (matcher `Write|Edit|NotebookEdit`) blocks the first file-modifying tool use until `session-agent` was invoked AND both declaration lines — `Linear gate:` and `Lessons:` — were declared. The gate opens once both lines appear EITHER in the assistant's reply text OR in the gate marker file — either channel satisfies it. Safety net, not the primary trigger. Kill switch: `CLAUDE_SKIP_SESSION_AGENT=1`.
- **Declare through the gate marker:** after emitting the R5 declaration, write it (both lines included) to `$CLAUDE_CONFIG_DIR/agentic-os/gate-<session_id>` — the SessionStart directive names the exact path. On desktop/SDK variants that marker is the only channel the gate can see; elsewhere it is a harmless extra write.
- Channel details, the mode marker, and catalog inputs: `$AI_CONFIG_DIR/harnesses/claude/adapter.md` → Fact 2, "session-agent gate".
