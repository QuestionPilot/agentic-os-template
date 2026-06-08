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
- **No ran-marker artifact:** the transcript is the marker that closeout ran; do not
  write a separate marker to record it. (The session-log drain in the shared body is
  different — it writes durable session *content* to the vault.) A `no-action`
  outcome is complete.
- **Session-log drain identity:** `<machine>` = `hostname`; the vault path = the
  rendered `$OBSIDIAN_VAULT_PATH`; generate `closeout_id` with `openssl rand -hex 4`.
  If the active Codex session/transcript id is known (e.g. from `$CODEX_HOME/sessions/`),
  record it in `session_id`; otherwise leave it empty — the `closeout_id` carries
  filename uniqueness.
