#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
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
  assert_eq "codex PreToolUse matcher covers Bash and native edit names" "Bash|apply_patch|Edit|Write" \
    "$(jq -r '.hooks.PreToolUse[0].matcher' "$cx_build/hooks.json")"
  cx_cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$cx_build/hooks.json")"
  assert_contains "codex PreToolUse command points at target hooks dir" "$cx_cmd" "$CX_OUT/hooks/session-agent.sh"
  assert_eq "codex PreToolUse command shell-quotes its absolute path" "'$CX_OUT/hooks/session-agent.sh'" "$cx_cmd"
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
  cxr_rel="$(jq -r '[.hooks[][].hooks[].command | gsub("^'"'"'|'"'"'$"; "")] | map(select(startswith("/") | not)) | length' "$cxr_hooks")"
  assert_eq "codex: every hooks.json command path is absolute" "0" "$cxr_rel"
fi
rm -rf "$CXR_WORK"

# The hook command is executed by a shell. A path containing spaces therefore
# needs its own shell quotes, not only JSON escaping. Exercise the exact emitted
# command with a benign hook payload to prevent the runtime wiring from regressing.
CXS_OUT="$CX_DIR/target with space's quote"; mkdir -p "$CXS_OUT"
CXS_ENV="$CX_DIR/spaced-local.env"
make_codex_env "$CXS_ENV" "$CXS_OUT" "$CX_VAULT"
AI_CONFIG_LOCAL_ENV="$CXS_ENV" bash "$REPO_ROOT/scripts/install.sh" --harness codex >/dev/null 2>&1
cxs_cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$CXS_OUT/hooks.json")"
cxs_result="$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":""}}' | bash -c "$cxs_cmd" 2>&1)"; cxs_status=$?
assert_eq "codex: quoted hook command with a spaced target exits 0" "0" "$cxs_status"
assert_eq "codex: quoted hook command with a spaced target is silent for a safe read" "" "$cxs_result"

# === Full install: swap into the target + drift gate ========================
CXB_OUT="$(mktemp -d)/target"; mkdir -p "$CXB_OUT"
CXB_ENV="$(mktemp -d)/local.env"
make_codex_env "$CXB_ENV" "$CXB_OUT"
cxb_err="$(mktemp)"
env -u AGENTS_DIR AI_CONFIG_LOCAL_ENV="$CXB_ENV" bash "$REPO_ROOT/scripts/install.sh" --harness codex >/dev/null 2>"$cxb_err"
cxb_status=$?
assert_eq "codex full install exits 0" "0" "$cxb_status"
# The codex build is inert until the user trusts its hooks.json — install.sh
# must surface that manual step (adapter.md Fact 2 documents it as surfaced).
assert_contains "codex install surfaces the /hooks trust step" "$(cat "$cxb_err")" "/hooks"
assert_contains "codex install reports the gate as unverified" "$(cat "$cxb_err")" "Gate status: UNVERIFIED"
assert_not_contains "codex install does not report the gate armed from file presence" "$(cat "$cxb_err")" "Gate status: ARMED"
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

# === .agents co-render: loud skip + live-overlay guard ======================
# Without AGENTS_DIR the codex install skips the co-render LOUDLY (a
# configured-but-forgotten overlay must be visible, never silently stale).
# The happy path — byte-identity, Shape C preservation, agents manifest,
# --auto coverage — is exercised in tests/drift.test.sh's --auto block.
assert_contains "codex install skips the .agents co-render loudly when AGENTS_DIR is unset" \
  "$(cat "$cxb_err")" "AGENTS_DIR not set"

# A throwaway local.env whose AGENTS_DIR names the repo's LIVE overlay must be
# refused (the same inherited-var corruption guard the harness-home targets
# have) — the die fires before any write to the overlay. String-compare based,
# so it holds whether or not .agents exists in this checkout.
CXA_WORK="$(mktemp -d)"
CXA_OUT="$CXA_WORK/target"; mkdir -p "$CXA_OUT"
CXA_ENV="$CXA_WORK/local.env"
{ printf 'CODEX_HOME=%q\n' "$CXA_OUT"
  printf 'OBSIDIAN_VAULT_PATH=%q\n' "/tmp/test-vault"
  printf 'AGENTS_DIR=%q\n' "$REPO_ROOT/.agents"
} > "$CXA_ENV"
cxa_out="$(AI_CONFIG_LOCAL_ENV="$CXA_ENV" bash "$REPO_ROOT/scripts/install.sh" --harness codex 2>&1)"; cxa_rc=$?
assert_eq "codex install refuses a throwaway-local.env co-render into the live overlay" "1" "$cxa_rc"
assert_contains "live-overlay refusal names the guard" \
  "$cxa_out" "refusing the .agents co-render into the live overlay"
rm -rf "$CXA_WORK"

# A later Codex co-render must not create a trusted Hermes project shadow.
CXH_WORK="$(mktemp -d)"; CXH_PROJECT="$CXH_WORK/project"; CXH_CODEX="$CXH_WORK/codex"; CXH_HERMES="$CXH_WORK/hermes"; CXH_BIN="$CXH_WORK/bin"; CXH_ENV="$CXH_WORK/local.env"
make_tracked_git_fixture "$CXH_PROJECT"
mkdir -p "$CXH_PROJECT/.agents" "$CXH_CODEX" "$CXH_HERMES/skills/session-agent" "$CXH_BIN"
ln -s "$CXH_PROJECT" "$CXH_WORK/project-link"
printf 'divergent Hermes profile skill\n' > "$CXH_HERMES/skills/session-agent/SKILL.md"
printf '%s\n' '#!/usr/bin/env bash' 'case "$*" in' '*skills.project_discovery*) printf true ;;' '*skills.trusted_project_dirs*) printf "[\\\"%s\\\"]" "$CXH_TRUSTED" ;;' '*) exit 2 ;;' 'esac' > "$CXH_BIN/hermes"; chmod +x "$CXH_BIN/hermes"
printf 'CODEX_HOME=%q\nHERMES_HOME=%q\nAGENTS_DIR=%q\nAI_CONFIG_DIR=%q\nOBSIDIAN_VAULT_PATH=%q\n' "$CXH_CODEX" "$CXH_HERMES" "$CXH_PROJECT/.agents" "$CXH_PROJECT" "/tmp/test-vault" > "$CXH_ENV"
cxh_out="$(PATH="$CXH_BIN:$PATH" CXH_TRUSTED="$CXH_WORK/project-link/" AI_CONFIG_LOCAL_ENV="$CXH_ENV" bash "$REPO_ROOT/scripts/install.sh" --harness codex 2>&1)"; cxh_rc=$?
assert_eq "codex prospective Hermes shadow refuses before co-render" "1" "$cxh_rc"
assert_contains "codex prospective Hermes shadow names the guard" "$cxh_out" "Hermes project-skill shadow"
assert_exit "codex prospective Hermes shadow leaves .agents untouched" 1 -- test -e "$CXH_PROJECT/.agents/skills/session-agent"
rm -rf "$CXH_WORK"

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

# session-agent.sh (PreToolUse / Bash + native edit paths)
cx_session_agent_payload() { printf '{"transcript_path":"%s","tool_name":"apply_patch"}' "$1"; }
cx_bash_payload() {
  local command_file payload
  command_file="$(mktemp)"
  printf '%s' "$2" > "$command_file"
  payload="$(jq -n --arg transcript "$1" --rawfile command "$command_file" '{transcript_path:$transcript,tool_name:"Bash",tool_input:{command:$command}}')"
  rm -f "$command_file"
  printf '%s\n' "$payload"
}

cr1="$(cx_run_hook "$CXH/session-agent.sh" '{"tool_name":"apply_patch"}')"
assert_eq "codex session-agent: no transcript exits 0" "0" "${cr1%%|*}"
assert_eq "codex session-agent: no transcript allows"  "allow" "$(cx_classify_block "$cr1")"

cr2="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_session_agent_payload "$fix/codex-transcript-empty.jsonl")")"
assert_eq "codex session-agent: no routing exits 0" "0" "${cr2%%|*}"
assert_eq "codex session-agent: no routing blocks"  "block" "$(cx_classify_block "$cr2")"

cr3="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_session_agent_payload "$fix/codex-transcript-session-agent-ok.jsonl")")"
assert_eq "codex session-agent: invoked+Linear+Lessons allows" "allow" "$(cx_classify_block "$cr3")"

# Both declaration lines are required — `Linear gate:` without `Lessons:` blocks.
cr3b="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_session_agent_payload "$fix/codex-transcript-session-agent-no-lessons.jsonl")")"
assert_eq "codex session-agent: invoked+Linear w/o Lessons blocks" "block" "$(cx_classify_block "$cr3b")"

cr4="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_session_agent_payload "$fix/codex-transcript-session-agent-no-linear.jsonl")")"
assert_eq "codex session-agent: invoked w/o Linear blocks" "block" "$(cx_classify_block "$cr4")"

# Codex reports shell-wrapped patches as Bash. The gate must leave orient reads
# usable, including literal writer words and a literal `>` argument, while
# feeding direct mutations into the existing declaration check. This is bounded
# coverage, not a shell parser.
cr_bash_read="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_bash_payload "$fix/codex-transcript-empty.jsonl" 'rg -n "Linear gate:" README.md')")"
assert_eq "codex session-agent: Bash read bypasses the declaration gate" "allow" "$(cx_classify_block "$cr_bash_read")"
cr_bash_writer_arg="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_bash_payload "$fix/codex-transcript-empty.jsonl" 'rg -n touch README.md')")"
assert_eq "codex session-agent: Bash writer word as rg argument stays a read" "allow" "$(cx_classify_block "$cr_bash_writer_arg")"
cr_bash_printf_arg="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_bash_payload "$fix/codex-transcript-empty.jsonl" 'printf "%s" touch')")"
assert_eq "codex session-agent: Bash writer word as printf argument stays a read" "allow" "$(cx_classify_block "$cr_bash_printf_arg")"
cr_bash_pipe_read="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_bash_payload "$fix/codex-transcript-empty.jsonl" 'rg --files | rg install')")"
assert_eq "codex session-agent: Bash pipe read stays a read" "allow" "$(cx_classify_block "$cr_bash_pipe_read")"
cr_bash_literal="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_bash_payload "$fix/codex-transcript-empty.jsonl" "printf '%s\\n' '>'")")"
assert_eq "codex session-agent: Bash quoted greater-than is not treated as redirection" "allow" "$(cx_classify_block "$cr_bash_literal")"
cr_bash_escaped="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_bash_payload "$fix/codex-transcript-empty.jsonl" 'printf %s \>')")"
assert_eq "codex session-agent: Bash escaped greater-than is not treated as redirection" "allow" "$(cx_classify_block "$cr_bash_escaped")"
cr_bash_dev_null="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_bash_payload "$fix/codex-transcript-empty.jsonl" 'command -v jq >/dev/null')")"
assert_eq "codex session-agent: Bash exact /dev/null redirect stays a read" "allow" "$(cx_classify_block "$cr_bash_dev_null")"
cr_bash_fd_dev_null="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_bash_payload "$fix/codex-transcript-empty.jsonl" 'rg foo 2>/dev/null')")"
assert_eq "codex session-agent: Bash fd /dev/null redirect stays a read" "allow" "$(cx_classify_block "$cr_bash_fd_dev_null")"
cr_bash_append_dev_null="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_bash_payload "$fix/codex-transcript-empty.jsonl" 'rg foo >>/dev/null; printf ok')")"
assert_eq "codex session-agent: Bash append /dev/null redirect stays a read" "allow" "$(cx_classify_block "$cr_bash_append_dev_null")"
cr_bash_append_dev_null_fd="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_bash_payload "$fix/codex-transcript-empty.jsonl" 'rg foo >>/dev/null 2>&1')")"
assert_eq "codex session-agent: Bash append /dev/null redirect with fd duplication stays a read" "allow" "$(cx_classify_block "$cr_bash_append_dev_null_fd")"
cr_bash_null_then_lookalike="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_bash_payload "$fix/codex-transcript-empty.jsonl" 'foo >/dev/null >/dev/null2')")"
assert_eq "codex session-agent: Bash /dev/null before lookalike redirect enters the declaration gate" "block" "$(cx_classify_block "$cr_bash_null_then_lookalike")"
cr_bash_lookalike_then_null="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_bash_payload "$fix/codex-transcript-empty.jsonl" 'foo >/dev/null2; bar >/dev/null')")"
assert_eq "codex session-agent: Bash lookalike before /dev/null redirect enters the declaration gate" "block" "$(cx_classify_block "$cr_bash_lookalike_then_null")"
cr_bash_mixed_redirect="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_bash_payload "$fix/codex-transcript-empty.jsonl" 'rg foo >/dev/null > evidence.txt')")"
assert_eq "codex session-agent: Bash mixed /dev/null and file redirects enter the declaration gate" "block" "$(cx_classify_block "$cr_bash_mixed_redirect")"
cr_bash_empty="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_bash_payload "$fix/codex-transcript-empty.jsonl" '')")"
assert_eq "codex session-agent: empty Bash command passes without a parser error" "allow" "$(cx_classify_block "$cr_bash_empty")"
cr_bash_patch="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_bash_payload "$fix/codex-transcript-empty.jsonl" "apply_patch <<'PATCH'\n*** Begin Patch\nPATCH")")"
assert_eq "codex session-agent: Bash apply_patch enters the declaration gate" "block" "$(cx_classify_block "$cr_bash_patch")"
cr_bash_compact_patch="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_bash_payload "$fix/codex-transcript-empty.jsonl" $'apply_patch<<\'PATCH\'\n*** Begin Patch\nPATCH')")"
assert_eq "codex session-agent: Bash compact heredoc apply_patch enters the declaration gate" "block" "$(cx_classify_block "$cr_bash_compact_patch")"
cr_bash_path_patch="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_bash_payload "$fix/codex-transcript-empty.jsonl" '/usr/local/bin/apply_patch <<'"'"'PATCH'"'"'\n*** Begin Patch\nPATCH')")"
assert_eq "codex session-agent: absolute-path Bash apply_patch enters the declaration gate" "block" "$(cx_classify_block "$cr_bash_path_patch")"
cr_bash_path_touch="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_bash_payload "$fix/codex-transcript-empty.jsonl" '/bin/touch evidence.txt')")"
assert_eq "codex session-agent: absolute-path Bash touch enters the declaration gate" "block" "$(cx_classify_block "$cr_bash_path_touch")"
cr_bash_tee="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_bash_payload "$fix/codex-transcript-empty.jsonl" 'printf x | tee evidence.txt')")"
assert_eq "codex session-agent: Bash pipe writer enters the declaration gate" "block" "$(cx_classify_block "$cr_bash_tee")"
cr_bash_background="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_bash_payload "$fix/codex-transcript-empty.jsonl" 'printf x & touch evidence.txt')")"
assert_eq "codex session-agent: Bash background-segment writer enters the declaration gate" "block" "$(cx_classify_block "$cr_bash_background")"
cr_bash_newline="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_bash_payload "$fix/codex-transcript-empty.jsonl" $'printf x\ntouch evidence.txt')")"
assert_eq "codex session-agent: Bash newline-segment writer enters the declaration gate" "block" "$(cx_classify_block "$cr_bash_newline")"
cr_bash_redirect="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_bash_payload "$fix/codex-transcript-empty.jsonl" 'printf x > evidence.txt')")"
assert_eq "codex session-agent: Bash file redirection enters the declaration gate" "block" "$(cx_classify_block "$cr_bash_redirect")"
cx_bash_ascii_8192="$(printf 'x%.0s' {1..8192})"
cr_bash_ascii_8192="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_bash_payload "$fix/codex-transcript-empty.jsonl" "$cx_bash_ascii_8192")")"
assert_eq "codex session-agent: 8192-byte ASCII Bash command stays a read" "allow" "$(cx_classify_block "$cr_bash_ascii_8192")"
cx_bash_ascii_8193="${cx_bash_ascii_8192}x"
cr_bash_ascii_8193="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_bash_payload "$fix/codex-transcript-empty.jsonl" "$cx_bash_ascii_8193")")"
assert_eq "codex session-agent: 8193-byte ASCII Bash command enters the declaration gate" "block" "$(cx_classify_block "$cr_bash_ascii_8193")"
cx_bash_emoji_2048="$(printf '😀%.0s' {1..2048})"
cr_bash_emoji_2048="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_bash_payload "$fix/codex-transcript-empty.jsonl" "$cx_bash_emoji_2048")")"
assert_eq "codex session-agent: 2048-emoji Bash command stays a read at 8192 UTF-8 bytes" "allow" "$(cx_classify_block "$cr_bash_emoji_2048")"
cx_bash_emoji_2049="${cx_bash_emoji_2048}😀"
cr_bash_emoji_2049="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_bash_payload "$fix/codex-transcript-empty.jsonl" "$cx_bash_emoji_2049")")"
assert_eq "codex session-agent: 2049-emoji Bash command enters the declaration gate" "block" "$(cx_classify_block "$cr_bash_emoji_2049")"
cx_bash_long_command="$(printf 'x%.0s' {1..200000})"
cx_bash_long_start=$SECONDS
cr_bash_long_block="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_bash_payload "$fix/codex-transcript-empty.jsonl" "$cx_bash_long_command")")"
cx_bash_long_elapsed=$((SECONDS - cx_bash_long_start))
assert_eq "codex session-agent: oversized Bash command enters the declaration gate" "block" "$(cx_classify_block "$cr_bash_long_block")"
if ((cx_bash_long_elapsed < 10)); then _pass "codex session-agent: oversized Bash command completes under 10 seconds"
else _fail "codex session-agent: oversized Bash command completes under 10 seconds" "elapsed: ${cx_bash_long_elapsed}s"; fi
cr_bash_long_allow="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_bash_payload "$fix/codex-transcript-session-agent-ok.jsonl" "$cx_bash_long_command")")"
assert_eq "codex session-agent: declared oversized Bash command allows" "allow" "$(cx_classify_block "$cr_bash_long_allow")"
cx_bash_multibyte="$(printf '😀%.0s' {1..8191})"
cr_bash_multibyte="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_bash_payload "$fix/codex-transcript-empty.jsonl" "$cx_bash_multibyte")")"
assert_eq "codex session-agent: UTF-8-byte oversized Bash command enters the declaration gate" "block" "$(cx_classify_block "$cr_bash_multibyte")"
cr_bash_malformed="$(cx_run_hook "$CXH/session-agent.sh" '{"transcript_path":"'"$fix/codex-transcript-empty.jsonl"'","tool_name":"Bash","tool_input":{}}')"
assert_eq "codex session-agent: malformed Bash command fails closed" "block" "$(cx_classify_block "$cr_bash_malformed")"

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
assert_contains "codex no-linear fixture models the Lessons template line" "$cx_nl_fixture" 'Lessons: <matched'
assert_contains "codex no-linear fixture models the Execution template line" "$cx_nl_fixture" 'Execution: inline | delegated wave | delegated wave + panel'
# Positive path: the ok fixture's ASSISTANT declaration carries the line too, so
# cr3's allow above proves a real declaration is not rejected for carrying it.
assert_contains "codex ok fixture declares Execution in the assistant declaration" "$(cat "$fix/codex-transcript-session-agent-ok.jsonl")" 'Linear gate: PROJ-1\nExecution: inline'
assert_contains "codex no-linear fixture models a prior deny message"     "$cx_nl_fixture" 'no complete routing declaration'

# Windows-separator ran marker (panel follow-up): the bash twin must accept a
# backslash SKILL.md path in a function_call, like the PS twin's F-1 amendment.
# Raw JSONL carries four backslashes (doubly JSON-encoded single separator).
cr_bs_fix="$(mktemp -d)/codex-bs.jsonl"
cat > "$cr_bs_fix" <<'CR_BS'
{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"type skills\\\\session-agent\\\\SKILL.md\"}","call_id":"c1"}}
{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"text","text":"Routing: x\nLessons: none match\nLinear gate: PROJ-1"}]}}
CR_BS
cr7="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_session_agent_payload "$cr_bs_fix")")"
assert_eq "codex session-agent: backslash marker path allows (bash twin)" "allow" "$(cx_classify_block "$cr7")"
rm -rf "${cr_bs_fix%/codex-bs.jsonl}"

# Case sensitivity (panel follow-up): a lowercase `linear gate:` is NOT the
# declaration — bash grep is case-sensitive and the PS twins use -cmatch.
cr_lc_fix="$(mktemp -d)/codex-lc.jsonl"
cat > "$cr_lc_fix" <<'CR_LC'
{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"cat skills/session-agent/SKILL.md\"}","call_id":"c1"}}
{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"text","text":"Routing: x\nlessons: none match\nlinear gate: PROJ-1"}]}}
CR_LC
cr8="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_session_agent_payload "$cr_lc_fix")")"
assert_eq "codex session-agent: lowercase declaration still blocks" "block" "$(cx_classify_block "$cr8")"
rm -rf "${cr_lc_fix%/codex-lc.jsonl}"

# Value-less declarations do not open the gate (panel finding): a bare
# `Lessons:` / `Linear gate:` with nothing after the colon is not a disposition.
cr_ev_fix="$(mktemp -d)/codex-ev.jsonl"
cat > "$cr_ev_fix" <<'CR_EV'
{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"cat skills/session-agent/SKILL.md\"}","call_id":"c1"}}
{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"text","text":"Routing: x\nLessons:\nLinear gate:"}]}}
CR_EV
cr9="$(cx_run_hook "$CXH/session-agent.sh" "$(cx_session_agent_payload "$cr_ev_fix")")"
assert_eq "codex session-agent: value-less declaration blocks" "block" "$(cx_classify_block "$cr9")"
rm -rf "${cr_ev_fix%/codex-ev.jsonl}"

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
