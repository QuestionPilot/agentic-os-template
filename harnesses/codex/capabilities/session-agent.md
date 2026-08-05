---
lifecycle: shipped
---

## Codex realization — session-agent

- **Invocation:** the `$session-agent` skill. Codex reads
  `$CODEX_HOME/skills/session-agent/SKILL.md` on invocation.
- **Auto-fire:** the SessionStart hook
  (`$CODEX_HOME/hooks/framework-surface.sh`, matcher `startup|clear|compact`)
  injects a directive into `additionalContext` telling the model to invoke
  `$session-agent` as its first action (Mode 1). One trigger per session.
- **Enforcement:** class `pre-edit-gate` → the `PreToolUse` hook
  `hooks/session-agent.sh`, matcher `apply_patch` (Codex file edits report
  `tool_name: "apply_patch"`). Blocks the first file-modifying tool use unless a
  `session-agent` declaration including both the `Linear gate:` and `Lessons:`
  lines appears in the transcript. Safety net only. Kill switch: env
  `CLAUDE_SKIP_SESSION_AGENT=1` — same name on every harness.
- **Mode marker:** Codex has no `Skill` tool — capabilities are
  context-injected. The hook + the Mode-1-vs-Mode-2 logic detect prior
  invocation by the capability body actually landing in the transcript: a
  message record carrying this capability's H1
  (`Session Agent — Session Kickoff Orient + Routing`) or an assistant
  function_call reading `skills/session-agent/SKILL.md`. A bare substring match
  on the path is NOT the marker — Codex's per-session skills catalog (a
  developer message) lists every skill's `(file: …)` path, so the path alone
  appears in transcripts where the capability never ran. The capability name
  AND the H1 title must stay in sync with both hook scripts.
- **Catalog inputs (R2):** the OS capability catalog in `$CODEX_HOME/AGENTS.md` and
  the capability specs under `$AI_CONFIG_DIR/capabilities/`; the routable
  capabilities are the compiled skills under `$CODEX_HOME/skills/`.
- **`.agents` co-render (Gemini):** this compiled skill is mirrored
  byte-identically into the repo-level `.agents/skills/` overlay when `AGENTS_DIR`
  is set in `local.env`. Gemini (agy/Antigravity) discovers that copy as a
  workspace skill; Codex ≥0.14x discovers it alongside `$CODEX_HOME/skills/`.
  A Gemini session has no hook runtime — the auto-fire directive and pre-edit gate
  do not apply there; invoke the capability as the first action and emit the R5
  declaration anyway. Enforcement is advisory.
