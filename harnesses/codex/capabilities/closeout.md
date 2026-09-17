---
lifecycle: shipped
---

## Codex realization — closeout

- **Invocation:** the `$closeout` skill. Codex reads
  `$CODEX_HOME/skills/closeout/SKILL.md` on invocation.
- **Enforcement:** none — `closeout` is **manual-fire**. There is no `Stop` hook.
  Invoke `$closeout` explicitly when a session warrants a wrap-up.
- **`skill` lesson class destination:** a new capability is added under
  `$CODEX_HOME/skills/<name>/SKILL.md`.
- **Q3a skill-candidate destination:** write the CANDIDATE row into the
  operator-local skills overlay named by `SKILLS_OVERLAY_PATH` in
  `$AI_CONFIG_DIR/local.env` (add a "Skill candidates" section if absent), then
  re-render the Claude harness via
  `$AI_CONFIG_DIR/scripts/install.sh --harness claude` — the overlay is the one
  shared candidate table, and it renders only into the Claude harness's
  `SKILLS.md`. If no overlay is configured, create one and set
  `SKILLS_OVERLAY_PATH`. This harness's own rendered catalog (the capability
  catalog inside `$CODEX_HOME/AGENTS.md`) is build-manifest-managed and never
  carries candidate rows — a hand-added row trips the drift gate.
- **Session-log drain identity:** `<machine>` = `hostname`; the vault path = the
  rendered `$OBSIDIAN_VAULT_PATH`; generate `closeout_id` with `openssl rand -hex 4`.
  If the active Codex session/transcript id is known (e.g. from
  `$CODEX_HOME/sessions/`), record it in `session_id`; otherwise leave it empty.
- **`.agents` co-render (Gemini):** this compiled skill is mirrored
  byte-identically into the repo-level `.agents/skills/` overlay when `AGENTS_DIR`
  is set in `local.env`; Gemini discovers it as a workspace skill and Codex ≥0.14x
  discovers the same copy. The capability is manual-fire everywhere, so a Gemini
  closeout uses the same drain identity rules above.
