---
lifecycle: shipped
---

## Hermes realization — closeout

- **Invocation:** the `/closeout` slash command. Hermes reads
  `$HERMES_HOME/skills/closeout/SKILL.md` on invocation.
- **Enforcement:** none — `closeout` is **manual-fire**. No session-end hook fires
  it: the autonomous `on_session_end` → shared-drain wiring is a SEPARATE, deferred
  governance feature (disabled by default). Invoke `/closeout` explicitly when a
  session warrants a wrap-up.
- **`skill` lesson class destination:** a new capability is added under
  `$HERMES_HOME/skills/<name>/SKILL.md` (agentskills.io shape — drop-in
  portable across harnesses).
- **Q3a skill-candidate destination:** write the CANDIDATE row into the
  operator-local skills overlay named by `SKILLS_OVERLAY_PATH` in
  `$AI_CONFIG_DIR/local.env` (add a "Skill candidates" section if absent), then
  re-render the Claude harness via
  `$AI_CONFIG_DIR/scripts/install.sh --harness claude` — the overlay is the one
  shared candidate table, and it renders only into the Claude harness's
  `SKILLS.md`. If no overlay is configured, create one and set
  `SKILLS_OVERLAY_PATH`. This harness's own rendered catalog (the capability
  catalog inside `$HERMES_HOME/SOUL.md`) is build-manifest-managed and never
  carries candidate rows — a hand-added row trips the drift gate.
- **Session-log drain identity:** `<machine>` = `hostname`; the vault path = the
  rendered `$OBSIDIAN_VAULT_PATH`; generate `closeout_id` with
  `openssl rand -hex 4`. Record the Hermes session id (from the hook payload or
  `hermes sessions`) in `session_id` when known; otherwise leave it empty.
- **Native memory boundary:** Hermes's native memory files (the `memories/` hot
  cache, hard-capped) are LOCAL CACHES per the framework cache contract — closeout
  routes durable lessons to the vault, never treating the native store as the
  long-term record.
