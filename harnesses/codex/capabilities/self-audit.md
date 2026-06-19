---
lifecycle: shipped
---

## Codex realization — self-audit

- **Invocation:** the `$self-audit` skill. Codex reads
  `$CODEX_HOME/skills/self-audit/SKILL.md` on invocation.
- **No auto-fire.** Unlike `session-agent` (which carries a SessionStart hook),
  `/self-audit` — like `closeout` — is opt-in only. Neither declares an
  `enforcement:` class, so `install.sh`'s hook-wiring step registers nothing for
  them. (`closeout`'s `Stop` gate was removed; it is now manual-fire.)
- **Script lookup:** the capability invokes `$AI_CONFIG_DIR/scripts/self-audit.sh`.
  `$AI_CONFIG_DIR` is the framework checkout path, substituted into rendered
  files by `install.sh` from `local.env`.
- **Output channel:** the script's markdown scorecard prints to stdout; the
  capability surfaces it inline in the transcript. With `--save audits/<date>.md`,
  it also writes a tracked artifact to the operator's checkout. Codex has no
  `Write` tool envelope at the skill level — the `--save` path is realized via
  the script's own `printf > path`, not via Codex's `apply_patch`.
