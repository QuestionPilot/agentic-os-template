#!/usr/bin/env bash
# tests/install-hermes.test.sh — the hermes harness build
# (`install.sh --harness hermes`) + the hermes hook behaviors.
#
# Covers: build output map (skills / hooks / hooks.yaml snippet / bridge
# plugin / SOUL.md / manifest), drift-gate pass on a fresh build, the
# pre-edit-gate hook's block/allow paths against synthetic pre_tool_call
# payloads, and the framework-surface hook's context emission shape.
#
# Sourced by tests/run.sh; uses assert_* helpers from tests/lib.sh.
# Never call `exit` — failures bubble through assertion counters.
# slow

IH_OUT="$(mktemp -d)/hermes-home"; mkdir -p "$IH_OUT"
IH_ENV="$(mktemp -d)/local.env"
make_hermes_env "$IH_ENV" "$IH_OUT"

assert_exit "install.sh --harness hermes builds clean" 0 -- \
  env AI_CONFIG_LOCAL_ENV="$IH_ENV" bash "$REPO_ROOT/scripts/install.sh" --harness hermes

# --- T1: build output map ---
for f in \
  "skills/session-agent/SKILL.md" \
  "skills/closeout/SKILL.md" \
  "skills/self-audit/SKILL.md" \
  "hooks/framework-surface.sh" \
  "hooks/session-agent.sh" \
  "hooks/hooks.yaml" \
  "plugins/agentic-os-hook-bridge/plugin.yaml" \
  "plugins/agentic-os-hook-bridge/__init__.py" \
  "SOUL.md" \
  ".build-manifest.json"; do
  assert_file "hermes build produced $f" "$IH_OUT/$f"
done

# --- T2: hooks.yaml snippet carries the edit-gate matcher + the bridge ---
ih_yaml="$(cat "$IH_OUT/hooks/hooks.yaml" 2>/dev/null || printf '')"
assert_contains "hooks.yaml wires the pre_tool_call edit-gate matcher" \
  "$ih_yaml" 'matcher: "write_file|patch|terminal"'
assert_contains "hooks.yaml wires on_session_start to framework-surface" \
  "$ih_yaml" "on_session_start"
assert_contains "hooks.yaml enables the agentic-os-hook-bridge plugin" \
  "$ih_yaml" "agentic-os-hook-bridge"

# --- T3: drift gate passes a fresh build ---
assert_exit "check-drift passes the fresh hermes build" 0 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$IH_OUT"

# --- T4: SOUL.md has the capability catalog and no unresolved placeholders ---
ih_soul="$(cat "$IH_OUT/SOUL.md" 2>/dev/null || printf '')"
assert_contains "SOUL.md carries the session-agent spine directive" \
  "$ih_soul" "/session-agent"
assert_not_contains "SOUL.md has no unresolved placeholders" \
  "$ih_soul" "@@"

# --- T5: edit-gate hook behavior against synthetic payloads ---
if command -v jq >/dev/null 2>&1; then
  IH_GATE="$IH_OUT/hooks/session-agent.sh"
  IH_SID="testsession01"

  # 5a. write_file with no open gate → block.
  ih_out="$(printf '%s' \
    '{"hook_event_name":"pre_tool_call","tool_name":"write_file","tool_input":{"path":"/tmp/x.txt","content":"hi"},"session_id":"'"$IH_SID"'","cwd":"/tmp"}' \
    | bash "$IH_GATE")"
  assert_contains "gate blocks a write_file before the gate is open" \
    "$ih_out" '"decision":"block"'

  # 5b. terminal with no open gate → block.
  ih_out="$(printf '%s' \
    '{"hook_event_name":"pre_tool_call","tool_name":"terminal","tool_input":{"command":"echo hi > /tmp/x"},"session_id":"'"$IH_SID"'","cwd":"/tmp"}' \
    | bash "$IH_GATE")"
  assert_contains "gate blocks a terminal call before the gate is open" \
    "$ih_out" '"decision":"block"'

  # 5c. the gate-declaration write itself is allowed through (exact per-session
  # path + a Linear gate: line in the content) and silent.
  ih_decl_path="$IH_OUT/agentic-os/gate-$IH_SID"
  ih_out="$(printf '{"hook_event_name":"pre_tool_call","tool_name":"write_file","tool_input":{"path":"%s","content":"Routing: x\\nLinear gate: none — single-step"},"session_id":"%s","cwd":"/tmp"}' \
    "$ih_decl_path" "$IH_SID" | bash "$IH_GATE")"
  assert_eq "the gate-declaration write is allowed (silent stdout)" "" "$ih_out"

  # 5d. once the gate file exists with a Linear gate: line, writes pass.
  mkdir -p "$IH_OUT/agentic-os"
  printf 'Routing: x\nLinear gate: none — single-step\n' > "$ih_decl_path"
  ih_out="$(printf '%s' \
    '{"hook_event_name":"pre_tool_call","tool_name":"write_file","tool_input":{"path":"/tmp/x.txt","content":"hi"},"session_id":"'"$IH_SID"'","cwd":"/tmp"}' \
    | bash "$IH_GATE")"
  assert_eq "writes pass once the session gate file is declared" "" "$ih_out"

  # 5e. kill switch bypasses the gate entirely.
  ih_out="$(printf '%s' \
    '{"hook_event_name":"pre_tool_call","tool_name":"write_file","tool_input":{"path":"/tmp/x.txt","content":"hi"},"session_id":"othersession"}' \
    | CLAUDE_SKIP_SESSION_AGENT=1 bash "$IH_GATE")"
  assert_eq "CLAUDE_SKIP_SESSION_AGENT=1 bypasses the gate" "" "$ih_out"

  # 5f. a synthetic payload with no session id stays silent (hooks test shape).
  ih_out="$(printf '%s' \
    '{"hook_event_name":"pre_tool_call","tool_name":"write_file","tool_input":{"path":"/tmp/x.txt"}}' \
    | bash "$IH_GATE")"
  assert_eq "a payload without session_id stays silent" "" "$ih_out"

  # --- T6: framework-surface emits Hermes context-injection shape ---
  ih_fs="$(printf '{"hook_event_name":"on_session_start","session_id":"%s"}' "$IH_SID" \
    | bash "$IH_OUT/hooks/framework-surface.sh")"
  if [ -n "$ih_fs" ]; then
    assert_exit "framework-surface output is valid JSON" 0 -- \
      sh -c "printf '%s' '$(printf '%s' "$ih_fs" | sed "s/'/'\\\\''/g")' | jq -e '.context | type == \"string\"' >/dev/null"
  else
    _skip "framework-surface emits context" "no git window / quiet exit"
  fi
else
  _skip "hermes hook behavior suite" "jq not installed"
fi

rm -rf "${IH_OUT%/hermes-home}" "${IH_ENV%/local.env}"
