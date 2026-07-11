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
#   CLAUDE_SKIP_DISTILLATION_NUDGE=1        disables just the distillation-lag nudge
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
    # fallback for the config dir: this hook's install dir is HERMES_HOME,
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
the full declaration (including the \`Linear gate:\` and \`Lessons:\` lines) as its content."
    fi
  fi
fi

# Nothing to surface from any block → quiet exit.
if [[ -z "$GIT_BLOCK" && -z "$FRESH_BLOCK" && -z "$DIST_BLOCK" && -z "$SA_BLOCK" ]]; then
  exit 0
fi

CONTEXT="${GIT_BLOCK}${FRESH_BLOCK}${DIST_BLOCK}${SA_BLOCK}"

# Sentinel dedup applies only when the first-turn signal was absent (above);
# mark this session surfaced so a later turn stays silent. Best-effort — never
# affects this hook's output or exit code.
if [[ -n "$SENTINEL" ]]; then
  mkdir -p "$(dirname "$SENTINEL")" 2>/dev/null && : > "$SENTINEL" 2>/dev/null || true
fi

# Emit Hermes context-injection JSON via jq for safe escaping. Hermes injects
# the context into the user message (first turn only — gated above).
jq -nR --arg ctx "$CONTEXT" '{context: $ctx}'
