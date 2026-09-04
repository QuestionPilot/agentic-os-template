---
lifecycle: shipped
---

## Cursor realization — session-agent

- **Invocation:** type `/session-agent` in Agent chat, or let the agent apply it
  on its own — Cursor presents every discovered skill's description and the
  model decides relevance (the spine capability sets no
  `disable-model-invocation`, so both paths are live). Cursor reads
  `<CURSOR_CONFIG_DIR>/skills/session-agent/SKILL.md` when the skill is used.
- **Auto-fire:** the `sessionStart` hook
  (`<CURSOR_CONFIG_DIR>/hooks/framework-surface.sh`) returns
  `additional_context` telling the model to invoke `/session-agent` as its first
  action (Mode 1). One trigger per conversation. `sessionStart` is
  fire-and-forget on Cursor — it *surfaces* the directive, it cannot compel it;
  the `preToolUse` gate below is the enforcement half.
- **Enforcement:** class `pre-edit-gate` → the `preToolUse` hook
  `hooks/session-agent.sh`, matcher `Write` (a file edit reports
  `tool_name: "Write"` — live-verified 2026-08-18). Blocks the first
  file-modifying tool use unless the gate is open for this conversation. `Shell`
  is deliberately outside the matcher (mirroring the Claude and Codex gates), so
  a shell-driven write is a known, accepted bypass — this is a discipline net,
  not a security boundary. Safety net only; the primary auto-fire is the
  `sessionStart` directive. Kill switch: env `CLAUDE_SKIP_SESSION_AGENT=1` —
  same name on every harness.
- **Gate declaration (Cursor-specific):** Cursor exposes a `transcript_path` to
  hooks and the transcript really is on disk (JSONL under
  `<CURSOR_CONFIG_DIR>/projects/<slug>/agent-transcripts/`), but its format is
  undocumented, so the gate does not parse it. Declare the gate on disk
  instead — the same marker channel Claude and Hermes use. After
  emitting the R5 routing declaration in your response, write the gate file:
  - path: `<CURSOR_CONFIG_DIR>/agentic-os/gate-<conversation_id>` — the id is
    stable across turns. Sources in order: (1) the `sessionStart` directive,
    which names the whole marker path; (2) if it is gone, one deliberate
    gate-less `Write` — the deny names the exact marker path for THIS call;
    (3) only if neither exists, `<CURSOR_CONFIG_DIR>/agentic-os/current-session`
    — never as a marker key unless this conversation is the most recent one
    started in this config home; (4) `Shell` last.
  - that side file is per config home and last-writer-wins, so reading it can
    hand you ANOTHER conversation's id: when it and a deny disagree, THE DENY WINS.
  - content: the full R5 declaration block, including the `Linear gate:` and
    `Lessons:` lines. Both lines are required, at line start, each with a
    non-empty value after the colon.

  The enforcement hook allows exactly this write through pre-gate and treats the
  file as the open-gate marker for the rest of the conversation. If the write is
  denied with a message about an unreadable tool payload, fall back to `Shell`.
  A `Write` call carries `tool_input.file_path` + `tool_input.content`
  (live-verified 2026-08-18), so the normal path works; the fallback exists
  because that shape is observed behavior, not a documented contract.
- **Catalog inputs (R2):** the OS capability catalog in the rendered
  `<CURSOR_CONFIG_DIR>/AGENTS.md` and the capability specs under
  `<AI_CONFIG_DIR>/capabilities/`; the routable capabilities are the compiled
  skills under `<CURSOR_CONFIG_DIR>/skills/`.
- **Surface notes.** The headless Agent CLI (`agent -p --trust`) fires both
  hooks and the gate really blocks (live-verified 2026-08-18) — this harness has
  full enforcement parity in an automation lane, unlike Codex, whose
  non-interactive mode runs no hooks at all. The IDE and interactive-TUI
  surfaces are expected to fire but are not yet confirmed (adapter U3). A Cursor
  **Cloud Agent** (and any private-worker surface) runs neither user-level hooks
  nor `sessionStart` at all (documented): no auto-fire directive and no edit
  gate, so the conversation id is not discoverable there — a side file may exist
  on a shared config home from IDE sessions, do not use it. Invoke the
  capability as your first action and emit the R5 declaration anyway.
  Enforcement is advisory on that surface.
