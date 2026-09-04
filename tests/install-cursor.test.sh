#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/install-cursor.test.sh — the cursor harness build
# (`install.sh --harness cursor`) + the cursor hook behaviors.
#
# Covers: build output map (skills / hooks / hooks.json / AGENTS.md / manifest),
# the Cursor-native hooks.json v1 shape (version, flat entries, omitted empty
# matcher, failClosed ONLY on the blocking event), drift-gate pass on a fresh
# build, entrypoint placeholder resolution + the fail-on-empty-placeholder case,
# the single-occurrence catalog-marker regression, and the preToolUse gate's
# allow/deny paths against synthetic payloads.
#
# Sourced by tests/run.sh; uses assert_* helpers from tests/lib.sh.
# Never call `exit` — failures bubble through assertion counters.
# slow

IC_OUT="$(mktemp -d)/cursor-home"; mkdir -p "$IC_OUT"
IC_ENV="$(mktemp -d)/local.env"
IC_VAULT="$(mktemp -d)/vault"
cp -R "$REPO_ROOT/obsidian/vault-scaffolding" "$IC_VAULT"
make_cursor_env "$IC_ENV" "$IC_OUT" "$IC_VAULT"

assert_exit "install.sh --harness cursor builds clean" 0 -- \
  env AI_CONFIG_LOCAL_ENV="$IC_ENV" bash "$REPO_ROOT/scripts/install.sh" --harness cursor

# --- T1: build output map ---
for f in \
  "skills/session-agent/SKILL.md" \
  "skills/closeout/SKILL.md" \
  "skills/self-audit/SKILL.md" \
  "hooks/framework-surface.sh" \
  "hooks/session-agent.sh" \
  "hooks.json" \
  "AGENTS.md" \
  ".build-manifest.json"; do
  assert_file "cursor build produced $f" "$IC_OUT/$f"
done

# Files the build must NEVER write (adapter Fact 5 — user-owned).
for f in "cli-config.json" "permissions.json" "sandbox.json" "mcp.json"; do
  if [ -e "$IC_OUT/$f" ]; then
    _fail "cursor build leaves the user-owned $f alone" "build wrote $IC_OUT/$f"
  else
    _pass "cursor build leaves the user-owned $f alone"
  fi
done

# --- T2: hooks.json is valid, v1-shaped, and fail-closed on the gate ONLY ---
if command -v jq >/dev/null 2>&1; then
  assert_exit "cursor hooks.json is valid JSON" 0 -- jq empty "$IC_OUT/hooks.json"
  assert_eq "hooks.json declares schema version 1" "1" \
    "$(jq -r '.version' "$IC_OUT/hooks.json")"
  # Matcher `Write|Delete` (panel fix A4): Delete is live-verified (adapter U6).
  assert_eq "the pre-edit gate is wired on preToolUse with the Write|Delete matcher" "Write|Delete" \
    "$(jq -r '.hooks.preToolUse[0].matcher' "$IC_OUT/hooks.json")"
  # Command path is double-quoted (panel fix A2): unquoted splits on spaces.
  assert_eq "the gate entry commands the rendered gate script (quoted absolute path)" \
    "\"$IC_OUT/hooks/session-agent.sh\"" \
    "$(jq -r '.hooks.preToolUse[0].command' "$IC_OUT/hooks.json")"
  # Cursor's DEFAULT is fail-OPEN on a hook crash/timeout/bad-JSON. A gate that
  # ships without failClosed silently degrades to "allow" the moment anything
  # goes wrong — this assertion is the regression guard for that whole class.
  assert_eq "the gate entry sets failClosed (Cursor defaults to fail-OPEN)" "true" \
    "$(jq -r '.hooks.preToolUse[0].failClosed' "$IC_OUT/hooks.json")"
  assert_eq "framework-surface is wired on sessionStart" \
    "\"$IC_OUT/hooks/framework-surface.sh\"" \
    "$(jq -r '.hooks.sessionStart[0].command' "$IC_OUT/hooks.json")"
  # The surfacing hook must NOT be fail-closed: a failed context injection must
  # never break a session. Absent key (null) is the correct state.
  assert_eq "framework-surface is NOT fail-closed (surfacing hooks fail open)" "null" \
    "$(jq -r '.hooks.sessionStart[0].failClosed' "$IC_OUT/hooks.json")"
  # sessionStart has no documented matcher field — the key must be OMITTED, not
  # emitted as an empty string (an empty regex is a meaningless filter).
  assert_eq "sessionStart entry omits the matcher key entirely" "false" \
    "$(jq -r '.hooks.sessionStart[0] | has("matcher")' "$IC_OUT/hooks.json")"
  # Flat entry shape: Cursor's entry IS {command,...} — no nested hooks array,
  # no `type` field (that is Claude's settings.json / Codex's hooks.json shape).
  assert_eq "cursor entries are FLAT (no nested hooks array — that is the codex shape)" "false" \
    "$(jq -r '[.hooks[][] | has("hooks")] | any' "$IC_OUT/hooks.json")"
else
  _skip "cursor hooks.json shape suite" "jq not installed"
fi

# --- T3: drift gate passes a fresh build ---
assert_exit "check-drift passes the fresh cursor build" 0 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$IC_OUT"

# A hand-edit to a generated file is drift.
printf '\n<!-- hand edit -->\n' >> "$IC_OUT/AGENTS.md"
assert_exit "check-drift flags a hand-edited cursor AGENTS.md" 1 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$IC_OUT"
env AI_CONFIG_LOCAL_ENV="$IC_ENV" bash "$REPO_ROOT/scripts/install.sh" --harness cursor >/dev/null 2>&1

# Operator (Shape C) skills are preserved across a re-render and exempt from the
# manifest gate — the same contract every other harness render has.
mkdir -p "$IC_OUT/skills/operator-skill"
printf -- '---\nname: operator-skill\ndescription: operator-local\n---\n\nbody\n' \
  > "$IC_OUT/skills/operator-skill/SKILL.md"
assert_exit "re-install with an operator skill subdir present builds clean" 0 -- \
  env AI_CONFIG_LOCAL_ENV="$IC_ENV" bash "$REPO_ROOT/scripts/install.sh" --harness cursor
assert_file "operator skill subdir survives a cursor re-install" \
  "$IC_OUT/skills/operator-skill/SKILL.md"
assert_exit "check-drift exempts the operator-added cursor skill subdir" 0 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$IC_OUT"
rm -rf "$IC_OUT/skills/operator-skill"

# --- T4: AGENTS.md placeholder resolution + the catalog ---
ic_agents="$(cat "$IC_OUT/AGENTS.md" 2>/dev/null || printf '')"
assert_not_contains "AGENTS.md has no unresolved placeholders" "$ic_agents" "@@"
assert_contains "AGENTS.md carries the session-agent spine directive" \
  "$ic_agents" "/session-agent"
assert_contains "AGENTS.md resolves the cursor config-dir token to the build target" \
  "$ic_agents" "$IC_OUT/skills/"
assert_contains "AGENTS.md carries the generated capability catalog" \
  "$ic_agents" '| `closeout` |'

# Single-occurrence regression for the catalog marker: a second copy in the
# template would be clobbered by the multi-line catalog splice. (The dedicated
# home for this invariant across every template is
# tests/entrypoint-token-occurrence.test.sh; this is the cursor-local guard.)
ic_marker_n="$(/usr/bin/grep -oF '@@CAPABILITY_CATALOG@@' \
  "$REPO_ROOT/harnesses/cursor/AGENTS.template.md" 2>/dev/null | /usr/bin/grep -c .)"
assert_eq "cursor AGENTS.template.md carries exactly one catalog marker" "1" "${ic_marker_n:-0}"

# --- T4b: an unresolvable placeholder FAILS the build (never renders empty) ---
# A generated entrypoint must never carry an empty path. The vault is the one
# optional var (it renders a sentinel), so drop the REQUIRED framework-checkout
# var instead and assert the build dies rather than shipping a hollow path.
IC_BAD_OUT="$(mktemp -d)/cursor-home"; mkdir -p "$IC_BAD_OUT"
IC_BAD_ENV="$(mktemp -d)/local.env"
printf 'CURSOR_CONFIG_DIR=%q\n' "$IC_BAD_OUT" > "$IC_BAD_ENV"
printf 'OBSIDIAN_VAULT_PATH=%q\n' "$IC_VAULT" >> "$IC_BAD_ENV"
printf 'AI_CONFIG_DIR=\n' >> "$IC_BAD_ENV"
ic_bad_rc=0
env AI_CONFIG_LOCAL_ENV="$IC_BAD_ENV" AI_CONFIG_DIR="" \
  bash "$REPO_ROOT/scripts/install.sh" --harness cursor \
  >/dev/null 2>"$IC_BAD_OUT/err.txt" || ic_bad_rc=$?
if [ "$ic_bad_rc" -eq 0 ]; then
  # AI_CONFIG_DIR defaults to the repo root when unset, so this path may legitimately
  # resolve; assert the rendered entrypoint still carries no empty placeholder.
  assert_not_contains "an AI_CONFIG_DIR-less build still renders no bare placeholder" \
    "$(cat "$IC_BAD_OUT/AGENTS.md" 2>/dev/null || printf '')" "@@"
else
  assert_contains "an unresolvable entrypoint placeholder fails the build loudly" \
    "$(cat "$IC_BAD_OUT/err.txt" 2>/dev/null)" "placeholder"
fi
rm -rf "${IC_BAD_OUT%/cursor-home}" "${IC_BAD_ENV%/local.env}"

# --- T5: preToolUse gate behavior against synthetic payloads ---
# Payload shape mirrors what a real headless run delivers (live-verified
# 2026-08-18): tool_name "Write" with tool_input.file_path + .content, and a
# conversation_id that keys the per-conversation gate marker.
if command -v jq >/dev/null 2>&1; then
  IC_GATE="$IC_OUT/hooks/session-agent.sh"
  IC_CID="testconv01"
  IC_GATEFILE="$IC_OUT/agentic-os/gate-$IC_CID"
  rm -rf "$IC_OUT/agentic-os"

  # ic_gate_decision <json> — the hook's permission verdict.
  ic_gate_decision() {
    printf '%s' "$1" | bash "$IC_GATE" 2>/dev/null | jq -r '.permission // "none"'
  }

  # ic_gate_msg / ic_gate_agent_msg <json> — the two halves of the decision.
  ic_gate_msg() {
    printf '%s' "$1" | bash "$IC_GATE" 2>/dev/null | jq -r '.user_message // ""'
  }
  ic_gate_agent_msg() {
    printf '%s' "$1" | bash "$IC_GATE" 2>/dev/null | jq -r '.agent_message // ""'
  }

  # 5a. a plain Write with no open gate → deny.
  assert_eq "gate denies a Write before the gate is open" "deny" \
    "$(ic_gate_decision '{"conversation_id":"'"$IC_CID"'","tool_name":"Write","tool_input":{"file_path":"/tmp/x.txt","content":"hi"},"cwd":"/tmp"}')"

  # 5b. the gate-declaration write itself is allowed through (gate path + BOTH
  # contract lines in the payload).
  ic_decl="$(jq -nc --arg p "$IC_GATEFILE" --arg c 'Routing: x
Lessons: none match
Linear gate: none - single-step' --arg id "$IC_CID" \
    '{conversation_id: $id, tool_name: "Write", tool_input: {file_path: $p, content: $c}, cwd: "/tmp"}')"
  assert_eq "the gate-declaration write is allowed through" "allow" \
    "$(ic_gate_decision "$ic_decl")"

  # 5b2. a declaration write carrying only the Linear gate: line is NOT a
  # complete declaration — denied (the recall-line contract).
  ic_decl_partial="$(jq -nc --arg p "$IC_GATEFILE" --arg c 'Linear gate: none - single-step' --arg id "$IC_CID" \
    '{conversation_id: $id, tool_name: "Write", tool_input: {file_path: $p, content: $c}, cwd: "/tmp"}')"
  assert_eq "a Lessons-less gate-declaration write is denied" "deny" \
    "$(ic_gate_decision "$ic_decl_partial")"

  # 5b3. schema-agnostic matching: an UNKNOWN tool_input shape carrying the same
  # path + lines still opens the gate. Cursor documents tool_input only for the
  # Shell tool, so the hook must not depend on file_path/content by name.
  ic_decl_nested="$(jq -nc --arg p "$IC_GATEFILE" --arg c 'Lessons: none match
Linear gate: none - single-step' --arg id "$IC_CID" \
    '{conversation_id: $id, tool_name: "Write", tool_input: {edits: [{target: $p, new_string: $c}]}, cwd: "/tmp"}')"
  assert_eq "an unknown Write payload shape still matches (schema-agnostic sweep)" "allow" \
    "$(ic_gate_decision "$ic_decl_nested")"

  # 5b4. CONTENT-SMUGGLING DENIED (panel fix A3): when file_path is PRESENT and
  # points somewhere else, a payload whose CONTENT merely mentions the gate path
  # + both lines must NOT be allowed — the destination field is authoritative.
  ic_smuggle="$(jq -nc --arg p "/tmp/unrelated.js" --arg c "// $IC_GATEFILE
// Linear gate: none - single-step
// Lessons: none match" --arg id "$IC_CID" \
    '{conversation_id: $id, tool_name: "Write", tool_input: {file_path: $p, content: $c}, cwd: "/tmp"}')"
  assert_eq "a smuggled gate path in an unrelated Write's content is denied" "deny" \
    "$(ic_gate_decision "$ic_smuggle")"

  # 5b5. the generated hooks.json command is a QUOTED path (panel fix A2): an
  # unquoted absolute path splits on spaces in Cursor's command parsing and the
  # gate never launches — fail-open if failClosed is inert.
  ic_cmd="$(jq -r '.hooks.preToolUse[0].command' "$IC_OUT/hooks.json")"
  case "$ic_cmd" in
    \"*\") assert_eq "hooks.json command path is double-quoted" "quoted" "quoted" ;;
    *)     assert_eq "hooks.json command path is double-quoted" "quoted" "UNQUOTED:$ic_cmd" ;;
  esac

  # 5c. once the marker is on disk with both lines, writes pass.
  mkdir -p "$IC_OUT/agentic-os"
  printf 'Routing: x\nLessons: none match\nLinear gate: none - single-step\n' > "$IC_GATEFILE"
  assert_eq "writes pass once the conversation gate file is declared" "allow" \
    "$(ic_gate_decision '{"conversation_id":"'"$IC_CID"'","tool_name":"Write","tool_input":{"file_path":"/tmp/x.txt","content":"hi"}}')"

  # 5c2. a marker missing the Lessons: line does NOT open the gate.
  printf 'Routing: x\nLinear gate: none - single-step\n' > "$IC_GATEFILE"
  assert_eq "a Lessons-less gate file does not open the gate" "deny" \
    "$(ic_gate_decision '{"conversation_id":"'"$IC_CID"'","tool_name":"Write","tool_input":{"file_path":"/tmp/x.txt"}}')"
  printf 'Routing: x\nLessons: none match\nLinear gate: none - single-step\n' > "$IC_GATEFILE"

  # 5d. kill switch bypasses the gate entirely.
  assert_eq "CLAUDE_SKIP_SESSION_AGENT=1 bypasses the gate" "allow" \
    "$(printf '%s' '{"conversation_id":"otherconv","tool_name":"Write"}' \
      | CLAUDE_SKIP_SESSION_AGENT=1 bash "$IC_GATE" | jq -r '.permission')"

  # 5e. ERROR PATHS DENY. Cursor's non-0/non-2 exit is fail-OPEN, so a hook that
  # exits quietly on a degenerate payload would silently disable the gate. Every
  # error branch must emit an explicit deny instead.
  assert_eq "a payload with no conversation_id denies (fail-closed)" "deny" \
    "$(ic_gate_decision '{"tool_name":"Write","tool_input":{"file_path":"/tmp/x"}}')"
  assert_eq "an unparseable payload denies (fail-closed)" "deny" \
    "$(ic_gate_decision 'not json at all')"
  assert_eq "a conversation_id containing a path separator denies" "deny" \
    "$(ic_gate_decision '{"conversation_id":"../../etc","tool_name":"Write"}')"

  # 5f. the hook never emits `ask` — Cursor accepts it in the schema but does
  # NOT enforce it on preToolUse, so an `ask` would silently become an allow.
  # Scan CODE lines only (comments legitimately explain why `ask` is banned);
  # both twins, since a PS-only regression would be invisible on this lane.
  # LC_ALL=C: byte-oriented awk semantics, locale-independent.
  ic_ask_hits="$(LC_ALL=C awk '!/^[[:space:]]*#/ && /ask/ {n++} END {print n+0}' \
    "$REPO_ROOT/harnesses/cursor/hooks/session-agent.sh")"
  assert_eq "the cursor gate hook (.sh) never emits permission ask" "0" "$ic_ask_hits"
  ic_ask_hits_ps="$(LC_ALL=C awk '!/^[[:space:]]*#/ && /ask/ {n++} END {print n+0}' \
    "$REPO_ROOT/harnesses/cursor/hooks/session-agent.ps1")"
  assert_eq "the cursor gate hook (.ps1) never emits permission ask" "0" "$ic_ask_hits_ps"

  # 5g. THE DENY NAMES THE MARKER PATH. `user_message` is the only half the
  # operator sees; a fixed "blocked, see the agent message" text made every
  # fresh conversation spend a sacrificial deny discovering where to write. Once
  # the conversation id is known BOTH halves must carry the literal gate path —
  # the operator reads one and the model reads the other, and the model's copy
  # is what the realization's "one deliberate gate-less Write" step relies on.
  # A conversation id with no marker on disk, writing somewhere else → deny.
  IC_CID2="testconv02"
  ic_deny_payload='{"conversation_id":"'"$IC_CID2"'","tool_name":"Write","tool_input":{"file_path":"/tmp/other.txt","content":"hi"},"cwd":"/tmp"}'
  assert_contains "the deny user_message names the literal gate-marker path" \
    "$(ic_gate_msg "$ic_deny_payload")" "$IC_OUT/agentic-os/gate-$IC_CID2"
  assert_contains "the deny agent_message names the same gate-marker path" \
    "$(ic_gate_agent_msg "$ic_deny_payload")" "$IC_OUT/agentic-os/gate-$IC_CID2"

  # 5h. EARLY denies cannot key ANY marker — there is no usable conversation id,
  # so no path would unblock the call. The message names the CAUSE and the kill
  # switch instead; pointing the reader at the side file here would be a dead end
  # (cross-model panel finding).
  for ic_early in '{"tool_name":"Write","tool_input":{"file_path":"/tmp/x"}}' \
                  '{"conversation_id":"../../etc","tool_name":"Write"}' \
                  'not json at all'; do
    ic_early_msg="$(ic_gate_msg "$ic_early")"
    assert_contains "an early deny names the no-usable-id cause" \
      "$ic_early_msg" "no usable conversation id"
    assert_contains "an early deny names the kill switch" \
      "$ic_early_msg" "CLAUDE_SKIP_SESSION_AGENT=1"
  done
  unset ic_early ic_early_msg ic_deny_payload

  # --- T6: framework-surface (sessionStart) emits the auto-fire directive ---
  ic_fs="$(printf '{"session_id":"%s","is_background_agent":false,"composer_mode":"agent"}' "$IC_CID" \
    | bash "$IC_OUT/hooks/framework-surface.sh")"
  if [ -n "$ic_fs" ]; then
    assert_exit "framework-surface emits valid JSON with a string additional_context" 0 -- \
      sh -c "printf '%s' '$(printf '%s' "$ic_fs" | sed "s/'/'\\\\''/g")' | jq -e '.additional_context | type == \"string\"' >/dev/null"
    assert_contains "framework-surface carries the session-agent kickoff directive" \
      "$ic_fs" "invoke now (Mode 1: kickoff orient)"
  else
    _skip "framework-surface emits context" "no git window / quiet exit"
  fi
  # An `ask`-mode composer cannot invoke a skill or edit files — the directive is
  # suppressed there (the framework blocks may still surface).
  ic_fs_ask="$(printf '{"session_id":"%s","composer_mode":"ask"}' "$IC_CID" \
    | bash "$IC_OUT/hooks/framework-surface.sh" | jq -r '.additional_context // ""' 2>/dev/null || printf '')"
  assert_not_contains "framework-surface suppresses the directive in ask-mode" \
    "$ic_fs_ask" "invoke now (Mode 1: kickoff orient)"
  # The surfacing hook fails OPEN: the whole-hook kill switch silences it.
  assert_eq "CLAUDE_SKIP_FRAMEWORK_SURFACE=1 silences the surfacing hook" "" \
    "$(printf '{"session_id":"x"}' | CLAUDE_SKIP_FRAMEWORK_SURFACE=1 bash "$IC_OUT/hooks/framework-surface.sh")"

  # --- T6b: the conversation-id side file ------------------------------------
  # sessionStart publishes the id to <config>/agentic-os/current-session so a
  # model that lost the injected directive can `cat` it instead of burning a
  # deny to discover it. The write must never change this hook's exit or its
  # stdout — it is fail-OPEN, and a broken state write may not break a session.
  IC_SIDE="$IC_OUT/agentic-os/current-session"

  # (a) a usable id publishes the file AND earns the directive sentence.
  rm -f "$IC_SIDE"
  ic_surface_rc=0
  ic_surface_out="$(printf '{"session_id":"abc123","composer_mode":"agent"}' \
    | bash "$IC_OUT/hooks/framework-surface.sh")" || ic_surface_rc=$?
  assert_eq "sessionStart still exits 0 while writing the side file" "0" "$ic_surface_rc"
  assert_contains "sessionStart still emits additional_context alongside the side file" \
    "$ic_surface_out" "additional_context"
  assert_eq "sessionStart writes session_id to the current-session side file" "abc123" \
    "$(cat "$IC_SIDE" 2>/dev/null)"
  # One line + a trailing newline, not a bare 6-byte token: `cat` in the
  # realization's read step must not glue the id onto the next shell word.
  assert_eq "the side file is one line with a trailing newline" "7" \
    "$(wc -c < "$IC_SIDE" | tr -d ' ')"
  assert_contains "the emitted directive names the side file as the id re-read path" \
    "$ic_surface_out" "agentic-os/current-session"

  # (b) OVERWRITE + the `conversation_id` spelling in one fixture: the file is
  # NOT deleted between the two runs, so this also pins last-writer-wins — a
  # second sessionStart under the same config home must replace the first id,
  # not append to or leave the old one.
  printf '{"conversation_id":"def456","composer_mode":"agent"}' \
    | bash "$IC_OUT/hooks/framework-surface.sh" >/dev/null 2>&1
  assert_eq "a second sessionStart overwrites the side file (conversation_id spelling)" "def456" \
    "$(cat "$IC_SIDE" 2>/dev/null)"
  assert_eq "the overwritten side file is also one line with a trailing newline" "7" \
    "$(wc -c < "$IC_SIDE" | tr -d ' ')"

  # (c) An id the gate would refuse never forms a usable marker path, so
  # publishing it would hand the model a broken one. The hook must write nothing
  # AND say nothing about a side file — a directive naming a path that holds
  # some OTHER conversation's id is worse than no directive sentence at all.
  rm -f "$IC_SIDE"
  ic_surface_rc=0
  ic_surface_out="$(printf '{"session_id":"a/b","composer_mode":"agent"}' \
    | bash "$IC_OUT/hooks/framework-surface.sh")" || ic_surface_rc=$?
  assert_eq "an unsafe session id still exits 0" "0" "$ic_surface_rc"
  assert_contains "an unsafe session id still emits additional_context" \
    "$ic_surface_out" "additional_context"
  assert_not_contains "an unsafe session id emits no side-file sentence" \
    "$ic_surface_out" "current-session"
  if [ -e "$IC_SIDE" ]; then
    _fail "an unsafe session id is never published to the side file" \
      "wrote: $(cat "$IC_SIDE" 2>/dev/null)"
  else
    _pass "an unsafe session id is never published to the side file"
  fi

  # (d) WRITE FAILURE. A usable id whose write cannot land must not produce a
  # directive claiming it did — that would send the model to a nonexistent path
  # or, worse, to a stale id from another conversation. Force the failure by
  # putting a regular FILE where the state dir belongs, so `mkdir -p` fails.
  rm -rf "$IC_OUT/agentic-os"
  : > "$IC_OUT/agentic-os"
  ic_surface_rc=0
  ic_surface_out="$(printf '{"session_id":"xyz789","composer_mode":"agent"}' \
    | bash "$IC_OUT/hooks/framework-surface.sh")" || ic_surface_rc=$?
  assert_eq "a failed side-file write still exits 0 (fail-OPEN)" "0" "$ic_surface_rc"
  assert_contains "a failed side-file write still emits additional_context" \
    "$ic_surface_out" "additional_context"
  assert_not_contains "a failed side-file write claims no side file in the directive" \
    "$ic_surface_out" "current-session"
  rm -f "$IC_OUT/agentic-os"
  mkdir -p "$IC_OUT/agentic-os"

  unset -f ic_gate_decision ic_gate_msg ic_gate_agent_msg
else
  _skip "cursor hook behavior suite" "jq not installed"
fi

rm -rf "${IC_OUT%/cursor-home}" "${IC_ENV%/local.env}" "${IC_VAULT%/vault}"
unset IC_OUT IC_ENV IC_VAULT IC_GATE IC_CID IC_CID2 IC_GATEFILE IC_SIDE \
      ic_surface_rc ic_surface_out
