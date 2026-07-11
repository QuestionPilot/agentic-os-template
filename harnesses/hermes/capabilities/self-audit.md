---
lifecycle: shipped
---

## Hermes realization — self-audit

- **Invocation:** the `/self-audit` slash command. Hermes reads
  `$HERMES_HOME/skills/self-audit/SKILL.md` on invocation.
- **No auto-fire.** Unlike `session-agent` (which carries an on_session_start
  directive), `/self-audit` — like `/closeout` — is opt-in only. Neither
  declares an `enforcement:` class, so the build's hook-wiring step registers
  nothing for them.
- **Script lookup:** the capability invokes
  `$AI_CONFIG_DIR/scripts/self-audit.sh` via the `terminal` tool.
  `$AI_CONFIG_DIR` is the framework checkout path, substituted into rendered
  files by the build from `local.env`.
- **Output channel:** the script's markdown scorecard prints to stdout; the
  capability surfaces it inline in the conversation. With
  `--save audits/<date>.md`, it writes a tracked artifact to the operator's
  checkout via the script's own redirection, not via a Hermes file tool.
- **Edit-gate interaction:** the `terminal` invocation of a read-only audit
  script still passes through the pre_tool_call edit-gate matcher — the gate
  must be open (session-agent ran + `Linear gate:` and `Lessons:` declared)
  before the audit runs, same as any other terminal use.
