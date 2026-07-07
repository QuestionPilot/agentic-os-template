#!/usr/bin/env bash
# tests/hooks-cross-harness-parity.test.sh — cross-harness behavioral parity
# fixtures for the pre-edit-gate spine hook (<TEAM>-364 item 3).
#
# CONTRACT: DECISION parity. One semantic scenario, rendered into each
# harness's native input shape, must produce the SAME allow/deny decision in
# every installed harness realization (claude / codex / hermes). This extends
# the bash<->PS twin-parity pattern (tests/hooks-ps-parity.test.sh) CROSS-
# HARNESS: the three session-agent gate sources are reviewed for equivalence,
# but review alone once let a vacuous-gate bug (whole-transcript grep opening
# the gate on the skill body's own template line) live undetected in ALL
# THREE twins — each harness was only ever tested in isolation, so the shared
# blind spot never collided with a shared expectation.
#
# THE MATRIX IS THE SEED DETECTOR: a seeded behavioral divergence in any ONE
# twin fails two rows here — its per-harness expected-decision assertion
# (localizing WHICH twin diverged) and the cross-harness agreement assertion
# (the parity contract itself). Verified by seeding: re-vacuating one twin's
# declaration check (whole-transcript grep) flips its S3 row to allow and
# turns both rows red while the other harnesses stay green.
#
# Scenario matrix (semantic situation -> expected decision, ALL harnesses):
#   S1 no-orient                     session-agent never invoked          -> deny
#   S2 orient-declared               invoked + assistant-authored line-
#                                    anchored `Linear gate:` declaration
#                                    via the harness's canonical channel  -> allow
#   S3 orient-undeclared-with-noise  invoked, NO declaration, but the
#                                    transcript/state carries the two
#                                    vacuousness triggers (the skill
#                                    body's own `Linear gate: <ISSUE-ID`
#                                    template line + a prior deny quoting
#                                    the phrase)                          -> deny
#   S4 kill-switch                   CLAUDE_SKIP_SESSION_AGENT=1 (the ONE
#                                    switch name every harness honors) on
#                                    the S1 input                         -> allow
#
# Per-harness input shape + decision channel (each from its hook's contract):
#   claude  PreToolUse JSON {transcript_path, session_id, tool_name} on
#           stdin against a Claude-CLI transcript JSONL; deny channel is
#           hookSpecificOutput.permissionDecision "deny" (the legacy
#           top-level {"decision":"block"} is a documented NO-OP there).
#   codex   PreToolUse JSON {transcript_path} on stdin against a Codex
#           rollout JSONL (response_item records); Codex honors BOTH the
#           modern permissionDecision deny (runtime path) AND the legacy
#           {"decision":"block"} (jq-missing static fail-closed path).
#   hermes  pre_tool_call JSON {tool_name, tool_input, session_id} on
#           stdin; session state lives in the per-session gate-marker file
#           and a state.db SQLite backstop (messages table), not in a
#           transcript file; block channel is the legacy
#           {"decision":"block"}, allow is silent stdout.
#
# Both engine realizations are exercised: the install.sh-rendered .sh hooks
# via bash, and the .ps1 twins via pwsh (guarded — all three harnesses also
# ship session-agent.ps1). Hooks run from throwaway per-harness homes so the
# marker-reap and state.db reads never touch the repo.
#
# Sourced by tests/run.sh with tests/lib.sh loaded; never calls `exit`.

# On a CI lane that MUST run the pwsh lanes, a missing pwsh is a loud failure
# instead of a silent skip (PARITY_REQUIRE_PWSH=1 — same contract as
# tests/hooks-ps-parity.test.sh).
_require_pwsh_or_fail "hooks-cross-harness-parity"

XH_FIX="$REPO_ROOT/tests/fixtures"
XH_WORK="$(mktemp -d)"

# --- Render each harness target into a throwaway home -----------------------
# One install.sh pass per harness with its canonical fixture local.env helper
# — the same rendered-hook pattern as tests/hooks-behavior.test.sh (claude),
# tests/codex.test.sh (codex full install) and tests/install-hermes.test.sh
# (hermes). Running rendered targets (not the raw sources) keeps this test on
# the exact artifacts operators execute.
XH_CL="$XH_WORK/claude-home"; mkdir -p "$XH_CL"
make_local_env "$XH_WORK/cl.env" "$XH_CL"
AI_CONFIG_LOCAL_ENV="$XH_WORK/cl.env" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1

XH_CX="$XH_WORK/codex-home"; mkdir -p "$XH_CX"
make_codex_env "$XH_WORK/cx.env" "$XH_CX"
AI_CONFIG_LOCAL_ENV="$XH_WORK/cx.env" bash "$REPO_ROOT/scripts/install.sh" --harness codex >/dev/null 2>&1

XH_HM="$XH_WORK/hermes-home"; mkdir -p "$XH_HM"
make_hermes_env "$XH_WORK/hm.env" "$XH_HM"
AI_CONFIG_LOCAL_ENV="$XH_WORK/hm.env" bash "$REPO_ROOT/scripts/install.sh" --harness hermes >/dev/null 2>&1

assert_file "xh: rendered claude session-agent.sh" "$XH_CL/hooks/session-agent.sh"
assert_file "xh: rendered codex session-agent.sh"  "$XH_CX/hooks/session-agent.sh"
assert_file "xh: rendered hermes session-agent.sh" "$XH_HM/hooks/session-agent.sh"

# install.sh compiles only the .sh hooks (install.ps1 owns the .ps1 surface);
# stage each .ps1 twin into the SAME rendered home — the copy-into-throwaway-
# layout pattern of tests/hooks-ps-parity.test.sh 3h — so its $PSScriptRoot-
# relative state (marker dir, state.db) resolves to the same home as the .sh
# twin and BOTH engines read the SAME rendered semantic state.
cp "$REPO_ROOT/harnesses/claude/hooks/session-agent.ps1" "$XH_CL/hooks/" 2>/dev/null
cp "$REPO_ROOT/harnesses/codex/hooks/session-agent.ps1"  "$XH_CX/hooks/" 2>/dev/null
cp "$REPO_ROOT/harnesses/hermes/hooks/session-agent.ps1" "$XH_HM/hooks/" 2>/dev/null

# --- Hermes state modeling ---------------------------------------------------
# Hermes has no transcript file: the hook reads a per-session gate-marker file
# plus a read-only state.db backstop. Build the db at test time with the exact
# shape the hook queries — messages(session_id, role, content, tool_calls) —
# the same schema tests/install-hermes.test.sh models. Row semantics mirror
# the claude/codex fixtures record for record:
#   xh-s1  benign chatter only            == transcript-empty.jsonl
#   xh-s2  injected skill body (the ran-marker SKILL.md path + the template
#          `Linear gate: <ISSUE-ID` line) + a prior deny quote + an ASSISTANT
#          row with the line-anchored declaration
#                                          == transcript-session-agent-ok.jsonl
#   xh-s3  same noise rows, but the assistant never declares
#                                          == transcript-session-agent-no-linear.jsonl
# The user-role body row and the tool-role deny row are the two vacuousness
# triggers: only the role-filtered, line-anchored query keeps S3 a deny.
XH_DB="$XH_HM/state.db"
XH_HAVE_SQLITE=0
if command -v sqlite3 >/dev/null 2>&1; then
  XH_HAVE_SQLITE=1
  rm -f "$XH_DB"
  sqlite3 "$XH_DB" <<'XH_SQL'
CREATE TABLE messages (session_id TEXT, role TEXT, content TEXT, tool_calls TEXT, timestamp REAL);
INSERT INTO messages VALUES ('xh-s1','user','hello',NULL,1);
INSERT INTO messages VALUES ('xh-s1','assistant','hi',NULL,2);
INSERT INTO messages VALUES ('xh-s2','user','# Session Agent — Session Kickoff Orient + Routing
injected body: skills/session-agent/SKILL.md
Routing: <one-sentence task surface>
Linear gate: <ISSUE-ID or URL> | none — single-step | none — drafted',NULL,1);
INSERT INTO messages VALUES ('xh-s2','tool','blocked: The session-agent capability ran but no `Linear gate:` declaration was found this session. Emit the full declaration including the `Linear gate:` line.',NULL,2);
INSERT INTO messages VALUES ('xh-s2','assistant','Routing: infra change
Linear gate: PROJ-1',NULL,3);
INSERT INTO messages VALUES ('xh-s3','user','# Session Agent — Session Kickoff Orient + Routing
injected body: skills/session-agent/SKILL.md
Routing: <one-sentence task surface>
Linear gate: <ISSUE-ID or URL> | none — single-step | none — drafted',NULL,1);
INSERT INTO messages VALUES ('xh-s3','tool','blocked: The session-agent capability ran but no `Linear gate:` declaration was found this session. Emit the full declaration including the `Linear gate:` line.',NULL,2);
INSERT INTO messages VALUES ('xh-s3','assistant','Routing: infra change',NULL,3);
XH_SQL
  # Scenario-realism guard (mirrors the fixture-noise assertions in
  # tests/hooks-behavior.test.sh): the S3 state must actually carry both
  # vacuousness triggers in NON-assistant rows, or the deny expectation would
  # pass vacuously without exercising the role filter.
  xh_s3_noise="$(sqlite3 -readonly "$XH_DB" "SELECT content FROM messages WHERE session_id='xh-s3' AND role <> 'assistant';")"
  assert_contains "xh: hermes S3 state models the injected template line" "$xh_s3_noise" 'Linear gate: <ISSUE-ID'
  assert_contains "xh: hermes S3 state models a prior deny quote"         "$xh_s3_noise" 'no `Linear gate:` declaration'
else
  _skip "xh: hermes S3 state models the injected template line" "sqlite3 not installed"
  _skip "xh: hermes S3 state models a prior deny quote"         "sqlite3 not installed"
fi

# --- Per-harness payload renderers (one semantic scenario, native shapes) ---
# xh_claude_payload <transcript> <session-id>
xh_claude_payload() {
  printf '{"transcript_path":"%s","tool_name":"Write","session_id":"%s"}' "$1" "$2"
}
# xh_codex_payload <transcript> — the codex hook keys only off the rollout.
xh_codex_payload() {
  printf '{"transcript_path":"%s","tool_name":"apply_patch"}' "$1"
}
# xh_hermes_payload <session-id> — a plain (non-marker-path) write_file event;
# the session id keys both the gate-marker path and the state.db rows.
xh_hermes_payload() {
  printf '{"hook_event_name":"pre_tool_call","tool_name":"write_file","tool_input":{"path":"/tmp/xh-target.txt","content":"hi"},"session_id":"%s","cwd":"/tmp"}' "$1"
}

# --- Per-harness decision classifiers ----------------------------------------
# One classifier per harness, each reading that harness's own decision channel
# — classifying every harness through one shared pattern would hide exactly
# the shape divergences this file exists to catch.

# claude: the ONLY honored PreToolUse deny channel is
# hookSpecificOutput.permissionDecision "deny"; the legacy top-level
# {"decision":"block"} is a no-op on this event, so it must classify as allow
# (a regression to the legacy shape then fails the deny rows).
xh_classify_claude() {
  case "$1" in *'"permissionDecision":"deny"'*) echo "deny";; *) echo "allow";; esac
}
# codex: Codex PreToolUse honors BOTH block shapes — the modern
# permissionDecision deny (the hook's runtime path) and the legacy top-level
# {"decision":"block"} (its jq-missing static fail-closed path) — verified
# v0.132.0; see harnesses/codex/adapter.md and tests/codex.test.sh.
xh_classify_codex() {
  case "$1" in
    *'"permissionDecision":"deny"'*|*'"decision":"block"'*) echo "deny";;
    *) echo "allow";;
  esac
}
# hermes: block channel is the legacy {"decision":"block"} shape (Hermes
# parses it natively into its wire shape); allow is silent stdout.
xh_classify_hermes() {
  case "$1" in *'"decision":"block"'*) echo "deny";; *) echo "allow";; esac
}

# xh_decision <harness> <hook-path> <payload> [ENV=val...] -> deny|allow|error-N
# Runs the hook (bash for .sh, pwsh for .ps1) with the payload on stdin and
# classifies stdout through the harness's own channel. A non-zero exit becomes
# "error-N": every gate hook's contract is exit-0-always, so an execution
# error must both miss the expected decision AND break the agreement rows
# with a diagnostic value — never silently count as allow.
xh_decision() {
  local harness="$1" hook="$2" payload="$3"; shift 3
  local out status
  status=0
  case "$hook" in
    *.ps1) out="$(printf '%s' "$payload" | env "$@" pwsh -NoProfile -File "$hook" 2>/dev/null)" || status=$? ;;
    *)     out="$(printf '%s' "$payload" | env "$@" bash "$hook" 2>/dev/null)" || status=$? ;;
  esac
  if [ "$status" -ne 0 ]; then
    printf 'error-%s' "$status"
    return 0
  fi
  case "$harness" in
    claude) xh_classify_claude "$out" ;;
    codex)  xh_classify_codex  "$out" ;;
    hermes) xh_classify_hermes "$out" ;;
  esac
}

# xh_scenario <engine:sh|ps1> <S1..S4> <name> <expected> [ENV=val...]
# One matrix row: render the scenario into each harness's native shape, compute
# the three decisions, then assert (a) each harness's decision equals the
# expected one — this localizes WHICH twin diverged — and (b) the harnesses
# agree pairwise (claude==codex, codex==hermes; equality is transitive, so two
# pairs pin all three) — that agreement IS the parity contract, and it fails
# even if the expected table itself were edited into disagreement.
xh_scenario() {
  local eng="$1" id="$2" name="$3" want="$4"; shift 4
  local ext="sh"
  [ "$eng" = "ps1" ] && ext="ps1"
  local cl_fix cx_fix
  case "$id" in
    S2) cl_fix="$XH_FIX/transcript-session-agent-ok.jsonl"
        cx_fix="$XH_FIX/codex-transcript-session-agent-ok.jsonl" ;;
    S3) cl_fix="$XH_FIX/transcript-session-agent-no-linear.jsonl"
        cx_fix="$XH_FIX/codex-transcript-session-agent-no-linear.jsonl" ;;
    # S1 and S4 share the no-orient input — S4 proves the kill switch flips
    # exactly that deny to an allow in every harness.
    *)  cl_fix="$XH_FIX/transcript-empty.jsonl"
        cx_fix="$XH_FIX/codex-transcript-empty.jsonl" ;;
  esac
  # xh-s1..xh-s4 — keys the hermes state.db rows and the per-session marker
  # paths; no scenario writes a marker, so sessions cannot cross-contaminate.
  local sid="xh-s${id#S}"
  local d_cl d_cx d_hm
  d_cl="$(xh_decision claude "$XH_CL/hooks/session-agent.$ext" "$(xh_claude_payload "$cl_fix" "$sid")" "$@")"
  d_cx="$(xh_decision codex  "$XH_CX/hooks/session-agent.$ext" "$(xh_codex_payload "$cx_fix")" "$@")"
  assert_eq "xh[$eng] $id $name: claude decision"      "$want" "$d_cl"
  assert_eq "xh[$eng] $id $name: codex decision"       "$want" "$d_cx"
  assert_eq "xh[$eng] $id $name: parity claude==codex" "$d_cl" "$d_cx"
  # Hermes S1-S3 model session state in state.db; without sqlite3 the scenario
  # cannot be rendered faithfully, so those lanes skip with the reason. S4
  # short-circuits on the kill switch before any state read, so it always runs.
  if [ "$XH_HAVE_SQLITE" = "1" ] || [ "$id" = "S4" ]; then
    d_hm="$(xh_decision hermes "$XH_HM/hooks/session-agent.$ext" "$(xh_hermes_payload "$sid")" "$@")"
    assert_eq "xh[$eng] $id $name: hermes decision"      "$want" "$d_hm"
    assert_eq "xh[$eng] $id $name: parity codex==hermes" "$d_cx" "$d_hm"
  else
    _skip "xh[$eng] $id $name: hermes decision"      "sqlite3 not installed - cannot model state.db"
    _skip "xh[$eng] $id $name: parity codex==hermes" "sqlite3 not installed - cannot model state.db"
  fi
}

# --- The matrix, bash engine: install.sh-rendered .sh realizations ----------
xh_scenario sh S1 "no-orient"                    deny
xh_scenario sh S2 "orient-declared"              allow
xh_scenario sh S3 "orient-undeclared-with-noise" deny
xh_scenario sh S4 "kill-switch"                  allow CLAUDE_SKIP_SESSION_AGENT=1

# --- The matrix, pwsh engine: the .ps1 twins, SAME semantic inputs ----------
# All three harnesses ship a session-agent.ps1 twin; drive them from bash via
# pwsh exactly like tests/hooks-ps-parity.test.sh does. When pwsh is absent
# this skips (loudly if PARITY_REQUIRE_PWSH=1 — enforced at the top).
if command -v pwsh >/dev/null 2>&1; then
  xh_scenario ps1 S1 "no-orient"                    deny
  xh_scenario ps1 S2 "orient-declared"              allow
  xh_scenario ps1 S3 "orient-undeclared-with-noise" deny
  xh_scenario ps1 S4 "kill-switch"                  allow CLAUDE_SKIP_SESSION_AGENT=1
else
  _skip "xh[ps1] S1-S4 cross-harness matrix (.ps1 twins)" "pwsh not on PATH"
fi

# Cleanup — tests/run.sh dot-sources every test file into one shell, so scrub
# the helpers and variables to avoid leaking into later files.
rm -rf "$XH_WORK"
unset XH_FIX XH_WORK XH_CL XH_CX XH_HM XH_DB XH_HAVE_SQLITE xh_s3_noise
unset -f xh_claude_payload xh_codex_payload xh_hermes_payload
unset -f xh_classify_claude xh_classify_codex xh_classify_hermes
unset -f xh_decision xh_scenario
