---
allowed-tools: Read, Bash, Glob
lifecycle: shipped
---
## Claude realization — self-audit

- **Invocation:** the `Skill` tool with name `self-audit`, or the slash command
  `/self-audit`.
- **No auto-fire.** Unlike `session-agent` (which carries a SessionStart hook),
  `/self-audit` — like `closeout` — is opt-in only. Neither declares an
  `enforcement:` class, so `install.sh`'s hook-wiring step registers nothing for
  them. (`closeout`'s `Stop` gate was removed; it is now manual-fire.)
- **Tool envelope:** `Read` and `Glob` for state inspection (memory files,
  capability surfaces, vault notes if available); `Bash` to invoke
  `$AI_CONFIG_DIR/scripts/self-audit.sh` and to optionally write a saved scorecard via the
  script's `--save` flag. No `Write` / `Edit` in the allowed-tools list —
  self-audit is read-only by design.
- **Script lookup:** the capability invokes `$AI_CONFIG_DIR/scripts/self-audit.sh`.
  `$AI_CONFIG_DIR` is the framework checkout path, substituted into rendered
  files by `install.sh` from `local.env`.
- **Output channel:** the script's markdown scorecard prints to stdout; the
  capability surfaces it inline in the transcript. With `--save audits/<date>.md`,
  it also writes a tracked artifact to the operator's checkout.
