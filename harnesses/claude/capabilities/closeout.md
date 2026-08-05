---
allowed-tools: Read, Write, Edit, Bash, AskUserQuestion, Skill
lifecycle: shipped
---
## Claude realization — closeout

- **Invocation:** the `Skill` tool with name `closeout`, or `/closeout`.
- **Enforcement:** none — `closeout` is **manual-fire**. There is no `Stop` hook.
  Invoke `closeout` explicitly when a session warrants a wrap-up.
- **`skill` lesson class destination:** a new capability is added under
  `CLAUDE_CONFIG_DIR/skills/<name>/SKILL.md` (authored via a skill-creation
  capability).
- **Q3a skill-candidate destination:** the rendered `CLAUDE_CONFIG_DIR/SKILLS.md`
  is build-manifest-managed — a hand-added row trips the drift gate. Write the
  CANDIDATE row into the operator-local skills overlay named by
  `SKILLS_OVERLAY_PATH` in `$AI_CONFIG_DIR/local.env` (add a "Skill candidates"
  section if absent), then re-render via `$AI_CONFIG_DIR/scripts/install.sh`. If no
  overlay is configured, create one and set `SKILLS_OVERLAY_PATH` — never hand-edit
  the rendered catalog.
- **Session-log drain identity:** `<machine>` = `hostname`; the vault path = the
  rendered `$OBSIDIAN_VAULT_PATH`; generate `closeout_id` with `openssl rand -hex 4`.
  Claude Code does not reliably expose the session/transcript id to a skill body, so
  leave `session_id` empty unless it can be determined.
