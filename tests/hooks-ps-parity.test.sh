#!/usr/bin/env bash
# tests/hooks-ps-parity.test.sh
#
# Asserts that every harness hook.sh has a behavioral-equivalent.ps1 twin
# (and vice versa — no orphan.ps1 files without a bash counterpart).
#
# This closes a structural drift class: a future PR that adds a new hook
# (e.g. a new `hooks/audit.sh`) would otherwise ship cross-platform-broken
# — bash operators get the new hook, Windows operators silently don't —
# with no test catching it until someone notices the surface mismatch.
#
# Spec: every harnesses/<h>/hooks/<base>.sh MUST have a sibling
# harnesses/<h>/hooks/<base>.ps1, and vice versa.
#
# Scope notes:
# - This is a SURFACE-PRESENCE check, not a behavioral-equivalence check.
# Behavioral parity for specific user-facing strings is asserted in
# tests/closeout-file-sweep.test.sh (count-string drift / trap #8) and
# in each hook's deny / block output via integration tests.
# - install.sh (bash compiler) only copies.sh hooks; install.ps1 (PS
# compiler) copies both.sh +.ps1 sources but emits.ps1 in the
# generated settings.json hook-command shape. The.ps1 files are
# install.ps1's source inputs.
# - When a new hook lands without a twin, this test fails with a precise
# message naming the missing file — the fix is to author the twin.

# Enumerate every hook source file across all harnesses. Use a glob via
# `find` so the test scales to N harnesses without per-harness wiring.
hkps_root="$REPO_ROOT/harnesses"

# No -maxdepth cap: if a future hook ever
# lives in a subdir of hooks/ (e.g. `hooks/preset-foo/x.sh`), it must
# still have a.ps1 twin or this gate would silently miss it. Forward-
# compatible: bash compilers today use a flat glob (install.sh:337
# `harnesses/$HARNESS/hooks/*.sh`), but the parity invariant is structural,
# not depth-limited. If nested hooks land later, install.sh would need
# updating too; this test fails LOUDLY if a twin is missing regardless.
# `-path '*/hooks/*'` keeps the scope to files literally under a hooks/
# subdir of any harness — never matches hooks/ siblings.

# Collect all.sh hooks (sorted, basename without extension, prefixed by harness).
hkps_sh_pairs=()
while IFS= read -r f; do
  [ -n "$f" ] || continue
  hkps_sh_pairs+=("$f")
done < <(find "$hkps_root" -type f -name '*.sh' -path '*/hooks/*' | sort)

# Collect all.ps1 hooks similarly.
hkps_ps1_pairs=()
while IFS= read -r f; do
  [ -n "$f" ] || continue
  hkps_ps1_pairs+=("$f")
done < <(find "$hkps_root" -type f -name '*.ps1' -path '*/hooks/*' | sort)

# At least one hook should exist — empty output usually means the find
# expression broke, not legitimate empty state.
if [ "${#hkps_sh_pairs[@]}" -eq 0 ]; then
  _fail "hooks-ps-parity: no .sh hooks found under $hkps_root (expected at least one — has the layout changed?)" \
        "find returned 0 entries"
else
  _pass "hooks-ps-parity: enumerated ${#hkps_sh_pairs[@]} .sh hooks across harnesses"
fi

# Every.sh hook must have a sibling.ps1.
hkps_missing_ps1=()
for sh_path in "${hkps_sh_pairs[@]}"; do
  ps1_path="${sh_path%.sh}.ps1"
  if [ ! -f "$ps1_path" ]; then
    hkps_missing_ps1+=("${ps1_path#"$REPO_ROOT"/}")
  fi
done

if [ "${#hkps_missing_ps1[@]}" -eq 0 ]; then
  _pass "hooks-ps-parity: every .sh hook has a sibling .ps1 twin"
else
  _fail "hooks-ps-parity: .sh hooks missing .ps1 twins" \
        "$(printf '  - %s\n' "${hkps_missing_ps1[@]}")"
fi

# Inverse: every.ps1 hook must have a sibling.sh. Without this gate, a
# ps1-only hook would silently ship with no bash twin — bash operators
# would lose the surface.
hkps_missing_sh=()
for ps1_path in "${hkps_ps1_pairs[@]}"; do
  sh_path="${ps1_path%.ps1}.sh"
  if [ ! -f "$sh_path" ]; then
    hkps_missing_sh+=("${sh_path#"$REPO_ROOT"/}")
  fi
done

if [ "${#hkps_missing_sh[@]}" -eq 0 ]; then
  _pass "hooks-ps-parity: every .ps1 hook has a sibling .sh twin"
else
  _fail "hooks-ps-parity: .ps1 hooks missing .sh twins" \
        "$(printf '  - %s\n' "${hkps_missing_sh[@]}")"
fi

# --- 3. Behavioral parity: codex Windows marker recognition ---
#
# The codex PreToolUse PS hook (session-agent.ps1) looks for
# `skills/<name>/SKILL.md` in the transcript. Codex transcripts on Windows
# JSON-encode `\` as `\\`, so the raw line contains TWO backslashes between
# path segments. Without `[/\\]+` in the regex, the PS hook would silently
# fail to recognize a real invocation on the Windows lane.
#
# (The codex closeout.ps1 marker cases were removed — the closeout
# Stop hook no longer exists; closeout is manual-fire.)
#
# This assertion runs the codex session-agent.ps1 against synthetic
# transcripts using BOTH separator shapes and verifies the expected ALLOW
# outcome for each. Cheap regression guard against someone "simplifying" the
# regex back to a bash-style literal.
#
# Skips entirely if pwsh is not on PATH (Linux CI without pwsh installed
# still runs the file-presence checks above).

if command -v pwsh >/dev/null 2>&1; then
  hkps_tmpdir="$(mktemp -d)"
  hkps_codex_sa="$REPO_ROOT/harnesses/codex/hooks/session-agent.ps1"

  # --- 3a. codex session-agent.ps1 — forward-slash marker ALLOWS ----------
  hkps_trans="$hkps_tmpdir/trans-sa-fwd.txt"
  printf 'I read skills/session-agent/SKILL.md\nLinear gate: PROJ-1\n' > "$hkps_trans"
  hkps_out="$(printf '%s\n' "{\"transcript_path\":\"$hkps_trans\"}" | pwsh -NoProfile -File "$hkps_codex_sa" 2>/dev/null)"
  if [ -z "$hkps_out" ]; then
    _pass "hooks-ps-parity: codex session-agent.ps1 ALLOWS forward-slash marker"
  else
    _fail "hooks-ps-parity: codex session-agent.ps1 should ALLOW forward-slash marker + Linear gate" \
          "got non-empty output: $hkps_out"
  fi

  # --- 3b. codex session-agent.ps1 — backslash marker ALLOWS (F-1 fix) ----
  hkps_trans="$hkps_tmpdir/trans-sa-bs.txt"
  printf 'I read skills\\\\session-agent\\\\SKILL.md\nLinear gate: PROJ-1\n' > "$hkps_trans"
  hkps_out="$(printf '%s\n' "{\"transcript_path\":\"$hkps_trans\"}" | pwsh -NoProfile -File "$hkps_codex_sa" 2>/dev/null)"
  if [ -z "$hkps_out" ]; then
    _pass "hooks-ps-parity: codex session-agent.ps1 ALLOWS backslash marker"
  else
    _fail "hooks-ps-parity: codex session-agent.ps1 should ALLOW backslash marker + Linear gate" \
          "got non-empty output: $hkps_out"
  fi

  # --- 3c/3d. claude framework-surface.ps1 — compaction-aware directive ---
  # SessionStart re-fires with source=compact|resume after a compaction. On those
  # sources the directive must be the idempotent re-orient, not the kickoff. MCP +
  # freshness probes disabled for a deterministic SA-only payload; @@AI_CONFIG_DIR@@
  # stays unsubstituted so the git block is empty.
  hkps_fs="$REPO_ROOT/harnesses/claude/hooks/framework-surface.ps1"
  hkps_out="$(printf '%s' '{"source":"compact"}' | CLAUDE_SKIP_MCP_PROBE=1 CLAUDE_SKIP_FRESHNESS_CHECK=1 pwsh -NoProfile -File "$hkps_fs" 2>/dev/null)"
  case "$hkps_out" in
    *"re-orient after compacted session"*)
      _pass "hooks-ps-parity: claude framework-surface.ps1 emits re-orient directive on source=compact" ;;
    *)
      _fail "hooks-ps-parity: claude framework-surface.ps1 should emit re-orient directive on source=compact" \
            "got: $hkps_out" ;;
  esac

  hkps_out="$(printf '%s' '{"source":"startup"}' | CLAUDE_SKIP_MCP_PROBE=1 CLAUDE_SKIP_FRESHNESS_CHECK=1 pwsh -NoProfile -File "$hkps_fs" 2>/dev/null)"
  case "$hkps_out" in
    *"invoke now"*)
      case "$hkps_out" in
        *"re-orient after"*)
          _fail "hooks-ps-parity: claude framework-surface.ps1 should keep kickoff directive on source=startup" \
                "leaked re-orient text: $hkps_out" ;;
        *)
          _pass "hooks-ps-parity: claude framework-surface.ps1 keeps kickoff directive on source=startup" ;;
      esac ;;
    *)
      _fail "hooks-ps-parity: claude framework-surface.ps1 should keep kickoff directive on source=startup" \
            "got: $hkps_out" ;;
  esac

  # (hermes skill-gate behavioral parity is section 3i below — it runs BOTH twins
  # against a throwaway HHOME, so it lives outside this pwsh-only guard block.)

  # --- 3g. claude framework-surface.ps1 MCP probe — glyph-independent status parse (<TEAM>-295 F4) ---
  # Stub `claude mcp list` with a mix the fix must classify correctly: a UTF-8 ✓
  # line and a NON-✓ glyph line (the Windows OEM/ANSI mojibake stand-in) both
  # surface; Failed-to-connect, Disconnected, a multi-word "...Connected", and
  # lowercase connected are all EXCLUDED. The probe runs in a Start-Job child that
  # inherits PATH, so prepend the stub dir.
  hkps_stub="$hkps_tmpdir/bin"; mkdir -p "$hkps_stub"
  cat > "$hkps_stub/claude" <<'HKPS_CLAUDE_STUB'
#!/bin/sh
[ "$1" = "mcp" ] && [ "$2" = "list" ] || exit 0
printf '%s\n' "linear: https://x - ✓ Connected" "notebook: a b - Z Connected" "broken: c - ✗ Failed to connect" "gone: d - ✗ Disconnected" "tricky: e - x Not really Connected" "lower: f - ✓ connected"
HKPS_CLAUDE_STUB
  chmod +x "$hkps_stub/claude"
  hkps_fs2="$REPO_ROOT/harnesses/claude/hooks/framework-surface.ps1"
  hkps_out="$(printf '%s' '{"source":"startup"}' | PATH="$hkps_stub:$PATH" CLAUDE_SKIP_FRESHNESS_CHECK=1 CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE=1 pwsh -NoProfile -File "$hkps_fs2" 2>/dev/null)"
  if printf '%s' "$hkps_out" | grep -q -- '- linear' \
     && printf '%s' "$hkps_out" | grep -q -- '- notebook' \
     && ! printf '%s' "$hkps_out" | grep -qE -- '- (broken|gone|tricky|lower)$'; then
    _pass "hooks-ps-parity: claude framework-surface.ps1 MCP probe surfaces glyph-independent Connected + excludes Failed/Disconnected/multi-word/lowercase"
  else
    _fail "hooks-ps-parity: claude framework-surface.ps1 MCP probe mis-classified a status line" "got: $hkps_out"
  fi

  rm -rf "$hkps_tmpdir"
  unset hkps_tmpdir hkps_codex_sa hkps_trans hkps_out hkps_fs hkps_sg hkps_stub hkps_fs2
else
  _pass "hooks-ps-parity: skipping pwsh behavioral parity (pwsh not on PATH)"
fi

# --- 3i. hermes skill-gate.{sh,ps1} — mutation-only gate parity (<TEAM>-300) -----
# skill_manage is MUTATION-ONLY: every valid action (create/edit/patch/delete/
# write_file/remove_file) mutates a skill, and reads use the SEPARATE, ungated
# skill_view/skills_list tools the matcher never fires on. So the gate has NO
# read-only fast-path — EVERY skill_manage call BLOCKS pending a per-use operator
# approval marker that the hook CONSUMES (one approval, one call). Both twins must
# agree on (a) block-by-default for every payload shape — including the read-only
# verbs an earlier version fast-pathed, malformed input, and a non-object
# tool_input — and (b) the allow-once-then-consume marker flow. Run against a COPY
# under a throwaway HHOME so the marker write never touches the repo. (This
# replaced a 22-row read-only-allowlist table whose JSON parsing was the source of
# a clutch of bash<->PS divergences; gating every call removes that surface whole.)
hkps_sgt="$(mktemp -d)"
mkdir -p "$hkps_sgt/hooks" "$hkps_sgt/agentic-os"
cp "$REPO_ROOT/harnesses/hermes/hooks/skill-gate.sh"  "$hkps_sgt/hooks/skill-gate.sh"
cp "$REPO_ROOT/harnesses/hermes/hooks/skill-gate.ps1" "$hkps_sgt/hooks/skill-gate.ps1"
hkps_sgmk="$hkps_sgt/agentic-os/allow-skill-manage"
hkps_sg_payloads=(
  '{"tool_input":{"action":"create","name":"x"}}'
  '{"tool_input":{"action":"delete"}}'
  '{"tool_input":{"action":"list"}}'
  '{"tool_input":{"operation":"list"}}'
  '{"tool_input":{"action":"list","operation":"delete"}}'
  '{"tool_input":{}}'
  '{}'
  '{"tool_input":[{"action":"list"}]}'
  'not valid json'
)

# With NO marker every payload BLOCKS; then a marker allows exactly one call and is
# consumed. $1=engine label, $2=hook path, $3=mode (bash|pwsh).
hkps_sg_run() {
  local eng="$1" hook="$2" mode="$3" pl out
  for pl in "${hkps_sg_payloads[@]}"; do
    rm -f "$hkps_sgmk"
    if [ "$mode" = pwsh ]; then out="$(printf '%s' "$pl" | pwsh -NoProfile -File "$hook" 2>/dev/null)"
    else out="$(printf '%s' "$pl" | bash "$hook" 2>/dev/null)"; fi
    case "$out" in
      *'"decision":"block"'*) _pass "hooks-ps-parity: skill-gate.$eng gates (blocks) $pl" ;;
      *) _fail "hooks-ps-parity: skill-gate.$eng should BLOCK $pl" "got: ${out:-<allow>}" ;;
    esac
  done
  : > "$hkps_sgmk"
  if [ "$mode" = pwsh ]; then out="$(printf '%s' '{"tool_input":{"action":"create"}}' | pwsh -NoProfile -File "$hook" 2>/dev/null)"
  else out="$(printf '%s' '{"tool_input":{"action":"create"}}' | bash "$hook" 2>/dev/null)"; fi
  if [ -z "$out" ] && [ ! -f "$hkps_sgmk" ]; then
    _pass "hooks-ps-parity: skill-gate.$eng approval marker allows ONE call and is consumed"
  else
    _fail "hooks-ps-parity: skill-gate.$eng approval marker should allow+consume" \
          "out='${out:-<allow>}' marker=$([ -f "$hkps_sgmk" ] && echo present || echo consumed)"
  fi
  # A DIRECTORY at the marker path is NOT an approval — the marker must be a FILE.
  # bash `[[ -f ]]` and PS `Test-Path -PathType Leaf` both reject it; without the
  # -PathType Leaf qualifier the PS twin would treat the dir as an approval (and a
  # non-empty dir would survive the delete → standing allow). Parity regression.
  rm -f "$hkps_sgmk" 2>/dev/null; mkdir -p "$hkps_sgmk"
  if [ "$mode" = pwsh ]; then out="$(printf '%s' '{"tool_input":{"action":"create"}}' | pwsh -NoProfile -File "$hook" 2>/dev/null)"
  else out="$(printf '%s' '{"tool_input":{"action":"create"}}' | bash "$hook" 2>/dev/null)"; fi
  case "$out" in
    *'"decision":"block"'*) _pass "hooks-ps-parity: skill-gate.$eng treats a DIRECTORY at the marker path as NO approval (blocks)" ;;
    *) _fail "hooks-ps-parity: skill-gate.$eng should BLOCK when the marker path is a directory" "got: ${out:-<allow>}" ;;
  esac
  rmdir "$hkps_sgmk" 2>/dev/null
}

hkps_sg_run "sh" "$hkps_sgt/hooks/skill-gate.sh" bash
if command -v pwsh >/dev/null 2>&1; then
  hkps_sg_run "ps1" "$hkps_sgt/hooks/skill-gate.ps1" pwsh
else
  _pass "hooks-ps-parity: skipping skill-gate.ps1 behavioral checks (pwsh not on PATH)"
fi
rm -rf "$hkps_sgt"
unset hkps_sgt hkps_sgmk hkps_sg_payloads
unset -f hkps_sg_run

# --- 4. <TEAM>-295 source guards: Windows hook-twin divergence fixes -------------
# Lock the F3/F4 fixes that cannot be reproduced on a UTF-8 / pwsh-on-PATH dev
# box (the bugs only bite on Windows). Pure source-text checks — no pwsh needed,
# so they run on every lane.
#
# F3: memory-sanitize.ps1 + hermes framework-surface.ps1 must resolve the
# RUNNING pwsh via $PID, not a bare `& pwsh` that depends on PATH — absent for a
# GUI-launched process on Windows, so the governance hook false-blocks every
# memory write and the freshness probe silently never runs.
hkps_ms="$(cat "$REPO_ROOT/harnesses/hermes/hooks/memory-sanitize.ps1")"
assert_contains "hooks-ps-parity: memory-sanitize.ps1 resolves the running pwsh via \$PID" \
  "$hkps_ms" '(Get-Process -Id $PID).Path'
assert_not_contains "hooks-ps-parity: memory-sanitize.ps1 has no bare '& pwsh -NoProfile -File'" \
  "$hkps_ms" '& pwsh -NoProfile -File'
hkps_hfs="$(cat "$REPO_ROOT/harnesses/hermes/hooks/framework-surface.ps1")"
assert_contains "hooks-ps-parity: hermes framework-surface.ps1 resolves the running pwsh via \$PID" \
  "$hkps_hfs" '(Get-Process -Id $PID).Path'
assert_not_contains "hooks-ps-parity: hermes framework-surface.ps1 has no bare '& pwsh -NoProfile -File'" \
  "$hkps_hfs" '& pwsh -NoProfile -File'

# F4: claude framework-surface.ps1 MCP probe must key off the Connected status
# WORD (case-sensitive -ceq), not the ✓ glyph — on Windows native stdout is
# decoded as OEM/ANSI, so the glyph is mojibake and a glyph match drops every
# connector. The positive guard catches a revert back to the glyph regex.
hkps_cfs="$(cat "$REPO_ROOT/harnesses/claude/hooks/framework-surface.ps1")"
assert_contains "hooks-ps-parity: claude framework-surface.ps1 MCP probe parses the Connected status word (-ceq)" \
  "$hkps_cfs" "-ceq 'Connected'"

# <TEAM>-300: skill_manage is mutation-only, so the gate has NO read-only
# fast-path — it gates EVERY call. Lock that source-side so a revert that
# re-introduces a read-only fast-path fails on every lane. The robust invariant
# is "the gate does not PARSE the verb out of the payload" — any read-only
# fast-path (whether a `jq` pipe-regex like ^(list|...)$ or a JSON-array allowlist)
# must read .tool_input on bash / ConvertFrom-Json on PS to extract the verb. The
# simple gate references neither (it only ENCODES its block output via jq -nc /
# ConvertTo-Json), so the absence of the input-parse is the regression tripwire.
hkps_sgsh="$(cat "$REPO_ROOT/harnesses/hermes/hooks/skill-gate.sh")"
assert_not_contains "hooks-ps-parity: skill-gate.sh does not parse the verb (no .tool_input read)" \
  "$hkps_sgsh" '.tool_input'
assert_contains "hooks-ps-parity: skill-gate.sh consumes stdin without inspecting it (cat >/dev/null)" \
  "$hkps_sgsh" 'cat >/dev/null'
hkps_sgps="$(cat "$REPO_ROOT/harnesses/hermes/hooks/skill-gate.ps1")"
assert_not_contains "hooks-ps-parity: skill-gate.ps1 does not parse the verb (no ConvertFrom-Json)" \
  "$hkps_sgps" 'ConvertFrom-Json'
assert_contains "hooks-ps-parity: skill-gate.ps1 consumes stdin without inspecting it (ReadToEnd)" \
  "$hkps_sgps" '[Console]::In.ReadToEnd()'

# Cleanup of helper vars to avoid leakage into other test files (tests/run.sh
# dot-sources each test in the same shell).
unset hkps_root hkps_sh_pairs hkps_ps1_pairs hkps_missing_ps1 hkps_missing_sh sh_path ps1_path f hkps_ms hkps_hfs hkps_cfs hkps_sgsh hkps_sgps
