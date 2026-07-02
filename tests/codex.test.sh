#!/usr/bin/env bash
# tests/codex.test.sh — Codex-target build acceptance tests.
# Sourced by tests/run.sh — must only call assert_* helpers, never `exit`.

# Shared fixture local.env for the codex target.
CX_DIR="$(mktemp -d)"
CX_OUT="$CX_DIR/out"; mkdir -p "$CX_OUT"
CX_VAULT="$CX_DIR/vault"
CX_ENV="$CX_DIR/local.env"
make_codex_env "$CX_ENV" "$CX_OUT" "$CX_VAULT"

# === Build-only: every managed path is produced =============================
cx_build="$(AI_CONFIG_LOCAL_ENV="$CX_ENV" bash "$REPO_ROOT/scripts/install.sh" --harness codex --build-only 2>/dev/null)"

assert_file "codex build emits session-agent SKILL.md" "$cx_build/skills/session-agent/SKILL.md"
assert_file "codex build emits AGENTS.md"              "$cx_build/AGENTS.md"
if [ -n "$cx_build" ] && [ -f "$cx_build/skills/session-agent/SKILL.md" ]; then
  cx_sa="$(cat "$cx_build/skills/session-agent/SKILL.md")"
  assert_contains "codex session-agent SKILL.md has neutral protocol" "$cx_sa" "Session Agent — Session Kickoff Orient + Routing"
  assert_contains "codex session-agent SKILL.md has Codex realization" "$cx_sa" "Codex realization"
fi

# Each native capability compiles to a SKILL.md.
for capn in session-agent closeout; do
  assert_file "codex build emits $capn SKILL.md" "$cx_build/skills/$capn/SKILL.md"
done

# the deleted route + skill-orchestrator capabilities must NOT
# generate output. Catalog row absence is asserted later (the inverse
# advertise-but-can't-discover risk); these assert the build artifact level
# (the inverse: discover-but-not-in-catalog).
for deleted in route skill-orchestrator; do
  [ -e "$cx_build/skills/$deleted/SKILL.md" ] \
    && _fail "codex build does NOT generate deleted $deleted SKILL.md" "skills/$deleted/SKILL.md still produced" \
    || _pass "codex build does NOT generate deleted $deleted SKILL.md"
done

# Each Codex hook script is compiled into hooks/.
# (closeout.sh removed — closeout is now manual-fire, no Stop hook.)
for h in session-agent.sh framework-surface.sh; do
  assert_file "codex build emits hook $h" "$cx_build/hooks/$h"
done

# the deleted route.sh hook must NOT be in the build.
[ -e "$cx_build/hooks/route.sh" ] \
  && _fail "codex build does NOT generate deleted hooks/route.sh" "hooks/route.sh still produced" \
  || _pass "codex build does NOT generate deleted hooks/route.sh"

# hooks.json is generated and well-formed.
assert_file "codex build emits hooks.json" "$cx_build/hooks.json"
if [ -f "$cx_build/hooks.json" ]; then
  assert_exit "codex hooks.json is valid JSON" 0 -- jq empty "$cx_build/hooks.json"
  # UserPromptSubmit was the cross-model-review prompt-scan hook, now
  # removed with the capability.: the closeout `Stop` hook was removed
  # (closeout is now manual-fire). PreToolUse / SessionStart are the wired events.
  for ev in PreToolUse SessionStart; do
    has="$(jq -r --arg e "$ev" '.hooks[$e] != null' "$cx_build/hooks.json")"
    assert_eq "codex hooks.json wires $ev" "true" "$has"
  done
  # negative guard: the closeout Stop hook must NOT be wired.
  assert_eq "codex hooks.json does NOT wire a Stop hook" "true" \
    "$(jq -r '.hooks.Stop == null' "$cx_build/hooks.json")"
  assert_eq "codex PreToolUse matcher is apply_patch" "apply_patch" \
    "$(jq -r '.hooks.PreToolUse[0].matcher' "$cx_build/hooks.json")"
  cx_cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$cx_build/hooks.json")"
  assert_contains "codex PreToolUse command points at target hooks dir" "$cx_cmd" "$CX_OUT/hooks/session-agent.sh"
fi

# Build manifest tracks the codex generated files and sources.
cx_mf="$cx_build/.build-manifest.json"
assert_file "codex build emits .build-manifest.json" "$cx_mf"
if [ -f "$cx_mf" ]; then
  assert_exit "codex manifest is valid JSON" 0 -- jq empty "$cx_mf"
  assert_eq "codex manifest records the harness" "codex" "$(jq -r '.harness' "$cx_mf")"
  assert_eq "codex manifest tracks AGENTS.md generated" "true" \
    "$(jq -r '.generated["AGENTS.md"] != null' "$cx_mf")"
  assert_eq "codex manifest tracks hooks.json generated" "true" \
    "$(jq -r '.generated["hooks.json"] != null' "$cx_mf")"
  assert_eq "codex manifest tracks the codex adapter as a source" "true" \
    "$(jq -r '.sources["harnesses/codex/adapter.md"] != null' "$cx_mf")"
  assert_eq "codex manifest tracks AGENTS.template.md as a source" "true" \
    "$(jq -r '.sources["harnesses/codex/AGENTS.template.md"] != null' "$cx_mf")"
fi

# Adapter prose hygiene. The 4 removed vendored skills (firecrawl, impeccable,
# printing-press, silver-platter) must not appear in any harnesses/<h>/adapter.md
# scope note. Catches stale cross-cutting prose (deleted vendored-skill names)
# that the catalog-deletion regression doesn't scan.
for adapter in "$REPO_ROOT/harnesses"/*/adapter.md; do
  [ -f "$adapter" ] || continue
  hname="$(basename "$(dirname "$adapter")")"
  stale_refs="$(grep -nE "firecrawl|impeccable|printing-press|silver-platter" "$adapter" 2>/dev/null || true)"
  assert_eq "harnesses/$hname/adapter.md has no stale vendored-skill refs" "" "$stale_refs"
done

# AGENTS.md carries the framework layers + routing protocol + capability catalog.
if [ -f "$cx_build/AGENTS.md" ]; then
  cx_agents="$(cat "$cx_build/AGENTS.md")"
  assert_contains "codex AGENTS.md references README.md"          "$cx_agents" "README.md"
  assert_contains "codex AGENTS.md references core/"              "$cx_agents" "core/"
  assert_contains "codex AGENTS.md carries the session-agent spine rule"  "$cx_agents" "session-agent\` is the spine"
  assert_not_contains "codex AGENTS.md has no unresolved placeholders" "$cx_agents" "@@"
  assert_contains "codex AGENTS.md substitutes the vault path"     "$cx_agents" "$CX_VAULT"
  assert_contains "codex AGENTS.md substitutes the agentic-os-template path" "$cx_agents" "$REPO_ROOT"
  for capn in session-agent closeout; do
    assert_contains "codex AGENTS.md catalog has a row for $capn" "$cx_agents" "| \`$capn\` |"
  done
  # the deleted route + skill-orchestrator capabilities must NOT appear
  # in the catalog. AGENTS.md would otherwise advertise capabilities Codex has no
  # installed skill for.
  for deleted in route skill-orchestrator; do
    assert_not_contains "codex AGENTS.md catalog omits deleted $deleted" "$cx_agents" "| \`$deleted\` |"
  done
  # the deleted firecrawl, impeccable, printing-press, silver-platter
  # capabilities (removed from the framework; preserved as Shape C operator-local)
  # must NOT appear in the catalog. AGENTS.md would otherwise advertise
  # capabilities the framework no longer ships.
  for deleted in firecrawl impeccable printing-press silver-platter; do
    assert_not_contains "codex AGENTS.md catalog omits removed $deleted" "$cx_agents" "| \`$deleted\` |"
  done
fi
[ -n "$cx_build" ] && rm -rf "$cx_build"

# === Determinism: two codex builds are byte-identical =======================
cx_det_a="$(AI_CONFIG_LOCAL_ENV="$CX_ENV" bash "$REPO_ROOT/scripts/install.sh" --harness codex --build-only 2>/dev/null)"
cx_det_b="$(AI_CONFIG_LOCAL_ENV="$CX_ENV" bash "$REPO_ROOT/scripts/install.sh" --harness codex --build-only 2>/dev/null)"
cx_det=0; diff -r "$cx_det_a" "$cx_det_b" >/dev/null 2>&1 || cx_det=$?
assert_eq "codex: two builds are byte-identical (diff -r)" "0" "$cx_det"
rm -rf "$cx_det_a" "$cx_det_b"

# === a relative --out yields absolute hooks.json command paths ====
# install.sh must canonicalize TARGET to an absolute path — a relative --out
# (or relative CODEX_HOME) otherwise leaks relative `command` paths into the
# generated hooks.json, which Codex resolves against an unpredictable CWD.
CXR_WORK="$(mktemp -d)"
CXR_ENV="$CXR_WORK/local.env"
make_codex_env "$CXR_ENV" "$CXR_WORK/unused"   # CODEX_HOME unused — --out drives it
( cd "$CXR_WORK" && AI_CONFIG_LOCAL_ENV="$CXR_ENV" \
    bash "$REPO_ROOT/scripts/install.sh" --harness codex --out ./reltgt >/dev/null 2>&1 )
cxr_hooks="$CXR_WORK/reltgt/hooks.json"
assert_file "codex: relative --out still produces hooks.json" "$cxr_hooks"
if [ -f "$cxr_hooks" ]; then
  cxr_rel="$(jq -r '[.hooks[][].hooks[].command] | map(select(startswith("/") | not)) | length' "$cxr_hooks")"
  assert_eq "codex: every hooks.json command path is absolute" "0" "$cxr_rel"
fi
rm -rf "$CXR_WORK"

# === Full install: swap into the target + drift gate ========================
CXB_OUT="$(mktemp -d)/target"; mkdir -p "$CXB_OUT"
CXB_ENV="$(mktemp -d)/local.env"
make_codex_env "$CXB_ENV" "$CXB_OUT"
cxb_err="$(mktemp)"
AI_CONFIG_LOCAL_ENV="$CXB_ENV" bash "$REPO_ROOT/scripts/install.sh" --harness codex >/dev/null 2>"$cxb_err"
cxb_status=$?
assert_eq "codex full install exits 0" "0" "$cxb_status"
# The codex build is inert until the user trusts its hooks.json — install.sh
# must surface that manual step (adapter.md Fact 2 documents it as surfaced).
assert_contains "codex install surfaces the /hooks trust step" "$(cat "$cxb_err")" "/hooks"
assert_file "codex full install swaps session-agent SKILL.md" "$CXB_OUT/skills/session-agent/SKILL.md"
assert_file "codex full install swaps hooks.json"             "$CXB_OUT/hooks.json"
assert_file "codex full install swaps AGENTS.md"              "$CXB_OUT/AGENTS.md"
assert_file "codex full install swaps the session-agent hook" "$CXB_OUT/hooks/session-agent.sh"
# No backup/temp dirs left behind.
cx_leftover="$(find "$CXB_OUT" -maxdepth 1 -name '.install-bak.*' -o -maxdepth 1 -name '.install-build.*' | head -1)"
assert_eq "codex install leaves no backup/temp dirs" "" "$cx_leftover"
# A clean codex build passes the drift gate.
assert_exit "codex drift check passes on a clean build" 0 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$CXB_OUT"

# === Codex hook behaviour ===================================================
# Feed each compiled Codex hook a mock Codex event payload, assert exit code +
# the deny/continue/inject side effect. Helpers are defined locally because
# tests/hooks-behavior.test.sh is sourced after this file.
fix="$REPO_ROOT/tests/fixtures"
CXH="$CXB_OUT/hooks"

# cx_run_hook <script> <stdin-payload> [env-assignments...] -> "<exit>|<stdout>"
cx_run_hook() {
  local script="$1" payload="$2"; shift 2
  local out status
  out="$(printf '%s' "$payload" | env "$@" bash "$script" 2>/dev/null)" && status=0 || status=$?
  printf '%s|%s' "$status" "$out"
}
# cx_classify_block <result> -> "block" if the hook denies/continues, else "allow".
# Covers both Codex PreToolUse block shapes: the modern
# hookSpecificOutput.permissionDecision:"deny" (deny path) AND the legacy
# top-level {"decision":"block"} (jq-missing fail-closed path, asserted by cj1).
# Codex honors BOTH on PreToolUse — verified v0.132.0 pre-tool-use.command.output
# schema; see harnesses/codex/adapter.md. (Contrast Claude Code, where the legacy
# top-level form is a no-op on PreToolUse —.)
cx_classify_block() {
  case "${1#*|}" in
    *'"permissionDecision":"deny"'*|*'"decision":"block"'*) echo "block";;
    *) echo "allow";;
  esac
}
cx_classify_directive() {
  case "${1#*|}" in *"$2"*) echo "directive";; *) echo "silent";; esac
}

# session-agent.sh (PreToolUse / apply_patch)
cx_session_agent_payload() { printf '{"transcript_path":"%s","tool_name":"apply_patch"}' "$1"; }

cr1="$(cx_run_hook "$CXH/session-agent.sh" '{"tool_name":"apply_patch"}')"
assert_eq "codex session-agent: no transcript exits 0" "0" "${cr1%%|*}"
assert_eq "codex session-agent: no transcript allows"  "allow" "$(cx_classify_block "$cr1")"

cr2="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_session_agent_payload "$fix/codex-transcript-empty.jsonl")")"
assert_eq "codex session-agent: no routing exits 0" "0" "${cr2%%|*}"
assert_eq "codex session-agent: no routing blocks"  "block" "$(cx_classify_block "$cr2")"

cr3="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_session_agent_payload "$fix/codex-transcript-session-agent-ok.jsonl")")"
assert_eq "codex session-agent: invoked+Linear allows" "allow" "$(cx_classify_block "$cr3")"

cr4="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_session_agent_payload "$fix/codex-transcript-session-agent-no-linear.jsonl")")"
assert_eq "codex session-agent: invoked w/o Linear blocks" "block" "$(cx_classify_block "$cr4")"

# <TEAM>-360 vacuousness regressions. Codex injects a skills CATALOG (a developer
# message listing every skill's `(file: …/SKILL.md)` path) into EVERY session's
# rollout, so a bare path grep opened the ran-check without any invocation; the
# injected skill body and a prior deny message both quote `Linear gate:` lines,
# so a whole-transcript grep opened the gate too. The enriched fixtures model
# all three noise sources — a regression back to whole-transcript greps flips
# cr4/cr6 to allow and fails here.
cr6="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_session_agent_payload "$fix/codex-transcript-catalog-only.jsonl")")"
assert_eq "codex session-agent: catalog-only transcript exits 0" "0" "${cr6%%|*}"
assert_eq "codex session-agent: skills catalog alone is not an invocation" "block" "$(cx_classify_block "$cr6")"
assert_contains "codex session-agent: catalog-only deny is the not-invoked reason" "${cr6#*|}" "has not been invoked"
cx_nl_fixture="$(cat "$fix/codex-transcript-session-agent-no-linear.jsonl")"
assert_contains "codex no-linear fixture models the catalog path line"    "$cx_nl_fixture" 'skills/session-agent/SKILL.md'
assert_contains "codex no-linear fixture models the injected template line" "$cx_nl_fixture" 'Linear gate: <ISSUE-ID'
assert_contains "codex no-linear fixture models a prior deny message"     "$cx_nl_fixture" 'no `Linear gate:` declaration'

# Windows-separator ran marker (panel follow-up): the bash twin must accept a
# backslash SKILL.md path in a function_call, like the PS twin's F-1 amendment.
# Raw JSONL carries four backslashes (doubly JSON-encoded single separator).
cr_bs_fix="$(mktemp -d)/codex-bs.jsonl"
cat > "$cr_bs_fix" <<'CR_BS'
{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"type skills\\\\session-agent\\\\SKILL.md\"}","call_id":"c1"}}
{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"text","text":"Routing: x\nLinear gate: PROJ-1"}]}}
CR_BS
cr7="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_session_agent_payload "$cr_bs_fix")")"
assert_eq "codex session-agent: backslash marker path allows (bash twin)" "allow" "$(cx_classify_block "$cr7")"
rm -rf "${cr_bs_fix%/codex-bs.jsonl}"

# Case sensitivity (panel follow-up): a lowercase `linear gate:` is NOT the
# declaration — bash grep is case-sensitive and the PS twins use -cmatch.
cr_lc_fix="$(mktemp -d)/codex-lc.jsonl"
cat > "$cr_lc_fix" <<'CR_LC'
{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"cat skills/session-agent/SKILL.md\"}","call_id":"c1"}}
{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"text","text":"Routing: x\nlinear gate: PROJ-1"}]}}
CR_LC
cr8="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_session_agent_payload "$cr_lc_fix")")"
assert_eq "codex session-agent: lowercase declaration still blocks" "block" "$(cx_classify_block "$cr8")"
rm -rf "${cr_lc_fix%/codex-lc.jsonl}"

cr5="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_session_agent_payload "$fix/codex-transcript-empty.jsonl")" CLAUDE_SKIP_SESSION_AGENT=1)"
assert_eq "codex session-agent: kill switch allows" "allow" "$(cx_classify_block "$cr5")"

# framework-surface.sh (SessionStart)
cf1="$(cx_run_hook "$CXH/framework-surface.sh" '{}' CLAUDE_FRAMEWORK_SINCE_DAYS=3650)"
assert_eq "codex framework-surface: emits context exits 0" "0" "${cf1%%|*}"
assert_contains "codex framework-surface: emits additionalContext" "${cf1#*|}" "additionalContext"

cf2="$(cx_run_hook "$CXH/framework-surface.sh" '{}' CLAUDE_SKIP_FRAMEWORK_SURFACE=1)"
assert_eq "codex framework-surface: kill switch is silent" "" "${cf2#*|}"

# codex framework-surface session-agent invocation directive.
# default -> probe emits the SA_BLOCK header
# CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE=1 -> SA_BLOCK omitted; git-log preserved
cf_sa1="$(cx_run_hook "$CXH/framework-surface.sh" '{}' CLAUDE_FRAMEWORK_SINCE_DAYS=3650)"
assert_eq          "codex framework-surface: session-agent directive exits 0"      "0"            "${cf_sa1%%|*}"
assert_contains    "codex framework-surface: emits session-agent directive header" "${cf_sa1#*|}" "Session-agent — invoke now"
assert_contains    "codex framework-surface: directive references Mode 1"          "${cf_sa1#*|}" "Mode 1"
assert_contains    "codex framework-surface: directive uses \$session-agent"       "${cf_sa1#*|}" '$session-agent'
assert_contains    "codex framework-surface: directive references kill switch"     "${cf_sa1#*|}" "CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE"

cf_sa2="$(cx_run_hook "$CXH/framework-surface.sh" '{}' \
  CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE=1 CLAUDE_FRAMEWORK_SINCE_DAYS=3650)"
assert_eq           "codex framework-surface: SA-directive kill switch exits 0"      "0"            "${cf_sa2%%|*}"
assert_not_contains "codex framework-surface: SA-directive kill switch drops block"  "${cf_sa2#*|}" "Session-agent — invoke now"
assert_contains     "codex framework-surface: SA-directive kill switch keeps git-log" "${cf_sa2#*|}" "additionalContext"

# compaction-aware session-agent directive (<TEAM>-360 — mirrors the Claude twin's
# behavior + tests). source=compact must emit the IDEMPOTENT re-orient, not the
# kickoff; startup/absent/malformed sources keep the kickoff (prior behavior).
cf_compact="$(cx_run_hook "$CXH/framework-surface.sh" '{"source":"compact"}' CLAUDE_FRAMEWORK_SINCE_DAYS=3650)"
assert_eq           "codex framework-surface: compact directive exits 0"             "0"            "${cf_compact%%|*}"
assert_contains     "codex framework-surface: compact emits re-orient header"        "${cf_compact#*|}" "re-orient after compacted session"
assert_contains     "codex framework-surface: compact directive references Mode 1"   "${cf_compact#*|}" "Mode 1"
assert_contains     "codex framework-surface: compact directive references Mode 2"   "${cf_compact#*|}" "Mode 2"
assert_not_contains "codex framework-surface: compact drops the kickoff header"      "${cf_compact#*|}" "invoke now (Mode 1: kickoff orient)"

cf_startup="$(cx_run_hook "$CXH/framework-surface.sh" '{"source":"startup"}' CLAUDE_FRAMEWORK_SINCE_DAYS=3650)"
assert_contains     "codex framework-surface: explicit startup keeps kickoff header" "${cf_startup#*|}" "Session-agent — invoke now"
assert_not_contains "codex framework-surface: startup drops the re-orient header"    "${cf_startup#*|}" "re-orient after"

cf_bad="$(cx_run_hook "$CXH/framework-surface.sh" 'not-json{' CLAUDE_FRAMEWORK_SINCE_DAYS=3650)"
assert_eq           "codex framework-surface: malformed source JSON exits 0"         "0"            "${cf_bad%%|*}"
assert_contains     "codex framework-surface: malformed source JSON keeps kickoff"   "${cf_bad#*|}" "Session-agent — invoke now"
assert_not_contains "codex framework-surface: malformed source JSON drops re-orient" "${cf_bad#*|}" "re-orient after"

# F3 — jq contract: the codex gate hook fails closed without jq; the
# surfacing hook fails open. CX_NOJQ is a PATH dir without jq symlinked.
CX_NOJQ="$(mktemp -d)"
for _b in bash cat grep sed git env printf; do
  _p="$(command -v "$_b" 2>/dev/null)" && ln -s "$_p" "$CX_NOJQ/$_b"
done
cj1="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_session_agent_payload "$fix/codex-transcript-session-agent-ok.jsonl")" PATH="$CX_NOJQ")"
assert_eq "codex session-agent: no jq exits 0"               "0" "${cj1%%|*}"
assert_eq "codex session-agent: no jq fails closed (blocks)" "block" "$(cx_classify_block "$cj1")"
cj3="$(cx_run_hook "$CXH/framework-surface.sh" '{}' PATH="$CX_NOJQ" CLAUDE_FRAMEWORK_SINCE_DAYS=3650)"
assert_eq "codex framework-surface: no jq exits 0"          "0" "${cj3%%|*}"
assert_eq "codex framework-surface: no jq is silent (open)" "" "${cj3#*|}"
rm -rf "$CX_NOJQ"

# === Drift gate catches a hand-edited generated entrypoint ==================
printf '\nHAND EDIT\n' >> "$CXB_OUT/AGENTS.md"
assert_exit "codex drift check fails after AGENTS.md is hand-edited" 1 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$CXB_OUT"

rm -rf "$CXB_OUT"
rm -rf "$CX_DIR"
