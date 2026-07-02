#!/usr/bin/env bash
# Framework-changes surfacing hook (Codex SessionStart event).
# Runs `git log` over the agentic-os-template checkout and surfaces recent framework changes
# as additional context. Filtered to startup/clear/compact via the hooks.json
# matcher. Not tied to any capability — wired unconditionally by the build.
#
# @@AI_CONFIG_DIR@@ is a build placeholder: install.sh substitutes the absolute
# path to the agentic-os-template checkout from local.env (see harnesses/codex/adapter.md).
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
# stdin:  SessionStart event JSON — `.source` (startup/clear/compact via the
#         hooks.json matcher) selects the session-agent directive variant;
#         everything else in the payload is unused
# stdout: when surfacing, JSON with hookSpecificOutput.additionalContext
# exit:   always 0 (fail-open; non-zero is treated as a hook error)

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

# Capture the SessionStart event JSON. Its `source` field (startup/clear/
# compact, per the matcher) selects the session-agent directive variant below
# — a compacted session needs a RE-ORIENT directive, not the "first action
# this session" kickoff (whose skip-condition would otherwise suppress
# re-orienting exactly when the orient context was just compacted away).
# <TEAM>-360: the Claude twin gained this compact-awareness; the codex
# twin was wired for startup|clear|compact but ignored the event type. jq is
# guaranteed here (checked above); on malformed/empty input `.source` resolves
# to empty → kickoff directive (the safe default, identical to prior behavior).
# Lowercase-normalize for bash↔PS parity (the PS twin's -eq is
# case-insensitive; bash == is not).
EVENT_JSON="$(cat)"
SESSION_SOURCE="$(printf '%s' "$EVENT_JSON" | jq -r '.source // empty' 2>/dev/null | tr '[:upper:]' '[:lower:]')"

# --- 1. agentic-os-template git-log block -----------------------------------------
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

# --- 1b. Config-freshness nudge -----------------------------------------
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
    # stall SessionStart and sink the OTHER blocks' emission. Prefer GNU
    # `timeout`, fall back to `gtimeout` (macOS coreutils); without either it
    # runs unbounded (graceful degradation). A timeout kill yields rc 124 ≠ 1
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

## ⚠ Installed config is stale — re-run install.sh

${stale_count} framework source file(s) changed since your last \`install.sh\`
render, so your live config may be running outdated hooks/capabilities.
check-drift won't catch this (it detects hand-edits, not staleness). Re-sync:

    bash \$AI_CONFIG_DIR/scripts/install.sh --harness claude --harness codex

Stale source(s):
$(printf '%s\n' "$stale_list" | sed 's/^/- /')

Disable this check: env \`CLAUDE_SKIP_FRESHNESS_CHECK=1\`."
    fi
  fi
fi

# --- 2. Session-agent invocation directive ---------------------
# Auto-fire mechanism for the session-agent spine capability. Emits one
# directive instructing the model to invoke session-agent as its first action
# (Mode 1: kickoff orient). Single trigger per session — the only mechanism
# that fires session-agent at session start (AGENTS.md prose and the
# PreToolUse hook are not duplicate triggers; PreToolUse is a safety net for
# file-modifying tool use, not a session-start trigger).
SA_BLOCK=""
if [[ "${CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE:-0}" != "1" ]]; then
  if [[ "$SESSION_SOURCE" == "compact" ]]; then
    # Post-compaction re-orient (<TEAM>-360; mirrors the Claude twin). The
    # matcher includes `compact`, so this hook re-fires after a compaction —
    # but the stock kickoff directive's "skip if already invoked this session"
    # clause can make the model SKIP re-orienting right when its Mode 1 orient
    # outputs were just summarized out of context. Emit an IDEMPOTENT
    # re-orient instead: re-run Mode 1 ONLY if the orient outputs are gone,
    # else a cheap Mode 2 route — so it cannot blindly double-orient on every
    # compaction. Leading blank line separates this block from the one above.
    SA_BLOCK="

## Session-agent — re-orient after compacted session

This session was just compacted; your earlier \`\$session-agent\` Mode 1 orient
context (memory bodies, Linear project/issue state, vault \`START.md\`) may have
been summarized out of context. Re-establish orientation:

- If those orient outputs are NO LONGER in your context, re-invoke
  \`\$session-agent\` (Mode 1) to rebuild them.
- If they are still present, do NOT re-run the orient — a Mode 2 route on the
  next non-trivial prompt is enough.

Disable this directive entirely: env \`CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE=1\`."
  else
    # Fresh session (startup / clear / unknown source): the kickoff directive.
    # Leading blank line separates this block from the git-log block above.
    SA_BLOCK="

## Session-agent — invoke now (Mode 1: kickoff orient)

The \`\$session-agent\` capability is the spine. **Your first action this session
must be to invoke \`\$session-agent\`** — Mode 1 fires the kickoff orient
(memory body-reads + Linear projects-first query + vault \`START.md\` +
reconcile this session-start window's commits against memory headlines), then
routes the user's first request.

On every subsequent non-trivial prompt, re-invoke \`\$session-agent\` (Mode 2:
route only — Mode 1's orient outputs are still live in context).

Skip this directive if you have already invoked session-agent this session.
Disable the directive entirely: env \`CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE=1\`."
  fi
fi

# Nothing to surface from any block → quiet exit.
if [[ -z "$GIT_BLOCK" && -z "$FRESH_BLOCK" && -z "$SA_BLOCK" ]]; then
  exit 0
fi

CONTEXT="${GIT_BLOCK}${FRESH_BLOCK}${SA_BLOCK}"

# Emit JSON via jq for safe escaping.
jq -nR --arg ctx "$CONTEXT" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
