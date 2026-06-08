---
allowed-tools: Read, Write, Edit, Bash, AskUserQuestion, Skill
lifecycle: shipped
---
## Claude realization — closeout

- **Invocation:** the `Skill` tool with name `closeout`, or `/closeout`.
- **Enforcement:** none — `closeout` is **manual-fire**. There is no `Stop` hook;
  the prior `session-end-gate` hook (`hooks/closeout.sh`) was removed in <TEAM>-211
  because it re-fired on closeout's own protocol-prescribed writes. Invoke
  `closeout` explicitly when a session warrants a wrap-up.
- **`skill` lesson class destination:** a new capability is added under
  `CLAUDE_CONFIG_DIR/skills/<name>/SKILL.md` (authored via a skill-creation
  capability).
- **No ran-marker artifact:** the transcript invocation is the marker that closeout
  ran; do not write a separate marker to record it. (The session-log drain in the
  shared body is different — it writes durable session *content* to the vault.) A
  `no-action` outcome is complete.
- **Session-log drain identity:** `<machine>` = `hostname`; the vault path = the
  rendered `$OBSIDIAN_VAULT_PATH`; generate `closeout_id` with `openssl rand -hex 4`.
  Claude Code does not reliably expose the session/transcript id to a skill body, so
  leave `session_id` empty unless it can be determined — the `closeout_id` carries
  filename uniqueness.
