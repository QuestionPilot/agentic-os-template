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
#   CLAUDE_SKIP_DISTILLATION_NUDGE=1        disables just the distillation-lag nudge
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

# --- 1c. Distillation-lag nudge ---------------------------------
# READ-ONLY kickoff surfacing of scripts/check-distillation-completeness.sh
# (<TEAM>-364; mirrors the claude twin's block 2b): when one or more
# feedback/decision memory notes have not been distilled into the vault's
# 04-Lessons layer, say so at session start instead of letting the lapse sit
# invisible until a wipe/migration boundary. A design panel explicitly
# REJECTED a background auto-distillation writer (a silent-write +
# prompt-injection surface), so this block only reads and reports — it never
# writes to the vault or the memory store; the distillation itself stays with
# the operator-driven closeout capability. Fail-open: missing checker,
# unresolvable dirs (checker exit 2), timeout kill (rc 124), or any rc other
# than 1 → block omitted, never a hook failure.
DIST_BLOCK=""
if [[ "${CLAUDE_SKIP_DISTILLATION_NUDGE:-0}" != "1" ]]; then
  DIST_SCRIPT="$AI_CONFIG_DIR/scripts/check-distillation-completeness.sh"
  if [[ -f "$DIST_SCRIPT" ]]; then
    # The checker derives its dirs from CLAUDE_CONFIG_DIR + OBSIDIAN_VAULT_PATH,
    # either of which may be unset in the hook environment. Resolve both
    # fail-open from the framework repo's local.env — read as DATA, never
    # sourced (sourcing would execute arbitrary operator-file code inside a
    # session-start hook, and a hostile PATH= line could poison every command
    # lookup here; modeled on scripts/self-audit.sh _sa_localenv_get,
    # deliberately smaller). Unlike the claude twin there is NO install-dir
    # fallback for the config dir: this hook's install dir is CODEX_HOME,
    # which does not hold the projects/*/memory store the checker scans.
    # _dist_localenv_get <key> — LAST KEY= assignment (last wins, like bash
    # sourcing), trailing whitespace trimmed, one surrounding quote pair
    # stripped.
    _dist_localenv_get() {
      local v
      v="$(grep -E "^[[:space:]]*(export[[:space:]]+)?$1=" "$AI_CONFIG_DIR/local.env" 2>/dev/null \
        | tail -n 1 | sed -E "s/^[[:space:]]*(export[[:space:]]+)?$1=//; s/[[:space:]]+\$//")"
      case "$v" in
        \"*\") v="${v#\"}"; v="${v%\"}" ;;
        \'*\') v="${v#\'}"; v="${v%\'}" ;;
      esac
      printf '%s' "$v"
    }
    DIST_CFG="${CLAUDE_CONFIG_DIR:-}"
    [[ -z "$DIST_CFG" ]] && DIST_CFG="$(_dist_localenv_get CLAUDE_CONFIG_DIR)"
    DIST_VAULT="${OBSIDIAN_VAULT_PATH:-}"
    [[ -z "$DIST_VAULT" ]] && DIST_VAULT="$(_dist_localenv_get OBSIDIAN_VAULT_PATH)"
    # A dir left unresolved is NOT pre-guarded beyond the cheap fallbacks
    # above — the checker itself exits 2 on an unresolvable path, which stays
    # silent here. Bound the run like the freshness block (prefer GNU
    # `timeout`, fall back to `gtimeout`; without either it runs unbounded —
    # same graceful degradation).
    DIST_TIMEOUT=""
    if command -v timeout >/dev/null 2>&1; then DIST_TIMEOUT="timeout 5"
    elif command -v gtimeout >/dev/null 2>&1; then DIST_TIMEOUT="gtimeout 5"; fi
    dist_rc=0
    dist_out="$(CLAUDE_CONFIG_DIR="$DIST_CFG" OBSIDIAN_VAULT_PATH="$DIST_VAULT" \
      $DIST_TIMEOUT bash "$DIST_SCRIPT" 2>&1)" || dist_rc=$?
    # ONLY a confirmed lapse (rc 1) surfaces; 0 (all distilled), 2 (usage /
    # unresolvable dirs), 124 (timeout kill), and any other rc stay silent.
    if [[ "$dist_rc" -eq 1 ]]; then
      # `FAIL undistilled: <name> — …` lines carry the note names in field 3
      # (memory-note filenames are slugs — they never contain spaces).
      # Sorted for cross-twin determinism: the bash checker walks find order,
      # the PS twin sorts — sorting here keeps the surfaced top-5 excerpt
      # identical on both sides (same posture as the MCP block's sort).
      dist_names="$(printf '%s\n' "$dist_out" | awk '/^FAIL undistilled: /{print $3}' | LC_ALL=C sort)"
      if [[ -n "$dist_names" ]]; then
        dist_count="$(printf '%s\n' "$dist_names" | grep -c .)"
        dist_list="$(printf '%s\n' "$dist_names" | head -5 | sed 's/^/- /')"
        if [[ "$dist_count" -gt 5 ]]; then
          dist_list="${dist_list}
- … and $((dist_count - 5)) more"
        fi
        # Leading blank line separates this block from the one above.
        DIST_BLOCK="

## Distillation lag — ${dist_count} feedback/decision note(s) not yet distilled

${dist_list}

These feedback/decision memory notes have not been promoted into the vault's
04-Lessons layer. Promote each into its thematic 04-Lessons note at the next
closeout (capabilities/closeout.md → \"Distill this session's feedback\"). This
nudge is a read-only lint — it changed nothing. Full list: \`bash
scripts/check-distillation-completeness.sh\`.
Disable this nudge: env \`CLAUDE_SKIP_DISTILLATION_NUDGE=1\`."
      fi
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
if [[ -z "$GIT_BLOCK" && -z "$FRESH_BLOCK" && -z "$DIST_BLOCK" && -z "$SA_BLOCK" ]]; then
  exit 0
fi

CONTEXT="${GIT_BLOCK}${FRESH_BLOCK}${DIST_BLOCK}${SA_BLOCK}"

# Emit JSON via jq for safe escaping.
jq -nR --arg ctx "$CONTEXT" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
