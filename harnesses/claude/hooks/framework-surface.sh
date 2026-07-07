#!/usr/bin/env bash
# Framework-changes + MCP-health surfacing hook (Claude Code SessionStart event).
# Two independent blocks emitted in one additionalContext payload:
#   1. agentic-os-template git log (last N days) — picks up improvements from prior sessions
#   2. `claude mcp list` ✓ Connected MCPs — surfaces the <TEAM>-59 silent-empty-tools
#      failure mode (CLI reports Connected while the deferred-tool catalog is empty)
# Filtered to startup/clear/compact via the settings.json matcher. Not tied to any
# capability — wired unconditionally by the build.
#
# @@AI_CONFIG_DIR@@ is a build placeholder: install.sh substitutes the absolute
# path to the agentic-os-template checkout from local.env (see harnesses/claude/adapter.md).
#
# Kill switches:
#   CLAUDE_SKIP_FRAMEWORK_SURFACE=1         disables the whole hook
#   CLAUDE_SKIP_FRESHNESS_CHECK=1           disables just the config-freshness nudge
#   CLAUDE_SKIP_LOCAL_HOOK_CHECK=1          disables just the orphaned-local-hook check
#   CLAUDE_SKIP_MCP_PROBE=1                 disables just the MCP-health block
#   CLAUDE_SKIP_DISTILLATION_NUDGE=1        disables just the distillation-lag nudge
#   CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE=1   disables just the session-agent auto-fire directive
# Window:
#   CLAUDE_FRAMEWORK_SINCE_DAYS=N    overrides git-log window (default 10)
#
# stdin:  SessionStart event JSON — `.source` (startup/clear/compact via the
#         matcher) selects the session-agent directive variant; rest unused
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
# — a compacted session needs a RE-ORIENT directive, not the "first action this
# session" kickoff (whose skip-condition would otherwise suppress re-orienting
# exactly when the orient context was just compacted away). Everything else in
# the payload is unused. jq is guaranteed here (checked above); on malformed/
# empty input `.source` resolves to empty → kickoff directive (the safe default,
# identical to prior behavior).
EVENT_JSON="$(cat)"
# Lowercase-normalize for bash↔PS parity: the PS twin's `-eq` is case-insensitive,
# so canonicalize here too (bash `==` is case-sensitive). Source is documented
# lowercase; this just keeps the twins provably identical. tr is bash-3.2 safe.
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
    # runs unbounded (same graceful degradation as the MCP probe). A timeout
    # kill yields rc 124 ≠ 1 → no nudge (fail-open).
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

# --- 1c. Orphaned operator-local hook check ---------------------
# Catch the silent-drop failure mode: an operator-local hook wired in
# settings.local.json whose target script no longer exists on disk (e.g. a
# migration moved the config dir but didn't carry the operator-local file).
# Claude loads settings.local.json hooks, but a missing command file just
# no-ops silently — so a dropped hook (a lost SessionStart nudge, a vanished
# safety gate) dies with no error. This block reads settings.local.json,
# collects every hook `command`, and warns on any LITERAL ABSOLUTE command path
# that does not exist on disk. The whole command string is tested first (so a
# path containing a space reads correctly), with a first-token fallback for the
# rare path-plus-args form. Scope is deliberately the literal-absolute subset;
# relative, $VAR/${VAR}/~, and inline commands are left unchecked — they can't be
# decisively proven missing, so no false positives. Fail-open: no settings file /
# no jq / parse error → silent.
LOCALHOOK_BLOCK=""
if [[ "${CLAUDE_SKIP_LOCAL_HOOK_CHECK:-0}" != "1" ]]; then
  # settings.local.json sits beside the hooks dir: <install>/settings.local.json
  # (this hook lives at <install>/hooks/). Resolve independently of block 1b's
  # INSTALL_DIR — each block carries its own kill switch and must stand alone.
  LH_INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
  LH_SETTINGS="$LH_INSTALL_DIR/settings.local.json"
  if [[ -n "$LH_INSTALL_DIR" && -f "$LH_SETTINGS" ]]; then
    # jq emits one command string per line; malformed JSON / odd shape → empty
    # → silent (the ? operators + 2>/dev/null keep a bad shape fail-open). Read
    # into a var + herestring (not `< <(jq…)` process substitution) so the loop
    # runs in THIS shell (lh_missing persists) without needing /dev/fd.
    lh_cmds="$(jq -r '.hooks // {} | to_entries[]? | .value[]? | .hooks[]? | .command // empty' "$LH_SETTINGS" 2>/dev/null)"
    lh_missing=""
    while IFS= read -r lh_cmd; do
      [[ -z "$lh_cmd" ]] && continue
      # Only LITERAL ABSOLUTE commands are decisively testable. A Claude hook
      # `command` is a bare script path (args live in a separate "args" field),
      # so test the WHOLE string first — this is what makes a path containing a
      # space (a config dir whose folder name contains a space) read correctly
      # instead of being truncated at the space into a false "missing" warning.
      # Fall back to the first token for the rare "exec arg1 arg2" form so a
      # real path-plus-args isn't a false positive. Warn naming the FULL command.
      # Out of scope (left unchecked, no false positives): relative paths
      # (cwd-dependent) and unexpanded $VAR / ${VAR} / ~ forms.
      case "$lh_cmd" in
        /*)
          if [[ ! -e "$lh_cmd" ]]; then
            read -r lh_first _ <<<"$lh_cmd"
            [[ -e "$lh_first" ]] || lh_missing="${lh_missing}- ${lh_cmd}"$'\n'
          fi
          ;;
      esac
    done <<<"$lh_cmds"
    if [[ -n "$lh_missing" ]]; then
      LOCALHOOK_BLOCK="

## ⚠ Operator-local hook is missing its script

\`settings.local.json\` wires one or more hooks whose target file does not exist
on disk. Claude loads these settings, but a missing command silently no-ops — so
the hook is dead with no error. This usually means a migration or cleanup moved
the config dir without carrying the operator-local script. Restore the file(s),
or remove the stale entry from \`settings.local.json\`:

${lh_missing}
Disable this check: env \`CLAUDE_SKIP_LOCAL_HOOK_CHECK=1\`."
    fi
  fi
fi

# --- 2. MCP-health probe block ---------------------------------
# Lists MCPs reported `✓ Connected` by `claude mcp list` so the session can
# spot the <TEAM>-59 silent-empty-tools case (CLI says connected, deferred-tool
# catalog is empty). Probe is fail-open: missing claude CLI, parse error,
# probe stall, or kill switch all reduce to "no block".
MCP_BLOCK=""
if [[ "${CLAUDE_SKIP_MCP_PROBE:-0}" != "1" ]] && command -v claude >/dev/null 2>&1; then
  # Bound the probe so a stalled CLI doesn't hang SessionStart. Prefer GNU
  # `timeout` (Linux); fall back to `gtimeout` (macOS via Homebrew coreutils).
  # Without either, the probe runs unbounded — bounded only by `claude mcp
  # list`'s own internal timeouts.
  TIMEOUT_CMD=""
  if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout 5"
  elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout 5"
  fi

  # Capture the probe's rc so a timeout-killed CLI (rc=124) doesn't leak
  # partial output as if it were complete. Discard `mcp_out` on any non-zero
  # exit — partial data is misleading data here.
  mcp_out=""
  mcp_rc=0
  if [[ -n "$TIMEOUT_CMD" ]]; then
    mcp_out="$($TIMEOUT_CMD claude mcp list 2>/dev/null)" || mcp_rc=$?
  else
    mcp_out="$(claude mcp list 2>/dev/null)" || mcp_rc=$?
  fi
  [ "$mcp_rc" -eq 0 ] || mcp_out=""
  if [[ -n "$mcp_out" ]]; then
    # `claude mcp list` lines:  <source-prefix>: <url-or-cmd> - <status>
    # We want the connected ones, trimmed to the prefix (e.g. "claude.ai Linear"
    # or a plugin MCP like "plugin:<name>:<name>"). Sed strips from the first ": " onward.
    connected="$(printf '%s\n' "$mcp_out" \
      | grep -E ' - ✓ Connected$' \
      | sed -E 's/: .*//' \
      | LC_ALL=C sort -u)"
    if [[ -n "$connected" ]]; then
      count="$(printf '%s\n' "$connected" | wc -l | tr -d ' ')"
      # Leading blank line separates this block from the git-log block above.
      MCP_BLOCK="

## MCP connectors (per \`claude mcp list\`) — ${count} ✓ Connected

$(printf '%s\n' "$connected" | sed 's/^/- /')

If any of these MCPs are missing their tools from your session (\`ToolSearch\`
returns no matches for known tool names), this is the <TEAM>-59 silent-empty-tools
failure mode. Restart Claude Code to populate the deferred-tool catalog.
See \`reference_mcp_silent_empty_tools\` for the full pattern. Disable this probe: env \`CLAUDE_SKIP_MCP_PROBE=1\`."
    fi
  fi
fi

# --- 2b. Distillation-lag nudge ---------------------------------
# READ-ONLY kickoff surfacing of scripts/check-distillation-completeness.sh
# (<TEAM>-364): when one or more feedback/decision memory notes have not been
# distilled into the vault's 04-Lessons layer, say so at session start instead
# of letting the lapse sit invisible until a wipe/migration boundary. A design
# panel explicitly REJECTED a background auto-distillation writer (a
# silent-write + prompt-injection surface), so this block only reads and
# reports — it never writes to the vault or the memory store; the distillation
# itself stays with the operator-driven closeout capability. Fail-open:
# missing checker, unresolvable dirs (checker exit 2), timeout kill (rc 124),
# or any rc other than 1 → block omitted, never a hook failure.
DIST_BLOCK=""
if [[ "${CLAUDE_SKIP_DISTILLATION_NUDGE:-0}" != "1" ]]; then
  DIST_SCRIPT="$AI_CONFIG_DIR/scripts/check-distillation-completeness.sh"
  if [[ -f "$DIST_SCRIPT" ]]; then
    # The checker derives its dirs from CLAUDE_CONFIG_DIR + OBSIDIAN_VAULT_PATH,
    # either of which may be unset in the hook environment. Resolve both
    # fail-open: the config dir falls back to this hook's own install dir
    # (hooks live at <install>/hooks/, and for the claude harness the install
    # dir IS the config dir); the vault path falls back to the
    # OBSIDIAN_VAULT_PATH key in the framework repo's local.env.
    DIST_CFG="${CLAUDE_CONFIG_DIR:-}"
    if [[ -z "$DIST_CFG" ]]; then
      DIST_CFG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
    fi
    DIST_VAULT="${OBSIDIAN_VAULT_PATH:-}"
    if [[ -z "$DIST_VAULT" && -f "$AI_CONFIG_DIR/local.env" ]]; then
      # Minimal no-exec read of ONE key (modeled on scripts/self-audit.sh
      # _sa_localenv_get, deliberately smaller). Sourcing local.env here is
      # forbidden: it would execute arbitrary operator-file code inside a
      # SessionStart hook, and a hostile PATH= line could poison every command
      # lookup in this hook. Read the LAST OBSIDIAN_VAULT_PATH= assignment as
      # DATA (last wins, like bash sourcing), trim trailing whitespace, and
      # strip one matching surrounding quote pair.
      DIST_VAULT="$(grep -E '^[[:space:]]*(export[[:space:]]+)?OBSIDIAN_VAULT_PATH=' "$AI_CONFIG_DIR/local.env" 2>/dev/null \
        | tail -n 1 | sed -E 's/^[[:space:]]*(export[[:space:]]+)?OBSIDIAN_VAULT_PATH=//; s/[[:space:]]+$//')"
      case "$DIST_VAULT" in
        \"*\") DIST_VAULT="${DIST_VAULT#\"}"; DIST_VAULT="${DIST_VAULT%\"}" ;;
        \'*\') DIST_VAULT="${DIST_VAULT#\'}"; DIST_VAULT="${DIST_VAULT%\'}" ;;
      esac
    fi
    # A dir left unresolved is NOT pre-guarded beyond the cheap fallbacks
    # above — the checker itself exits 2 on an unresolvable path, which stays
    # silent here. Bound the run like the other blocks (prefer GNU `timeout`,
    # fall back to `gtimeout`; without either it runs unbounded — same
    # graceful degradation). Computed locally: the MCP block's TIMEOUT_CMD
    # lives inside that block's own `if` and is absent when the probe is
    # skipped.
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
        # Leading blank line separates this block from the MCP block above.
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

# --- 3. Session-agent invocation directive ---------------------
# Auto-fire mechanism for the session-agent spine capability. Emits one
# directive instructing the model to invoke session-agent as its first action
# (Mode 1: kickoff orient). Single trigger per session — the only mechanism
# that fires session-agent at session start (CLAUDE.md prose and the
# PreToolUse hook are not duplicate triggers; PreToolUse is a safety net for
# file-modifying tool use, not a session-start trigger).
SA_BLOCK=""
if [[ "${CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE:-0}" != "1" ]]; then
  if [[ "$SESSION_SOURCE" == "compact" ]]; then
    # Post-compaction re-orient. The SessionStart matcher includes
    # `compact`, so this hook re-fires after a compaction and re-injects — but
    # the stock kickoff directive's "skip if already invoked this session"
    # clause can make the model SKIP re-orienting right when its Mode 1 orient
    # outputs were just summarized out of context. Emit an IDEMPOTENT re-orient
    # instead: re-run Mode 1 ONLY if the orient outputs are gone, else a cheap
    # Mode 2 route — so it cannot blindly double-orient on every compaction.
    # (`resume` is NOT in the matcher, so it never reaches this hook — and a
    # resumed session reloads its transcript, keeping the orient in context.)
    # Leading blank line separates this block from the MCP block above.
    SA_BLOCK="

## Session-agent — re-orient after compacted session

This session was just compacted; your earlier \`session-agent\` Mode 1 orient
context (memory bodies, Linear project/issue state, vault \`START.md\`) may have
been summarized out of context. Re-establish orientation:

- If those orient outputs are NO LONGER in your context, re-invoke
  \`session-agent\` (Mode 1) to rebuild them.
- If they are still present, do NOT re-run the orient — a Mode 2 route on the
  next non-trivial prompt is enough.

Disable this directive entirely: env \`CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE=1\`."
  else
    # Fresh session (startup / clear / unknown source): the kickoff directive.
    # Per-session gate-marker pointer (<TEAM>-365): the pre-edit gate accepts
    # the R5 declaration from a marker file at <install>/agentic-os/
    # gate-<session_id> — the ONLY channel that works on harness variants
    # (desktop/SDK) whose transcript does not persist assistant text blocks.
    # The model cannot reliably learn its own session_id, so this directive is
    # the canonical place the exact path is surfaced (the pre-edit deny
    # message repeats it as a recovery path). session_id is sanitized to the
    # path-safe alphabet (letters/digits/hyphen) before being embedded in a path; a non-conforming id just
    # drops the pointer (fail-open — the transcript channel still applies).
    SA_GATE_NOTE=""
    SA_SESSION_ID="$(printf '%s' "$EVENT_JSON" | jq -r '.session_id // empty' 2>/dev/null)"
    if [[ "$SA_SESSION_ID" =~ ^[[:space:]]*([A-Za-z0-9-]+)[[:space:]]*$ ]]; then
      SA_SESSION_ID="${BASH_REMATCH[1]}"
      SA_INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
      if [[ -n "$SA_INSTALL_DIR" ]]; then
        SA_GATE_NOTE="

After emitting the R5 routing declaration, ALSO persist it to the pre-edit
gate's marker file — on harness variants that do not persist assistant text
into the transcript (desktop/SDK), the marker is the only declaration channel
the gate can see; elsewhere it is a harmless no-op. Write the declaration
(including the \`Linear gate:\` line) to:

    $SA_INSTALL_DIR/agentic-os/gate-$SA_SESSION_ID

via a Bash heredoc (mkdir -p the directory first) or the Write tool — a Write
to that exact path is allowed through the gate."
      fi
    fi
    # Leading blank line separates this block from the MCP block above.
    SA_BLOCK="

## Session-agent — invoke now (Mode 1: kickoff orient)

The \`session-agent\` capability is the spine. **Your first action this session
must be to invoke \`session-agent\` via the Skill tool** — Mode 1 fires the
kickoff orient (memory body-reads + Linear projects-first query + vault
\`START.md\` + reconcile this session-start window's commits against memory
headlines), then routes the user's first request.

On every subsequent non-trivial prompt, re-invoke \`session-agent\` (Mode 2:
route only — Mode 1's orient outputs are still live in context).
${SA_GATE_NOTE}
Skip this directive if you have already invoked session-agent this session.
Disable the directive entirely: env \`CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE=1\`."
  fi
fi

# Nothing to surface from any block → quiet exit.
if [[ -z "$GIT_BLOCK" && -z "$FRESH_BLOCK" && -z "$LOCALHOOK_BLOCK" && -z "$MCP_BLOCK" && -z "$DIST_BLOCK" && -z "$SA_BLOCK" ]]; then
  exit 0
fi

CONTEXT="${GIT_BLOCK}${FRESH_BLOCK}${LOCALHOOK_BLOCK}${MCP_BLOCK}${DIST_BLOCK}${SA_BLOCK}"

# Emit JSON via jq for safe escaping.
jq -nR --arg ctx "$CONTEXT" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
