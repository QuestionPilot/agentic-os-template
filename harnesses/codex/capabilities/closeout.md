---
lifecycle: shipped
---

## Codex realization — closeout

- **Invocation:** the `$closeout` skill. Codex reads
  `$CODEX_HOME/skills/closeout/SKILL.md` on invocation.
- **Enforcement:** none — `closeout` is **manual-fire**. There is no `Stop` hook;
  the prior `session-end-gate` hook (`hooks/closeout.sh`) was removed in <TEAM>-211
  because it re-fired on closeout's own protocol-prescribed writes. Invoke
  `$closeout` explicitly when a session warrants a wrap-up.
- **`skill` lesson class destination:** a new capability is added under
  `$CODEX_HOME/skills/<name>/SKILL.md`.
- **No side artifact:** the transcript is the marker; do not write a side
  artifact to record that closeout ran. A `no-action` outcome is complete.
