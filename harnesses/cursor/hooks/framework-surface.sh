#!/usr/bin/env bash
# Framework-changes surfacing hook (Cursor `sessionStart` event).
# Runs `git log` over the agentic-os-template checkout and surfaces recent
# framework changes, a config-freshness nudge, and the session-agent auto-fire
# directive as `additional_context`. Not tied to any capability — wired
# unconditionally by the build.
#
# @@AI_CONFIG_DIR@@ is a build placeholder: install.sh substitutes the absolute
# path to the agentic-os-template checkout from local.env (see
# harnesses/cursor/adapter.md).
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
# stdin:  sessionStart event JSON — {session_id, is_background_agent,
#         composer_mode} plus the common base fields. `composer_mode` selects
#         whether the directive is emitted at all; everything else is unused.
# stdout: when surfacing, {"additional_context": "<markdown>"}
# exit:   always 0 (fail-OPEN — a surfacing hook must never break a session;
#         Cursor's default for a non-0/non-2 exit is fail-open anyway, and this
#         hook is deliberately NOT wired failClosed)
#
# Cursor note: `sessionStart` is fire-and-forget — the agent loop does not wait
# for or enforce a blocking response, and `continue:false` does not block
# session creation (docs 2026-08-18). This hook only surfaces context, which is
# exactly what that event supports. It also never fires in a Cloud Agent (user
# hooks and sessionStart are both unavailable there) — see adapter.md Fact 2.

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

# Capture the sessionStart payload. `composer_mode` is "agent" | "ask" | "edit"
# (optional). An `ask`-mode composer cannot invoke a skill or edit files, so the
# session-agent kickoff directive would be noise there — surface the framework
# blocks but skip the directive. Absent/unknown mode → treat as agent (the safe
# default, identical to prior behavior). Lowercase-normalized for bash<->PS
# parity (the PS twin's -eq is case-insensitive; bash == is not).
EVENT_JSON="$(cat)"
COMPOSER_MODE="$(printf '%s' "$EVENT_JSON" | jq -r '.composer_mode // empty' 2>/dev/null | tr '[:upper:]' '[:lower:]')"

# --- 1. agentic-os-template git-log block ----------------------------------
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
# Warn when the installed config was rendered from now-stale sources — a fixed
# hook/capability merged to main but install.sh was never re-run, so it sits
# un-activated on this machine. check-drift CANNOT see this: it compares the
# install against its own build-time manifest (tamper detection), never against
# the repo. This block diffs the manifest's recorded SOURCE hashes vs the
# current repo via scripts/check-freshness.sh and surfaces a soft "re-run
# install.sh" nudge. Soft signal only — never blocks. Fail-open: any error or
# indeterminate result → silent.
FRESH_BLOCK=""
if [[ "${CLAUDE_SKIP_FRESHNESS_CHECK:-0}" != "1" ]]; then
  # The install dir is this hook's own parent (hooks live at <install>/hooks/).
  INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
  FRESHNESS_SCRIPT="$AI_CONFIG_DIR/scripts/check-freshness.sh"
  if [[ -n "$INSTALL_DIR" && -f "$INSTALL_DIR/.build-manifest.json" && -f "$FRESHNESS_SCRIPT" ]]; then
    # Bound the check so a pathological manifest (huge/slow source set) can't
    # stall session start and sink the OTHER blocks' emission. Prefer GNU
    # `timeout`, fall back to `gtimeout` (macOS coreutils); without either it
    # runs unbounded (graceful degradation). A timeout kill yields rc 124 != 1
    # → no nudge (fail-open).
    FRESHNESS_TIMEOUT=""
    if command -v timeout >/dev/null 2>&1; then FRESHNESS_TIMEOUT="timeout 5"
    elif command -v gtimeout >/dev/null 2>&1; then FRESHNESS_TIMEOUT="gtimeout 5"; fi
    stale_list="$($FRESHNESS_TIMEOUT bash "$FRESHNESS_SCRIPT" --manifest "$INSTALL_DIR" --list 2>/dev/null)"
    fresh_rc=$?
    # exit 1 = stale (a clean non-empty list). 0 = fresh, 2 = indeterminate:
    # both stay silent (fail-open) — only surface a confirmed-stale install.
    if [[ "$fresh_rc" -eq 1 && -n "$stale_list" ]]; then
      stale_count="$(printf '%s\n' "$stale_list" | grep -c .)"
      FRESH_BLOCK="

## Installed config is stale — re-run install.sh

${stale_count} framework source file(s) changed since your last \`install.sh\`
render, so your live config may be running outdated hooks/capabilities.
check-drift won't catch this (it detects hand-edits, not staleness). Re-sync:

    bash \$AI_CONFIG_DIR/scripts/install.sh --harness cursor

Stale source(s):
$(printf '%s\n' "$stale_list" | sed 's/^/- /')

Disable this check: env \`CLAUDE_SKIP_FRESHNESS_CHECK=1\`."
    fi
  fi
fi

# --- 2. Session-agent invocation directive ---------------------------------
# Auto-fire mechanism for the session-agent spine capability. Emits one
# directive instructing the model to invoke /session-agent as its first action
# (Mode 1: kickoff orient). Single trigger per conversation — sessionStart fires
# once when a composer conversation is created. AGENTS.md prose and the
# preToolUse gate are NOT duplicate triggers: the gate is a safety net for
# file-modifying tool use, not a session-start trigger.
#
# There is no compact variant here (the Claude/Codex twins have one): Cursor
# splits compaction onto its own `preCompact` event, which is explicitly
# observational — it cannot inject context — so a post-compaction re-orient has
# no delivery channel on this harness. Recorded as a known asymmetry rather
# than faked.
SA_BLOCK=""
if [[ "${CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE:-0}" != "1" && "$COMPOSER_MODE" != "ask" ]]; then
  SA_BLOCK="

## Session-agent — invoke now (Mode 1: kickoff orient)

The \`/session-agent\` capability is the spine. **Your first action this session
must be to invoke \`/session-agent\`** — Mode 1 fires the kickoff orient (memory
body-reads + tracker projects-first query + vault \`START.md\` + reconcile this
session-start window's commits against memory headlines), then routes the
user's first request.

On every subsequent non-trivial prompt, re-invoke \`/session-agent\` (Mode 2:
route only — Mode 1's orient outputs are still live in context).

Before your first file-modifying tool use, open the edit gate: write your R5
routing declaration (including the \`Linear gate:\` and \`Lessons:\` lines) to
\`<config>/agentic-os/gate-<conversation_id>\`, where \`<config>\` is the dir
holding this hook's parent. The realization body in the capability spells out
the contract.

Skip this directive if you have already invoked session-agent this session.
Disable the directive entirely: env \`CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE=1\`."
fi

# Nothing to surface from any block → quiet exit.
if [[ -z "$GIT_BLOCK" && -z "$FRESH_BLOCK" && -z "$SA_BLOCK" ]]; then
  exit 0
fi

CONTEXT="${GIT_BLOCK}${FRESH_BLOCK}${SA_BLOCK}"

# Emit JSON via jq for safe escaping. Cursor's sessionStart output schema is
# {env?, additional_context?} — this hook sets no session env vars.
jq -nR --arg ctx "$CONTEXT" '{additional_context: $ctx}'
