#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/stuck-detector.test.sh — behavioral acceptance for the stuck-detector
# hook (the act-time gate for the cross-model-review rescue rule).
#
# Contract under test (harnesses/claude/hooks/stuck-detector.sh):
#   - 3rd qualifying PostToolUseFailure of the same normalized Bash command
#     with no intervening success -> ONE additionalContext reminder naming the
#     cross-model-review rescue lane; 1st/2nd and every later failure of that
#     hash stay silent (exactly-once per hash per session).
#   - a PostToolUse success of that command resets the streak.
#   - distinct commands never trigger; whitespace variants count as the same
#     command (minimal normalization).
#   - interrupts and non-"Exit code" errors (permission denials, harness
#     errors) never count — the false-fire budget is near zero by design.
#   - state is per-session, path-safe, and reaped at +7 days.
#   - surfacing hook: every path exits 0 (fails OPEN).
# Wiring under test (install.sh): ONE script registered on TWO events — the
# full-record dedupe in install_hook must keep both registrations.

fix_dir="$REPO_ROOT/tests/fixtures"

# Build the hooks once into a throwaway target (same pattern as hooks-behavior).
SD_OUT="$(mktemp -d)/target"; mkdir -p "$SD_OUT"
SD_ENV="$(mktemp -d)/local.env"
make_local_env "$SD_ENV" "$SD_OUT"
AI_CONFIG_LOCAL_ENV="$SD_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1
SD_HOOK="$SD_OUT/hooks/stuck-detector.sh"
SD_STATE_DIR="$SD_OUT/agentic-os"

assert_file "stuck-detector: hook rendered into the build" "$SD_HOOK"

# --- settings.json wiring: one script, two events, both matcher Bash ---------
# This is the dedupe regression pin: install_hook once deduped on script name
# alone, which would silently drop the second event registration.
sd_wire_fail="$(jq -r '.hooks.PostToolUseFailure[]? | select(.hooks[]?.command | endswith("hooks/stuck-detector.sh")) | .matcher' "$SD_OUT/settings.json" 2>/dev/null)"
sd_wire_ok="$(jq -r '.hooks.PostToolUse[]? | select(.hooks[]?.command | endswith("hooks/stuck-detector.sh")) | .matcher' "$SD_OUT/settings.json" 2>/dev/null)"
assert_eq "stuck-detector: wired on PostToolUseFailure with matcher Bash" "Bash" "$sd_wire_fail"
assert_eq "stuck-detector: wired on PostToolUse with matcher Bash" "Bash" "$sd_wire_ok"

# --- payload builders ---------------------------------------------------------
# Shapes mirror the live v2.1.209 payloads (see adapter.md Fact 2): a failing
# Bash call fires PostToolUseFailure with .error "Exit code N\n<stderr>"; a
# succeeding one fires PostToolUse with a tool_response object and no exit code.
sd_fail_payload() { # <command> [session] [error] [is_interrupt]
  jq -nc --arg cmd "$1" --arg sid "${2:-sess-A}" --arg err "${3:-Exit code 1
boom}" --argjson intr "${4:-false}" \
    '{hook_event_name:"PostToolUseFailure", tool_name:"Bash", session_id:$sid,
      tool_input:{command:$cmd}, error:$err, is_interrupt:$intr}'
}
sd_ok_payload() { # <command> [session]
  jq -nc --arg cmd "$1" --arg sid "${2:-sess-A}" \
    '{hook_event_name:"PostToolUse", tool_name:"Bash", session_id:$sid,
      tool_input:{command:$cmd}, tool_response:{stdout:"x", stderr:"", interrupted:false}}'
}
# sd_run <payload> [env k=v...] -> echoes "<exit>|<stdout>"
sd_run() {
  local payload="$1"; shift
  local out status
  out="$(printf '%s' "$payload" | env "$@" bash "$SD_HOOK" 2>/dev/null)" && status=0 || status=$?
  printf '%s|%s' "$status" "$out"
}
sd_fired() { case "${1#*|}" in *'"additionalContext"'*) echo fired;; *) echo silent;; esac }
sd_reset_state() { rm -f "$SD_STATE_DIR"/stuck-* 2>/dev/null; }

# --- fire on the 3rd same-hash failure, silent before, exactly once ----------
sd_reset_state
r1="$(sd_run "$(sd_fail_payload 'make verify')")"
r2="$(sd_run "$(sd_fail_payload 'make verify')")"
r3="$(sd_run "$(sd_fail_payload 'make verify')")"
r4="$(sd_run "$(sd_fail_payload 'make verify')")"
assert_eq "stuck-detector: 1st failure exits 0"          "0"      "${r1%%|*}"
assert_eq "stuck-detector: 1st failure silent"           "silent" "$(sd_fired "$r1")"
assert_eq "stuck-detector: 2nd failure silent"           "silent" "$(sd_fired "$r2")"
assert_eq "stuck-detector: 3rd failure fires"            "fired"  "$(sd_fired "$r3")"
assert_eq "stuck-detector: 3rd failure exits 0"          "0"      "${r3%%|*}"
assert_eq "stuck-detector: 4th failure silent (once per hash)" "silent" "$(sd_fired "$r4")"

# The reminder must carry the rescue invocation (default generic phrasing —
# RESCUE_SKILL_NAME unset in the fixture local.env) and be valid hook JSON.
sd_ctx_ok="$(printf '%s' "${r3#*|}" | jq -e '
    .hookSpecificOutput.hookEventName == "PostToolUseFailure"
    and (.hookSpecificOutput.additionalContext | test("invoke your cross-model rescue capability"))
    and (.hookSpecificOutput.additionalContext | test("CLAUDE_SKIP_STUCK_DETECTOR"))
  ' >/dev/null 2>&1 && echo ok || echo bad)"
assert_eq "stuck-detector: reminder shape + rescue invocation + kill switch" "ok" "$sd_ctx_ok"

# No unresolved render token may survive into the built hook, and a local.env
# that names the operator's rescue skill must land the name in the reminder.
sd_token_left="$(grep -c '@@RESCUE_INVOCATION@@' "$SD_HOOK" || true)"
assert_eq "stuck-detector: rescue token resolved in the rendered hook" "0" "$sd_token_left"
SD_NM_OUT="$(mktemp -d)/target"; mkdir -p "$SD_NM_OUT"
SD_NM_ENV="$(mktemp -d)/local.env"
make_local_env "$SD_NM_ENV" "$SD_NM_OUT"
printf 'RESCUE_SKILL_NAME=test-rescue-skill\n' >> "$SD_NM_ENV"
AI_CONFIG_LOCAL_ENV="$SD_NM_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1
# grep -F: in a GNU BRE an escaped backtick is the buffer-start anchor (a BSD
# grep reads it as a literal backtick) — a fixed-string match is portable.
sd_named="$(grep -cF 'invoke the `test-rescue-skill` skill' "$SD_NM_OUT/hooks/stuck-detector.sh" || true)"
assert_eq "stuck-detector: RESCUE_SKILL_NAME renders the named invocation" "1" "$sd_named"

# --- success resets the streak ------------------------------------------------
sd_reset_state
sd_run "$(sd_fail_payload 'curl -s http://x')" >/dev/null
sd_run "$(sd_fail_payload 'curl -s http://x')" >/dev/null
sd_run "$(sd_ok_payload   'curl -s http://x')" >/dev/null
r5="$(sd_run "$(sd_fail_payload 'curl -s http://x')")"
r6="$(sd_run "$(sd_fail_payload 'curl -s http://x')")"
assert_eq "stuck-detector: post-reset 1st failure silent" "silent" "$(sd_fired "$r5")"
assert_eq "stuck-detector: post-reset 2nd failure silent" "silent" "$(sd_fired "$r6")"
r7="$(sd_run "$(sd_fail_payload 'curl -s http://x')")"
assert_eq "stuck-detector: post-reset 3rd consecutive failure fires" "fired" "$(sd_fired "$r7")"

# --- distinct commands never trigger ------------------------------------------
sd_reset_state
ra="$(sd_run "$(sd_fail_payload 'ls -la')")"
rb="$(sd_run "$(sd_fail_payload 'git status')")"
rc="$(sd_run "$(sd_fail_payload 'pwd')")"
assert_eq "stuck-detector: three distinct failing commands stay silent" "silentsilentsilent" \
  "$(sd_fired "$ra")$(sd_fired "$rb")$(sd_fired "$rc")"

# --- interleaving: per-hash streaks survive other commands in between ---------
sd_reset_state
sd_run "$(sd_fail_payload 'probe A')" >/dev/null
sd_run "$(sd_fail_payload 'probe B')" >/dev/null
sd_run "$(sd_fail_payload 'probe A')" >/dev/null
sd_run "$(sd_fail_payload 'probe B')" >/dev/null
ri="$(sd_run "$(sd_fail_payload 'probe A')")"
assert_eq "stuck-detector: interleaved distinct command does not break the streak" "fired" "$(sd_fired "$ri")"

# --- whitespace variants normalize to the same command ------------------------
sd_reset_state
sd_run "$(sd_fail_payload 'echo  a')" >/dev/null
sd_run "$(sd_fail_payload 'echo a')" >/dev/null
rw="$(sd_run "$(sd_fail_payload '  echo   a ')")"
assert_eq "stuck-detector: whitespace variants count as the same command" "fired" "$(sd_fired "$rw")"

# --- qualification guards: interrupts and non-exit errors never count ---------
sd_reset_state
sd_run "$(sd_fail_payload 'flaky' sess-A 'Exit code 1' true)"  >/dev/null
sd_run "$(sd_fail_payload 'flaky' sess-A 'Exit code 1' true)"  >/dev/null
rq="$(sd_run "$(sd_fail_payload 'flaky' sess-A 'Exit code 1' true)")"
assert_eq "stuck-detector: interrupted failures never count" "silent" "$(sd_fired "$rq")"
sd_reset_state
sd_run "$(sd_fail_payload 'denied' sess-A 'Permission to use Bash denied')" >/dev/null
sd_run "$(sd_fail_payload 'denied' sess-A 'Permission to use Bash denied')" >/dev/null
rp="$(sd_run "$(sd_fail_payload 'denied' sess-A 'Permission to use Bash denied')")"
assert_eq "stuck-detector: non-'Exit code' errors (denials) never count" "silent" "$(sd_fired "$rp")"

# --- kill switch --------------------------------------------------------------
sd_reset_state
sd_run "$(sd_fail_payload 'kswitch')" >/dev/null
sd_run "$(sd_fail_payload 'kswitch')" >/dev/null
rk="$(sd_run "$(sd_fail_payload 'kswitch')" CLAUDE_SKIP_STUCK_DETECTOR=1)"
assert_eq "stuck-detector: kill switch silences the firing call" "silent" "$(sd_fired "$rk")"
assert_eq "stuck-detector: kill switch exits 0" "0" "${rk%%|*}"

# --- per-session isolation ----------------------------------------------------
sd_reset_state
sd_run "$(sd_fail_payload 'shared cmd' sess-A)" >/dev/null
sd_run "$(sd_fail_payload 'shared cmd' sess-A)" >/dev/null
rs="$(sd_run "$(sd_fail_payload 'shared cmd' sess-B)")"
assert_eq "stuck-detector: another session's counter is independent" "silent" "$(sd_fired "$rs")"

# --- hostile session id: no path escape, no state, silent ---------------------
sd_reset_state
rh="$(sd_run "$(sd_fail_payload 'x' '../../etc/passwd')")"
assert_eq "stuck-detector: hostile session id exits 0 silent" "0|" "$rh"
# -not -path excludes the rendered hook scripts themselves (stuck-detector.sh
# matches the stuck-* glob); only state files are being counted.
sd_escaped="$(find "$SD_OUT" -name 'stuck-*' -not -path '*/hooks/*' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "stuck-detector: hostile session id writes no state" "0" "$sd_escaped"

# --- reap: stale per-session state older than 7 days is deleted ---------------
sd_reset_state
mkdir -p "$SD_STATE_DIR"
touch "$SD_STATE_DIR/stuck-old-session"
# BSD and GNU touch both accept -t.
touch -t 202501010000 "$SD_STATE_DIR/stuck-old-session"
sd_run "$(sd_fail_payload 'reaper probe')" >/dev/null
if [ -f "$SD_STATE_DIR/stuck-old-session" ]; then sd_reaped=stale; else sd_reaped=reaped; fi
assert_eq "stuck-detector: stale session state is reaped" "reaped" "$sd_reaped"

# --- fail-open: no jq on PATH -> exit 0 silent --------------------------------
SD_NOJQ_BIN="$(mktemp -d)"
for t in bash cat printf env grep cut wc mv rm mkdir find tr head shasum sha256sum cksum; do
  p="$(command -v "$t" 2>/dev/null)" && ln -s "$p" "$SD_NOJQ_BIN/$t" 2>/dev/null
done
# Capture the HOOK's exit via PIPESTATUS: the hook may exit before the writer
# finishes, and under pipefail the writer's EPIPE would masquerade as a hook
# failure (bit CI; the hook now drains stdin first, this keeps the test honest
# regardless).
rn_out="$(printf '%s' "$(sd_fail_payload 'x')" | env PATH="$SD_NOJQ_BIN" bash "$SD_HOOK" 2>/dev/null; exit "${PIPESTATUS[1]}")" && rn_status=0 || rn_status=$?
assert_eq "stuck-detector: missing jq fails open (exit 0)" "0" "$rn_status"
assert_eq "stuck-detector: missing jq stays silent" "" "$rn_out"

# --- non-Bash tools and foreign events are ignored ----------------------------
sd_reset_state
rt="$(sd_run "$(jq -nc '{hook_event_name:"PostToolUseFailure", tool_name:"Read", session_id:"sess-A", tool_input:{command:"x"}, error:"Exit code 1"}')")"
assert_eq "stuck-detector: non-Bash tool is ignored" "0|" "$rt"
rv="$(sd_run "$(jq -nc '{hook_event_name:"PreToolUse", tool_name:"Bash", session_id:"sess-A", tool_input:{command:"x"}}')")"
assert_eq "stuck-detector: foreign event is ignored" "0|" "$rv"

# --- varied-work dry run: a realistic mixed stream never fires ----------------
# Acceptance criterion 3: no reminder during normal varied work. The stream
# mirrors a real session shape — mostly successes, isolated failures (a grep
# no-match, a missing file, one flaky re-run that succeeds on retry 2).
sd_reset_state
sd_dry_fired=0
while IFS='|' read -r kind cmd; do
  [ -n "$kind" ] || continue
  if [ "$kind" = "F" ]; then p="$(sd_fail_payload "$cmd" sess-dry)"; else p="$(sd_ok_payload "$cmd" sess-dry)"; fi
  out="$(sd_run "$p")"
  [ "$(sd_fired "$out")" = "fired" ] && sd_dry_fired=$((sd_dry_fired + 1))
done <<'DRYRUN'
O|git status
O|ls -la src
F|grep -n missing_symbol src/main.c
O|grep -rn init src
F|cat /tmp/notes-from-last-time.md
O|make build
F|make test
O|make test
O|git add -A
O|git commit -m wip
F|curl -s https://api.example.com/health
O|curl -s https://api.example.com/health
O|jq . package.json
O|npm run lint
DRYRUN
assert_eq "stuck-detector: varied-work dry run never fires" "0" "$sd_dry_fired"

# --- twin parity: the fired reminder string is byte-identical in the PS twin --
if command -v pwsh >/dev/null 2>&1; then
  SD_PS_DIR="$(mktemp -d)"; mkdir -p "$SD_PS_DIR/hooks"
  # The source .ps1 still carries the render token — apply the same default
  # substitution install.sh applied to the built .sh before comparing.
  sed 's/@@RESCUE_INVOCATION@@/invoke your cross-model rescue capability/' \
    "$REPO_ROOT/harnesses/claude/hooks/stuck-detector.ps1" > "$SD_PS_DIR/hooks/stuck-detector.ps1"
  sd_ps_last=""
  for i in 1 2 3; do
    sd_ps_last="$(printf '%s' "$(sd_fail_payload 'make verify' sess-ps)" | pwsh -NoProfile -File "$SD_PS_DIR/hooks/stuck-detector.ps1" 2>/dev/null)"
  done
  sd_bash_msg="$(printf '%s' "${r3#*|}" | jq -r '.hookSpecificOutput.additionalContext')"
  sd_ps_msg="$(printf '%s' "$sd_ps_last" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
  assert_eq "stuck-detector: PS twin reminder is byte-identical" "$sd_bash_msg" "$sd_ps_msg"
else
  _skip "stuck-detector: PS twin reminder is byte-identical" "pwsh not on PATH"
fi

# ============================ panel-driven cases ==============================

# --- cross-command isolation: success of B must not disturb A's streak -------
# (Pins the per-hash invariant the whole feature rests on: a refactor that
# truncates the state file on ANY success would pass every earlier test.)
sd_reset_state
sd_run "$(sd_fail_payload 'probe iso-A')" >/dev/null
sd_run "$(sd_fail_payload 'probe iso-A')" >/dev/null
sd_run "$(sd_ok_payload   'probe iso-B')" >/dev/null
rx="$(sd_run "$(sd_fail_payload 'probe iso-A')")"
assert_eq "stuck-detector: success of another command preserves the streak" "fired" "$(sd_fired "$rx")"

# --- successes never create state records ------------------------------------
sd_reset_state
sd_run "$(sd_fail_payload 'seed fail')" >/dev/null
sd_run "$(sd_ok_payload 'unseen ok one')" >/dev/null
sd_run "$(sd_ok_payload 'unseen ok two')" >/dev/null
sd_lines="$(wc -l < "$SD_STATE_DIR/stuck-sess-A" | tr -d ' ')"
assert_eq "stuck-detector: successes never create state records" "1" "$sd_lines"

# --- full reset drops the record; sticky fired survives a success ------------
sd_reset_state
sd_run "$(sd_fail_payload 'reset drop')" >/dev/null
sd_run "$(sd_ok_payload   'reset drop')" >/dev/null
sd_dropped="$(grep -c . "$SD_STATE_DIR/stuck-sess-A" 2>/dev/null || true)"
assert_eq "stuck-detector: a fully-reset record is dropped from state" "0" "$sd_dropped"
sd_reset_state
for i in 1 2 3; do sd_run "$(sd_fail_payload 'sticky keep')" >/dev/null; done
sd_run "$(sd_ok_payload 'sticky keep')" >/dev/null
sd_sticky="$(awk '{print $2, $3}' "$SD_STATE_DIR/stuck-sess-A" 2>/dev/null)"
assert_eq "stuck-detector: sticky fired flag survives a success reset" "0 1" "$sd_sticky"

# --- malformed state lines are filtered on rewrite ---------------------------
sd_reset_state
mkdir -p "$SD_STATE_DIR"
printf 'garbage-not-a-record\n\n' > "$SD_STATE_DIR/stuck-sess-A"
sd_run "$(sd_fail_payload 'filter probe')" >/dev/null
sd_bad="$(grep -cv -E '^[0-9a-f]{64} [0-9]+ [01]$' "$SD_STATE_DIR/stuck-sess-A" || true)"
assert_eq "stuck-detector: malformed state lines are filtered on rewrite" "0" "$sd_bad"

# --- a fresh contended lock skips the event (fail open, no state change) -----
sd_reset_state
mkdir -p "$SD_STATE_DIR/stuck-sess-A.lock"
rl="$(sd_run "$(sd_fail_payload 'locked out')")"
assert_eq "stuck-detector: contended lock skips silently" "0|" "$rl"
sd_lock_state="$([ -f "$SD_STATE_DIR/stuck-sess-A" ] && echo written || echo untouched)"
assert_eq "stuck-detector: contended lock leaves state untouched" "untouched" "$sd_lock_state"
rmdir "$SD_STATE_DIR/stuck-sess-A.lock"

# --- storage failure stays silent (no emit without a persisted fired flag) ---
sd_reset_state
sd_run "$(sd_fail_payload 'ro probe')" >/dev/null
sd_run "$(sd_fail_payload 'ro probe')" >/dev/null
chmod -w "$SD_STATE_DIR"
rro="$(sd_run "$(sd_fail_payload 'ro probe')")"
chmod +w "$SD_STATE_DIR"
assert_eq "stuck-detector: storage failure stays silent" "0|" "$rro"
sd_ro_fired="$(awk '{print $3}' "$SD_STATE_DIR/stuck-sess-A" 2>/dev/null)"
assert_eq "stuck-detector: storage failure does not record fired" "0" "$sd_ro_fired"

# --- absent is_interrupt field still counts ----------------------------------
sd_reset_state
sd_noint() { jq -nc --arg cmd "$1" '{hook_event_name:"PostToolUseFailure", tool_name:"Bash", session_id:"sess-A", tool_input:{command:$cmd}, error:"Exit code 1"}'; }
sd_run "$(sd_noint 'no intr field')" >/dev/null
sd_run "$(sd_noint 'no intr field')" >/dev/null
rni="$(sd_run "$(sd_noint 'no intr field')")"
assert_eq "stuck-detector: absent is_interrupt field still counts" "fired" "$(sd_fired "$rni")"

# --- backticks in the failing command are stripped from the reminder snippet -
sd_reset_state
for i in 1 2 3; do rbt="$(sd_run "$(sd_fail_payload 'echo `date` now')")"; done
sd_bt_ctx="$(printf '%s' "${rbt#*|}" | jq -r '.hookSpecificOutput.additionalContext')"
case "$sd_bt_ctx" in
  *': `echo date now`. Rescue rule'*) sd_bt_ok=ok ;;
  *) sd_bt_ok="bad: $sd_bt_ctx" ;;
esac
assert_eq "stuck-detector: snippet strips backticks (code span stays intact)" "ok" "$sd_bt_ok"

# --- reap deletes stale sessions but preserves the current one ---------------
sd_reset_state
mkdir -p "$SD_STATE_DIR"
touch "$SD_STATE_DIR/stuck-old-two"; touch -t 202501010000 "$SD_STATE_DIR/stuck-old-two"
sd_run "$(sd_fail_payload 'reap keep probe')" >/dev/null
sd_reap_pair="$([ -f "$SD_STATE_DIR/stuck-old-two" ] && echo stale || echo reaped)-$([ -f "$SD_STATE_DIR/stuck-sess-A" ] && echo kept || echo lost)"
assert_eq "stuck-detector: reap drops stale sessions and keeps the current one" "reaped-kept" "$sd_reap_pair"

# --- hostile RESCUE_SKILL_NAME falls back to generic phrasing, hook parses ---
SD_HO_OUT="$(mktemp -d)/target"; mkdir -p "$SD_HO_OUT"
SD_HO_ENV="$(mktemp -d)/local.env"
make_local_env "$SD_HO_ENV" "$SD_HO_OUT"
printf "RESCUE_SKILL_NAME='rescue \$(touch /tmp/sd-pwn-\$\$)'\n" >> "$SD_HO_ENV"
AI_CONFIG_LOCAL_ENV="$SD_HO_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1
sd_ho_generic="$(grep -c 'invoke your cross-model rescue capability' "$SD_HO_OUT/hooks/stuck-detector.sh" || true)"
assert_eq "stuck-detector: hostile RESCUE_SKILL_NAME falls back to generic phrasing" "1" "$sd_ho_generic"
assert_exit "stuck-detector: hook rendered from hostile name still parses" 0 -- bash -n "$SD_HO_OUT/hooks/stuck-detector.sh"

# --- install idempotency: re-install keeps single wiring per event -----------
AI_CONFIG_LOCAL_ENV="$SD_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1
sd_wire_counts="$(jq -r '[
    ([.hooks.PostToolUseFailure[]? | select(.hooks[]?.command | contains("stuck-detector"))] | length),
    ([.hooks.PostToolUse[]?        | select(.hooks[]?.command | contains("stuck-detector"))] | length),
    ([.hooks.SessionStart[]?       | select(.hooks[]?.command | contains("framework-surface"))] | length)
  ] | join(",")' "$SD_OUT/settings.json" 2>/dev/null)"
assert_eq "stuck-detector: re-install keeps exactly one wiring per event" "1,1,1" "$sd_wire_counts"
