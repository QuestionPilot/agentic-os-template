---
lifecycle: shipped
---

## Cursor realization — closeout

- **Invocation:** type `/closeout` in Agent chat (the agent may also apply it
  when a wrap-up is clearly the request). Cursor reads
  `<CURSOR_CONFIG_DIR>/skills/closeout/SKILL.md` when the skill is used.
- **Enforcement:** none — `closeout` is **manual-fire**. The build registers no
  `stop` or `sessionEnd` hook for it, deliberately: Cursor's `stop` hook can
  auto-submit a `followup_message` and would re-fire on closeout's own writes,
  the exact loop that got the Stop-hook gate removed on the other harnesses.
  Invoke `/closeout` explicitly when a session warrants a wrap-up.
- **`skill` lesson class destination:** a new capability is added under
  `<CURSOR_CONFIG_DIR>/skills/<name>/SKILL.md` (agentskills.io shape — the same
  file drops into any harness). A project-scoped variant belongs in the
  repository's own skills dir instead, where Cursor scopes it to that tree.
- **Session-log drain identity:** `<machine>` = `hostname`; the vault path = the
  rendered `<OBSIDIAN_VAULT_PATH>`; generate `closeout_id` with
  `openssl rand -hex 4`. Record the Cursor `conversation_id` in `session_id`
  when known — it is the same value the gate file is keyed on, so
  `ls <CURSOR_CONFIG_DIR>/agentic-os/` recovers it for the current
  conversation; otherwise leave it empty.
- **Edit-gate interaction:** closeout writes vault notes and framework files, so
  the `preToolUse` gate must already be open (session-agent ran and the gate
  file carries both declaration lines). It normally is by the time a session is
  worth closing out.
