#!/usr/bin/env bash
# Stuck-detector hook (Claude Code PostToolUseFailure + PostToolUse events, matcher Bash).
# Converts the operator's cross-model rescue rule ("hand to a critic after
# repeated failure of the same probe") from routing-time prose into an act-time
# signal. The rule's trigger condition — "I am stuck" — suppresses its own
# recall: a session deep in a retry loop is in exactly the state least likely
# to step back, so this hook watches the failure stream mechanically and
# injects the reminder at the moment it applies. The rescue capability itself
# is operator-local (Shape C) — the framework never names it; the
# RESCUE_INVOCATION render token in the reminder below is substituted at
# render time from local.env's optional RESCUE_SKILL_NAME (generic phrasing
# when unset; install validates the name against a strict allowlist so config
# can never inject into this generated source).
#
# ONE script, TWO event wirings (see harnesses/claude/adapter.md Fact 2):
#   PostToolUseFailure / Bash — a command failed (non-zero exit): count it.
#   PostToolUse        / Bash — a command succeeded: reset that command's streak.
# Claude Code routes a non-zero-exit Bash call to PostToolUseFailure (verified
# live on v2.1.209: `.error` carries "Exit code N\n<stderr>", tool_response is
# null; a succeeding call fires PostToolUse with {stdout,stderr,...} and no
# exit code anywhere — so the EVENT, not the payload, is the failure signal).
#
# Behavior: the 3rd qualifying failure of the same normalized command with no
# intervening success of that command emits ONE additionalContext reminder
# naming the operator's rescue lane. Exactly one reminder per command
# hash per session — repeat firing is alarm fatigue, and alarm fatigue trains
# sessions to ignore the gate (Guard-pitfalls lesson). A success resets the
# streak but the fired flag stays sticky.
#
# Failure qualification (false-fire budget is near zero by design):
#   - event PostToolUseFailure with tool_name Bash
#   - .is_interrupt is not true       (an operator interrupt is not a failure)
#   - .error starts with "Exit code"  (a command that RAN and failed — permission
#                                      denials and harness-level errors carry
#                                      different error text and never count)
#
# Normalization is deliberately minimal: trim, collapse whitespace runs, cap at
# 2000 bytes, hash. Verbatim re-runs of the same probe (the actual stuck
# pattern) hash identically; any textual variation counts as a distinct
# command. Aggressive stripping of "volatile" args/paths was considered and
# rejected: it can only convert distinct commands into shared streaks (false
# fires), while under-normalization merely under-counts — the safe direction.
# (Accepted residual: the bash twin normalizes in C-locale bytes and the PS
# twin in Unicode characters — state never crosses hosts and only one twin
# runs per host, so the divergence is unobservable; the injected snippet is
# sanitized to printable ASCII in both twins so it is always jq/JSON-safe.)
#
# Concurrency: parallel Bash calls fire hooks concurrently, so the state
# read-modify-write runs under a per-session mkdir lock. Contention SKIPS the
# event (bounded retries, fail open — one lost count is the safe direction;
# a blocked Bash tool is not). A stale lock (crashed holder) is stolen after
# ~60s. The reminder is emitted ONLY after the fired flag has been durably
# persisted — a state-write failure stays silent rather than re-alarming on
# every subsequent failure (panel finding).
#
# State: <install>/agentic-os/stuck-<session_id>, one line per FAILING command
# hash: "<hash> <count> <fired>". Successes never create records — they only
# reset an existing streak (and a fully-reset "0 0" record is dropped), so
# ordinary varied work cannot grow the file (panel finding). Same directory +
# reap policy as the session-agent gate markers (mtime +7d).
#
# stdin:  PostToolUseFailure / PostToolUse hook event JSON
# stdout: when firing, JSON with hookSpecificOutput.additionalContext
# exit:   always 0 (surfacing hook — fails OPEN; a missing reminder is not a
#         safety risk, a wedged Bash tool is)
#
# Kill switch: CLAUDE_SKIP_STUCK_DETECTOR=1

set -uo pipefail

STREAK_THRESHOLD=3

# Consume stdin BEFORE any early exit: a hook that exits without reading its
# pipe sends SIGPIPE to the harness-side writer (observed as a CI-only broken
# pipe under pipefail). Reading first costs nothing on a surfacing hook.
INPUT="$(cat)"

if [[ "${CLAUDE_SKIP_STUCK_DETECTOR:-0}" == "1" ]]; then
  exit 0
fi

# jq contract — surfacing hook, fails OPEN: without jq the payload cannot be
# parsed and no reminder can be safely emitted; stay silent.
command -v jq >/dev/null 2>&1 || exit 0

EVENT="$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty')"
TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')"
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty')"

[[ "$TOOL_NAME" == "Bash" ]] || exit 0
case "$EVENT" in PostToolUse|PostToolUseFailure) ;; *) exit 0 ;; esac

# Session id keys the state file path — sanitize to a path-safe alphabet
# (superset of UUIDs), same contract as the session-agent gate marker. An id
# that fails the check disables the detector for this event; nothing else.
if [[ "$SESSION_ID" =~ ^[[:space:]]*([A-Za-z0-9-]+)[[:space:]]*$ ]]; then
  SESSION_ID="${BASH_REMATCH[1]}"
else
  exit 0
fi

SD_INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
[[ -n "$SD_INSTALL_DIR" ]] || exit 0
STATE_DIR="$SD_INSTALL_DIR/agentic-os"
STATE_FILE="$STATE_DIR/stuck-$SESSION_ID"

# Cheap path: a success with no recorded state has nothing to reset.
if [[ "$EVENT" == "PostToolUse" && ! -f "$STATE_FILE" ]]; then
  exit 0
fi

# Failure qualification (see header). is_interrupt defaults false when absent.
if [[ "$EVENT" == "PostToolUseFailure" ]]; then
  INTERRUPT="$(printf '%s' "$INPUT" | jq -r '.is_interrupt // false')"
  [[ "$INTERRUPT" == "true" ]] && exit 0
  ERR_HEAD="$(printf '%s' "$INPUT" | jq -r '.error // "" | .[0:16]')"
  case "$ERR_HEAD" in "Exit code"*) ;; *) exit 0 ;; esac
fi

COMMAND="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')"
[[ -n "$COMMAND" ]] || exit 0

# Normalize: collapse every whitespace run (newlines included) to one space,
# trim, cap at 2000 bytes. LC_ALL=C pins byte semantics (single-locale lesson).
NORM="$(printf '%s' "$COMMAND" | LC_ALL=C tr -s '[:space:]' ' ')"
NORM="${NORM# }"; NORM="${NORM% }"
NORM="${NORM:0:2000}"

# Hash the normalized command with sha256 (sha256sum on Linux, shasum on
# macOS, openssl anywhere else). NO weak fallback: identity decisions on a
# collision-prone digest can merge distinct commands into one streak (panel
# finding) — with no sha256 provider the detector fails OPEN instead.
if command -v sha256sum >/dev/null 2>&1; then
  HASH="$(printf '%s' "$NORM" | sha256sum | cut -d' ' -f1)"
elif command -v shasum >/dev/null 2>&1; then
  HASH="$(printf '%s' "$NORM" | shasum -a 256 | cut -d' ' -f1)"
elif command -v openssl >/dev/null 2>&1; then
  HASH="$(printf '%s' "$NORM" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')"
else
  exit 0
fi
[[ "$HASH" =~ ^[0-9a-f]{64}$ ]] || exit 0

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
# Reap stale per-session state (old sessions); never fails the hook.
find "$STATE_DIR" -maxdepth 1 -name 'stuck-*' -mtime +7 -delete 2>/dev/null || true

# Per-session lock: serialize the read-modify-write against concurrent hook
# invocations (parallel Bash calls). Contention skips the event after bounded
# retries — losing one count under-fires, the safe direction. A lock left by
# a crashed holder is stolen once it is over a minute old.
LOCK_DIR="$STATE_FILE.lock"
SD_LOCKED=0
for _ in 1 2 3; do
  if mkdir "$LOCK_DIR" 2>/dev/null; then SD_LOCKED=1; break; fi
  if [[ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +1 2>/dev/null)" ]]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
    continue
  fi
  sleep 0.2
done
[[ "$SD_LOCKED" == "1" ]] || exit 0
sd_unlock() { rmdir "$LOCK_DIR" 2>/dev/null || true; }
trap sd_unlock EXIT

# Read this hash's record. State lines: "<hash> <count> <fired>".
COUNT=0; FIRED=0; HAVE_REC=0
if [[ -f "$STATE_FILE" ]]; then
  # Pathological-size guard: >500 distinct FAILING hashes in one session
  # (successes never create records) — drop the file rather than scan forever.
  if [[ "$(wc -l < "$STATE_FILE" 2>/dev/null || echo 0)" -gt 500 ]]; then
    rm -f "$STATE_FILE"
  else
    REC="$(grep "^$HASH " "$STATE_FILE" 2>/dev/null | head -n1)"
    if [[ -n "$REC" ]]; then
      HAVE_REC=1
      COUNT="$(printf '%s' "$REC" | cut -d' ' -f2)"
      FIRED="$(printf '%s' "$REC" | cut -d' ' -f3)"
      [[ "$COUNT" =~ ^[0-9]+$ ]] || COUNT=0
      [[ "$FIRED" =~ ^[01]$ ]] || FIRED=0
    fi
  fi
fi

if [[ "$EVENT" == "PostToolUse" ]]; then
  # Success: only an existing streak is affected — never create a record for
  # an unseen hash (ordinary varied work must not grow the state file), and
  # drop a record that fully resets to "0 0" (fired stays sticky as "0 1").
  [[ "$HAVE_REC" == "1" ]] || exit 0
  COUNT=0
else
  COUNT=$((COUNT + 1))
fi

EMIT=0
if [[ "$EVENT" == "PostToolUseFailure" && "$COUNT" -ge "$STREAK_THRESHOLD" && "$FIRED" == "0" ]]; then
  EMIT=1
  FIRED=1
fi

# Rewrite the record (temp + mv keeps the file whole under interruption).
# Only well-formed records are preserved — blank/malformed lines are filtered
# so corruption cannot accumulate toward the size guard (panel finding).
TMP="$STATE_FILE.tmp.$$"
PERSISTED=0
{
  [[ -f "$STATE_FILE" ]] && grep -v "^$HASH " "$STATE_FILE" 2>/dev/null | grep -E '^[0-9a-f]{64} [0-9]+ [01]$'
  if [[ "$COUNT" -gt 0 || "$FIRED" == "1" ]]; then
    printf '%s %s %s\n' "$HASH" "$COUNT" "$FIRED"
  fi
} > "$TMP" 2>/dev/null && mv -f "$TMP" "$STATE_FILE" 2>/dev/null && PERSISTED=1
rm -f "$TMP" 2>/dev/null || true

# Emit ONLY after the fired flag is durably persisted: if the write failed,
# the next failure would re-read fired=0 and alarm again — a fail-open
# storage problem must not become repeated alarm injection (panel finding).
if [[ "$EMIT" == "1" && "$PERSISTED" == "1" ]]; then
  # Twin-parity contract: this user-facing reminder string must stay identical
  # in stuck-detector.ps1 (count-string drift trap). The snippet is sanitized
  # to backtick-free printable ASCII in both twins so the message is always
  # JSON-safe and its inline code span cannot be broken by the command text.
  CMD_SNIP="$(printf '%s' "$NORM" | LC_ALL=C tr -d '`' | LC_ALL=C tr -cd '[:print:]')"
  CMD_SNIP="${CMD_SNIP:0:120}"
  MSG="Stuck-detector: this Bash command has now failed ${STREAK_THRESHOLD} times this session with no intervening success: \`${CMD_SNIP}\`. Rescue rule: stop retrying — @@RESCUE_INVOCATION@@ (rescue lane: hand the failure to a different model family) before attempting retry 4. Kill switch: env CLAUDE_SKIP_STUCK_DETECTOR=1."
  OUT="$(jq -nc --arg ctx "$MSG" \
    '{hookSpecificOutput: {hookEventName: "PostToolUseFailure", additionalContext: $ctx}}' 2>/dev/null)"
  [[ -n "$OUT" ]] && printf '%s\n' "$OUT"
fi

exit 0
