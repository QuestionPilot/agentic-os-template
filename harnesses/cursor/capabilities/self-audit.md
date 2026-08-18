---
lifecycle: shipped
---

## Cursor realization — self-audit

- **Invocation:** type `/self-audit` in Agent chat. Cursor reads
  `<CURSOR_CONFIG_DIR>/skills/self-audit/SKILL.md` when the skill is used.
- **No auto-fire.** Unlike `session-agent` (which carries a `sessionStart`
  directive), `/self-audit` — like `/closeout` — is opt-in only. Neither
  declares an `enforcement:` class, so the build's hook-wiring step registers
  nothing for them.
- **Script lookup:** the capability invokes
  `<AI_CONFIG_DIR>/scripts/self-audit.sh` through the `Shell` tool.
  `<AI_CONFIG_DIR>` is the framework checkout path, substituted into rendered
  files by the build from `local.env`.
- **Output channel:** the script's markdown scorecard prints to stdout; the
  capability surfaces it inline in the conversation. With
  `--save audits/<date>.md`, it writes a tracked artifact to the operator's
  checkout via the script's own redirection, not via Cursor's `Write` tool.
- **Edit-gate interaction:** the audit runs through `Shell`, which is
  deliberately outside the `preToolUse` gate matcher (`Write|Delete`), so a
  read-only audit is not blocked by an unopened gate. The `--save` variant also
  writes through the script rather than the `Write` tool, so it too bypasses the
  gate — that is a deliberate consequence of the matcher choice documented in
  `harnesses/cursor/adapter.md` Fact 2, not an exemption carved for this
  capability.
- **Sandbox note:** Cursor's default shell sandbox is `workspace_readwrite` and
  denies unmatched network traffic. A `--save` outside the current workspace, or
  an audit step that reaches the network, may need
  `additionalReadwritePaths` in the operator-owned `sandbox.json` — the build
  never writes that file.
