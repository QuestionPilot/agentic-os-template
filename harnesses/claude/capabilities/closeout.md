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
- **No side artifact:** the transcript invocation is the marker; do not write a
  side artifact to record that closeout ran. A `no-action` outcome is complete.
