#!/usr/bin/env bash
# Framework-changes surfacing hook (Hermes on_session_start event).
# Runs `git log` over the agentic-os-template checkout and surfaces recent
# framework changes as injected context. Hermes fires on_session_start once,
# on the first turn of a new session — no matcher needed.
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
# stdin:  on_session_start event JSON (drained but unused)
# stdout: when surfacing, {"context": "..."} — Hermes injects it into the
#         user message (never the system prompt)
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
# (Mode 1: kickoff orient). One trigger per session — Hermes fires
# on_session_start only on the first turn.
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

# Emit Hermes context-injection JSON via jq for safe escaping. Hermes injects
# the context into the user message of the first turn.
jq -nR --arg ctx "$CONTEXT" '{context: $ctx}'
