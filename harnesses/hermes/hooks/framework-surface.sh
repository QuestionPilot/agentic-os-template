#!/usr/bin/env bash
# Framework-changes surfacing hook (Hermes pre_llm_call event, first turn only).
# Runs `git log` over the agentic-os-template checkout and surfaces recent
# framework changes + the session-agent kickoff directive as injected context.
#
# WHY pre_llm_call (not on_session_start): on_session_start is fire-and-forget in
# Hermes — conversation_loop.py invokes it but DISCARDS its return, so a
# {"context":...} emitted there never reaches the model (verified against the
# Hermes source, v0.16.0). pre_llm_call is the session-lifecycle event whose
# {"context":...} IS injected into the user message (turn_context.py ->
# conversation_loop.py). pre_llm_call fires before EVERY model call, so this hook
# self-gates to the first turn via .extra.is_first_turn.
#
# @@AI_CONFIG_DIR@@ is a build placeholder: install.sh substitutes the absolute
# path to the agentic-os-template checkout from local.env (see
# harnesses/hermes/adapter.md).
#
# Kill switches:
#   CLAUDE_SKIP_FRAMEWORK_SURFACE=1         disables the whole hook (same env
#                                           name as the Claude harness — one
#                                           switch works regardless of harness)
#   CLAUDE_SKIP_FRESHNESS_CHECK=1           disables just the config-freshness nudge
#   CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE=1   disables just the session-agent
#                                           auto-fire directive
# Window: set CLAUDE_FRAMEWORK_SINCE_DAYS=N to override (default 10).
#
# stdin:  pre_llm_call event JSON — carries .session_id, .cwd, and
#         .extra.is_first_turn (the first-turn gate signal)
# stdout: on the first turn only, {"context": "..."} — Hermes injects it into the
#         user message (never the system prompt). Silent on every later turn.
# exit:   always 0 (fail-open; this is a surfacing hook)

set -uo pipefail

if [[ "${CLAUDE_SKIP_FRAMEWORK_SURFACE:-0}" == "1" ]]; then
  exit 0
fi

# jq contract — this is a surfacing hook, so it fails OPEN: without jq it
# cannot emit safely-escaped JSON, so it stays silent rather than erroring.
# Missing framework context is not a safety risk.
command -v jq >/dev/null 2>&1 || exit 0

AI_CONFIG_DIR="@@AI_CONFIG_DIR@@"
DAYS="${CLAUDE_FRAMEWORK_SINCE_DAYS:-10}"

# Read stdin — the event JSON carries session_id, which the model cannot see
# anywhere else and needs to name its per-session gate file (the edit-gate's
# declaration channel — see hooks/session-agent.sh).
EVENT_JSON="$(cat)"
SESSION_ID="$(printf '%s' "$EVENT_JSON" | jq -r '.session_id // empty' 2>/dev/null || true)"

# --- First-turn gate --------------------------------------------------------
# This hook is wired to Hermes's pre_llm_call event (see header). pre_llm_call
# fires before EVERY model call, so surface ONLY on the session's first turn.
# Primary signal: .extra.is_first_turn (Hermes computes it as
# `not conversation_history`; a JSON boolean). Use has()-checks, NOT jq's `//`,
# because `//` treats a literal `false` as empty and would misread a later turn
# as "absent". Fallback when the signal is missing (defensive — e.g. a future
# wire change): a per-session sentinel so the directive is never injected twice.
IS_FIRST="$(printf '%s' "$EVENT_JSON" | jq -r '
  if (.extra? // {} | type=="object" and has("is_first_turn")) then (.extra.is_first_turn|tostring)
  elif has("is_first_turn") then (.is_first_turn|tostring)
  else "absent" end' 2>/dev/null || echo absent)"

# Normalize case so a non-canonical stringified "False"/"True" is treated the
# same as jq's lowercase boolean — keeps the .sh/.ps1 twins (PowerShell compares
# case-insensitively) behaviorally identical.
IS_FIRST="$(printf '%s' "$IS_FIRST" | tr '[:upper:]' '[:lower:]')"
SENTINEL=""
if [[ "$IS_FIRST" == "false" ]]; then
  exit 0
elif [[ "$IS_FIRST" != "true" ]]; then
  # No reliable first-turn signal → dedup via a per-session sentinel file.
  # Without a session_id we cannot dedup at all, so fail SAFE (stay silent)
  # rather than re-inject the directive on every model call.
  _gate_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
  if [[ -z "$_gate_dir" || -z "$SESSION_ID" ]]; then
    exit 0
  fi
  SENTINEL="$_gate_dir/agentic-os/surfaced-$SESSION_ID"
  [[ -f "$SENTINEL" ]] && exit 0
fi

# --- 1. agentic-os-template git-log block ---------------------------------
# Use -e (not -d) on .git: inside a linked git worktree it's a regular file
# (gitlink) pointing at the main repo's .git/worktrees/<name>, not a directory.
GIT_BLOCK=""
if [[ -e "$AI_CONFIG_DIR/.git" ]]; then
  CHANGES="$(git -C "$AI_CONFIG_DIR" log --since="${DAYS}.days.ago" --pretty=format:'- %ad %s (%h)' --date=short 2>/dev/null)"
  if [[ -n "$CHANGES" ]]; then
    GIT_BLOCK="# Recent agentic-os-template (framework) changes — last ${DAYS} days

The agentic OS framework has had the following commits recently. Use this to pick
up improvements from prior sessions and know what changed in the operating-system
layer itself:

${CHANGES}

Full details: \`git -C \"\$AI_CONFIG_DIR\" log --since=${DAYS}.days.ago\`
Override window: env \`CLAUDE_FRAMEWORK_SINCE_DAYS=N\`. Disable: env \`CLAUDE_SKIP_FRAMEWORK_SURFACE=1\`."
  fi
fi

# --- 1b. Config-freshness nudge --------------------------------------------
# Warn when the installed config was rendered from now-stale sources. Soft
# signal only — never blocks. Fail-open: any error or indeterminate → silent.
FRESH_BLOCK=""
if [[ "${CLAUDE_SKIP_FRESHNESS_CHECK:-0}" != "1" ]]; then
  # The install dir is this hook's own parent (hooks live at <install>/hooks/).
  INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
  FRESHNESS_SCRIPT="$AI_CONFIG_DIR/scripts/check-freshness.sh"
  if [[ -n "$INSTALL_DIR" && -f "$INSTALL_DIR/.build-manifest.json" && -f "$FRESHNESS_SCRIPT" ]]; then
    FRESHNESS_TIMEOUT=""
    if command -v timeout >/dev/null 2>&1; then FRESHNESS_TIMEOUT="timeout 5"
    elif command -v gtimeout >/dev/null 2>&1; then FRESHNESS_TIMEOUT="gtimeout 5"; fi
    stale_list="$($FRESHNESS_TIMEOUT bash "$FRESHNESS_SCRIPT" --manifest "$INSTALL_DIR" --list 2>/dev/null)"
    fresh_rc=$?
    if [[ "$fresh_rc" -eq 1 && -n "$stale_list" ]]; then
      stale_count="$(printf '%s\n' "$stale_list" | grep -c .)"
      FRESH_BLOCK="

## ⚠ Installed config is stale — re-run install.sh

${stale_count} framework source file(s) changed since your last \`install.sh\`
render, so your live config may be running outdated hooks/capabilities.
check-drift won't catch this (it detects hand-edits, not staleness). Re-sync:

    bash \$AI_CONFIG_DIR/scripts/install.sh --harness hermes

Stale source(s):
$(printf '%s\n' "$stale_list" | sed 's/^/- /')

Disable this check: env \`CLAUDE_SKIP_FRESHNESS_CHECK=1\`."
    fi
  fi
fi

# --- 2. Session-agent invocation directive ----------------------------------
# Auto-fire mechanism for the session-agent spine capability. Emits one
# directive instructing the model to invoke session-agent as its first action
# (Mode 1: kickoff orient). One trigger per session — the first-turn gate above
# ensures this fires only on the session's first pre_llm_call.
SA_BLOCK=""
if [[ "${CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE:-0}" != "1" ]]; then
  SA_BLOCK="

## Session-agent — invoke now (Mode 1: kickoff orient)

The \`/session-agent\` skill is the spine. **Your first action this session
must be to invoke \`/session-agent\`** — Mode 1 fires the kickoff orient
(memory body-reads + Linear projects-first query + vault \`START.md\` +
reconcile this session-start window's commits against memory headlines), then
routes the user's first request.

On every subsequent non-trivial prompt, re-invoke \`/session-agent\` (Mode 2:
route only — Mode 1's orient outputs are still live in context).

Skip this directive if you have already invoked session-agent this session.
Disable the directive entirely: env \`CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE=1\`."

  # Surface the per-session gate path: the edit-gate hook keys on session_id,
  # which the model cannot discover on its own.
  if [[ -n "$SESSION_ID" ]]; then
    INSTALL_DIR_SA="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
    if [[ -n "$INSTALL_DIR_SA" ]]; then
      SA_BLOCK="${SA_BLOCK}

After the R5 routing declaration, open the edit-gate by writing the file
\`${INSTALL_DIR_SA}/agentic-os/gate-${SESSION_ID}\` via the write_file tool with
the full declaration (including the \`Linear gate:\` line) as its content."
    fi
  fi
fi

# Nothing to surface from any block → quiet exit.
if [[ -z "$GIT_BLOCK" && -z "$FRESH_BLOCK" && -z "$SA_BLOCK" ]]; then
  exit 0
fi

CONTEXT="${GIT_BLOCK}${FRESH_BLOCK}${SA_BLOCK}"

# Sentinel dedup applies only when the first-turn signal was absent (above);
# mark this session surfaced so a later turn stays silent. Best-effort — never
# affects this hook's output or exit code.
if [[ -n "$SENTINEL" ]]; then
  mkdir -p "$(dirname "$SENTINEL")" 2>/dev/null && : > "$SENTINEL" 2>/dev/null || true
fi

# Emit Hermes context-injection JSON via jq for safe escaping. Hermes injects
# the context into the user message (first turn only — gated above).
jq -nR --arg ctx "$CONTEXT" '{context: $ctx}'
