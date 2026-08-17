#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
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

# On a CI lane that MUST run the bash<->PS cross-check, a missing pwsh is a hard
# failure, not a silent skip (PARITY_REQUIRE_PWSH=1 set on the acceptance lanes).
# The pwsh-only behavioral sections below (3a–3i) otherwise just _pass-skip.
_require_pwsh_or_fail "hooks-ps-parity"

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
  # <TEAM>-360: the hook now parses rollout RECORDS (an assistant function_call
  # reading the SKILL.md path + an assistant-authored line-anchored gate), so
  # these synthetic transcripts are real JSONL, not bare text.
  hkps_trans="$hkps_tmpdir/trans-sa-fwd.jsonl"
  cat > "$hkps_trans" <<'HKPS_SA_FWD'
{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"cat skills/session-agent/SKILL.md\"}","call_id":"c1"}}
{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"text","text":"Routing: x\nLessons: none match\nLinear gate: PROJ-1"}]}}
HKPS_SA_FWD
  hkps_out="$(printf '%s\n' "{\"transcript_path\":\"$hkps_trans\"}" | pwsh -NoProfile -File "$hkps_codex_sa" 2>/dev/null)"
  if [ -z "$hkps_out" ]; then
    _pass "hooks-ps-parity: codex session-agent.ps1 ALLOWS forward-slash marker"
  else
    _fail "hooks-ps-parity: codex session-agent.ps1 should ALLOW forward-slash marker + Linear gate" \
          "got non-empty output: $hkps_out"
  fi

  # --- 3b. codex session-agent.ps1 — backslash marker ALLOWS (F-1 fix) ----
  # A Windows path in the doubly-encoded arguments string reaches the parsed
  # .arguments value with TWO literal backslashes per separator; the raw JSONL
  # bytes below carry four. The function_call branch's [/\\]+ class must match.
  hkps_trans="$hkps_tmpdir/trans-sa-bs.jsonl"
  cat > "$hkps_trans" <<'HKPS_SA_BS'
{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"cat skills\\\\session-agent\\\\SKILL.md\"}","call_id":"c1"}}
{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"text","text":"Routing: x\nLessons: none match\nLinear gate: PROJ-1"}]}}
HKPS_SA_BS
  hkps_out="$(printf '%s\n' "{\"transcript_path\":\"$hkps_trans\"}" | pwsh -NoProfile -File "$hkps_codex_sa" 2>/dev/null)"
  if [ -z "$hkps_out" ]; then
    _pass "hooks-ps-parity: codex session-agent.ps1 ALLOWS backslash marker"
  else
    _fail "hooks-ps-parity: codex session-agent.ps1 should ALLOW backslash marker + Linear gate" \
          "got non-empty output: $hkps_out"
  fi

  # --- 3b2. codex session-agent.ps1 — lowercase declaration DENIES ---------
  # (cross-model panel 2026-07-02): PS -match is case-insensitive by default,
  # so a plain -match would open the gate on `linear gate:` on Windows only.
  # The hook uses -cmatch; this locks the bash<->PS case-sensitivity parity.
  hkps_trans="$hkps_tmpdir/trans-sa-lc.jsonl"
  cat > "$hkps_trans" <<'HKPS_SA_LC'
{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"cat skills/session-agent/SKILL.md\"}","call_id":"c1"}}
{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"text","text":"Routing: x\nLessons: none match\nlinear gate: PROJ-1"}]}}
HKPS_SA_LC
  hkps_out="$(printf '%s\n' "{\"transcript_path\":\"$hkps_trans\"}" | pwsh -NoProfile -File "$hkps_codex_sa" 2>/dev/null)"
  case "$hkps_out" in
    *'"deny"'*|*'"block"'*)
      _pass "hooks-ps-parity: codex session-agent.ps1 DENIES lowercase declaration (case parity)" ;;
    *)
      _fail "hooks-ps-parity: codex session-agent.ps1 should DENY lowercase 'linear gate:'" \
            "got: ${hkps_out:-<empty = allow>}" ;;
  esac

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

  # --- 3e/3f. codex framework-surface.ps1 — compaction-aware directive (<TEAM>-360)
  # Same contract as the Claude twin: source=compact → idempotent re-orient;
  # source=startup → kickoff. Freshness probe disabled for a deterministic
  # SA-only payload; @@AI_CONFIG_DIR@@ stays unsubstituted so the git block is empty.
  hkps_cxfs="$REPO_ROOT/harnesses/codex/hooks/framework-surface.ps1"
  hkps_out="$(printf '%s' '{"source":"compact"}' | CLAUDE_SKIP_FRESHNESS_CHECK=1 pwsh -NoProfile -File "$hkps_cxfs" 2>/dev/null)"
  case "$hkps_out" in
    *"re-orient after compacted session"*)
      _pass "hooks-ps-parity: codex framework-surface.ps1 emits re-orient directive on source=compact" ;;
    *)
      _fail "hooks-ps-parity: codex framework-surface.ps1 should emit re-orient directive on source=compact" \
            "got: $hkps_out" ;;
  esac

  hkps_out="$(printf '%s' '{"source":"startup"}' | CLAUDE_SKIP_FRESHNESS_CHECK=1 pwsh -NoProfile -File "$hkps_cxfs" 2>/dev/null)"
  case "$hkps_out" in
    *"invoke now"*)
      case "$hkps_out" in
        *"re-orient after"*)
          _fail "hooks-ps-parity: codex framework-surface.ps1 should keep kickoff directive on source=startup" \
                "leaked re-orient text: $hkps_out" ;;
        *)
          _pass "hooks-ps-parity: codex framework-surface.ps1 keeps kickoff directive on source=startup" ;;
      esac ;;
    *)
      _fail "hooks-ps-parity: codex framework-surface.ps1 should keep kickoff directive on source=startup" \
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
  if stub_host_is_windows; then
    # pwsh on Windows cannot execute an extensionless sh stub (ShellExecute
    # pops a GUI "Select an app" dialog), and the hook's resolver rejects
    # that shape as absent. Plant a .ps1 twin the resolver accepts.
    cat > "$hkps_stub/claude.ps1" <<'HKPS_CLAUDE_STUB'
if (-not ($args.Count -ge 2 -and $args[0] -eq 'mcp' -and $args[1] -eq 'list')) { exit 0 }
"linear: https://x - ✓ Connected"
"notebook: a b - Z Connected"
"broken: c - ✗ Failed to connect"
"gone: d - ✗ Disconnected"
"tricky: e - x Not really Connected"
"lower: f - ✓ connected"
exit 0
HKPS_CLAUDE_STUB
  else
    cat > "$hkps_stub/claude" <<'HKPS_CLAUDE_STUB'
#!/bin/sh
[ "$1" = "mcp" ] && [ "$2" = "list" ] || exit 0
printf '%s\n' "linear: https://x - ✓ Connected" "notebook: a b - Z Connected" "broken: c - ✗ Failed to connect" "gone: d - ✗ Disconnected" "tricky: e - x Not really Connected" "lower: f - ✓ connected"
HKPS_CLAUDE_STUB
    chmod +x "$hkps_stub/claude"
  fi
  hkps_fs2="$REPO_ROOT/harnesses/claude/hooks/framework-surface.ps1"
  hkps_out="$(printf '%s' '{"source":"startup"}' | PATH="$hkps_stub:$PATH" CLAUDE_SKIP_FRESHNESS_CHECK=1 CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE=1 pwsh -NoProfile -File "$hkps_fs2" 2>/dev/null)"
  if printf '%s' "$hkps_out" | grep -q -- '- linear' \
     && printf '%s' "$hkps_out" | grep -q -- '- notebook' \
     && ! printf '%s' "$hkps_out" | grep -qE -- '- (broken|gone|tricky|lower)$'; then
    _pass "hooks-ps-parity: claude framework-surface.ps1 MCP probe surfaces glyph-independent Connected + excludes Failed/Disconnected/multi-word/lowercase"
  else
    _fail "hooks-ps-parity: claude framework-surface.ps1 MCP probe mis-classified a status line" "got: $hkps_out"
  fi

  # --- 3h. claude session-agent.ps1 — gate-marker channel (<TEAM>-365) -----
  # The desktop/SDK variant does not persist assistant text into the
  # transcript, so the PS twin (like the bash hook) must accept the R5
  # declaration from the per-session marker file at <install>/agentic-os/
  # gate-<session_id> — and never let the marker substitute for the Skill
  # invocation itself. Run against a COPY in a throwaway install layout so
  # marker writes and the stale-reap never touch the repo.
  hkps_sa365="$hkps_tmpdir/install-365"
  mkdir -p "$hkps_sa365/hooks"
  cp "$REPO_ROOT/harnesses/claude/hooks/session-agent.ps1" "$hkps_sa365/hooks/"
  hkps_sa365_fix="$REPO_ROOT/tests/fixtures/transcript-desktop-session-agent.jsonl"
  hkps_sa365_sid="ps-dt-0000"
  hkps_sa365_gate="$hkps_sa365/agentic-os/gate-$hkps_sa365_sid"

  # no marker → DENY, and the deny must name the recovery path.
  hkps_out="$(printf '{"transcript_path":"%s","session_id":"%s","tool_name":"Edit","tool_input":null}' "$hkps_sa365_fix" "$hkps_sa365_sid" | pwsh -NoProfile -File "$hkps_sa365/hooks/session-agent.ps1" 2>/dev/null)"
  case "$hkps_out" in
    *'"permissionDecision":"deny"'*"gate-$hkps_sa365_sid"*)
      _pass "hooks-ps-parity: claude session-agent.ps1 DENIES desktop transcript w/o marker, naming the marker path" ;;
    *)
      _fail "hooks-ps-parity: claude session-agent.ps1 should DENY w/o marker and name the marker path"             "got: ${hkps_out:-<empty = allow>}" ;;
  esac

  # the marker Write itself (exact path + line-anchored declaration) → ALLOW.
  hkps_wpayload="$(jq -nc --arg t "$hkps_sa365_fix" --arg sid "$hkps_sa365_sid" --arg p "$hkps_sa365_gate" \
    '{transcript_path: $t, session_id: $sid, tool_name: "Write", tool_input: {file_path: $p, content: "Routing: fix\nLessons: none match\nLinear gate: none — single-step\n"}}')"
  hkps_out="$(printf '%s' "$hkps_wpayload" | pwsh -NoProfile -File "$hkps_sa365/hooks/session-agent.ps1" 2>/dev/null)"
  if [ -z "$hkps_out" ]; then
    _pass "hooks-ps-parity: claude session-agent.ps1 ALLOWS the marker write through pre-gate"
  else
    _fail "hooks-ps-parity: claude session-agent.ps1 should ALLOW the marker write" "got: $hkps_out"
  fi

  # marker on disk with the declaration → ALLOW subsequent edits.
  mkdir -p "$hkps_sa365/agentic-os"
  printf 'Routing: fix\nLessons: none match\nLinear gate: none — single-step\n' > "$hkps_sa365_gate"
  hkps_out="$(printf '{"transcript_path":"%s","session_id":"%s","tool_name":"Edit","tool_input":null}' "$hkps_sa365_fix" "$hkps_sa365_sid" | pwsh -NoProfile -File "$hkps_sa365/hooks/session-agent.ps1" 2>/dev/null)"
  if [ -z "$hkps_out" ]; then
    _pass "hooks-ps-parity: claude session-agent.ps1 ALLOWS once marker is on disk"
  else
    _fail "hooks-ps-parity: claude session-agent.ps1 should ALLOW with marker on disk" "got: $hkps_out"
  fi

  # marker NEVER substitutes for the Skill invocation (empty transcript) → DENY.
  hkps_out="$(printf '{"transcript_path":"%s","session_id":"%s","tool_name":"Edit","tool_input":null}' "$REPO_ROOT/tests/fixtures/transcript-empty.jsonl" "$hkps_sa365_sid" | pwsh -NoProfile -File "$hkps_sa365/hooks/session-agent.ps1" 2>/dev/null)"
  case "$hkps_out" in
    *'"permissionDecision":"deny"'*)
      _pass "hooks-ps-parity: claude session-agent.ps1 DENIES marker w/o skill invocation" ;;
    *)
      _fail "hooks-ps-parity: claude session-agent.ps1 should DENY marker w/o skill invocation"             "got: ${hkps_out:-<empty = allow>}" ;;
  esac

  # --- 3h2. hermes session-agent.ps1 — gate-file channel (panel findings) ---
  # The Hermes ps1 gate-file channel was previously untested end-to-end, and its
  # `-like` matching was case-INsensitive + substring (a Windows-only false-allow
  # vs the bash twin). These rows pin the tightened contract: line-anchored,
  # case-sensitive, non-empty values, BOTH lines.
  hkps_hm="$hkps_tmpdir/hermes-home"
  mkdir -p "$hkps_hm/hooks"
  cp "$REPO_ROOT/harnesses/hermes/hooks/session-agent.ps1" "$hkps_hm/hooks/"
  hkps_hm_sid="ps-hm-0000"
  hkps_hm_gate="$hkps_hm/agentic-os/gate-$hkps_hm_sid"
  hkps_hm_payload() { # <content-json-escaped-string> -> a write_file event to the gate path
    printf '{"hook_event_name":"pre_tool_call","tool_name":"write_file","tool_input":{"path":"%s","content":"%s"},"session_id":"%s","cwd":"/tmp"}' \
      "$hkps_hm_gate" "$1" "$hkps_hm_sid"
  }
  # (a) marker write with both proper lines → ALLOW (silent).
  hkps_out="$(hkps_hm_payload 'Routing: x\nLessons: none match\nLinear gate: none — single-step' | pwsh -NoProfile -File "$hkps_hm/hooks/session-agent.ps1" 2>/dev/null)"
  if [ -z "$hkps_out" ]; then
    _pass "hooks-ps-parity: hermes session-agent.ps1 ALLOWS the full-declaration gate write"
  else
    _fail "hooks-ps-parity: hermes session-agent.ps1 should ALLOW the full-declaration gate write" "got: $hkps_out"
  fi
  # (b) marker write with only the Linear gate line → BLOCK.
  hkps_out="$(hkps_hm_payload 'Routing: x\nLinear gate: none — single-step' | pwsh -NoProfile -File "$hkps_hm/hooks/session-agent.ps1" 2>/dev/null)"
  case "$hkps_out" in
    *'"decision":"block"'*) _pass "hooks-ps-parity: hermes session-agent.ps1 BLOCKS a Lessons-less gate write" ;;
    *) _fail "hooks-ps-parity: hermes session-agent.ps1 should BLOCK a Lessons-less gate write" "got: ${hkps_out:-<empty = allow>}" ;;
  esac
  # (c) marker ON DISK, lowercase both lines → BLOCK (case parity with bash twin).
  mkdir -p "$hkps_hm/agentic-os"
  printf 'Routing: x\nlessons: none match\nlinear gate: none — single-step\n' > "$hkps_hm_gate"
  hkps_out="$(printf '{"hook_event_name":"pre_tool_call","tool_name":"write_file","tool_input":{"path":"/tmp/x.txt","content":"hi"},"session_id":"%s","cwd":"/tmp"}' "$hkps_hm_sid" | pwsh -NoProfile -File "$hkps_hm/hooks/session-agent.ps1" 2>/dev/null)"
  case "$hkps_out" in
    *'"decision":"block"'*) _pass "hooks-ps-parity: hermes session-agent.ps1 BLOCKS a lowercase on-disk marker (case parity)" ;;
    *) _fail "hooks-ps-parity: hermes session-agent.ps1 should BLOCK a lowercase on-disk marker" "got: ${hkps_out:-<empty = allow>}" ;;
  esac
  # (d) asymmetric case: proper Linear gate + lowercase lessons → BLOCK
  #     (pins the Lessons pattern's case-sensitivity independently).
  printf 'Routing: x\nlessons: none match\nLinear gate: none — single-step\n' > "$hkps_hm_gate"
  hkps_out="$(printf '{"hook_event_name":"pre_tool_call","tool_name":"write_file","tool_input":{"path":"/tmp/x.txt","content":"hi"},"session_id":"%s","cwd":"/tmp"}' "$hkps_hm_sid" | pwsh -NoProfile -File "$hkps_hm/hooks/session-agent.ps1" 2>/dev/null)"
  case "$hkps_out" in
    *'"decision":"block"'*) _pass "hooks-ps-parity: hermes session-agent.ps1 BLOCKS lowercase-lessons asymmetric marker" ;;
    *) _fail "hooks-ps-parity: hermes session-agent.ps1 should BLOCK lowercase-lessons asymmetric marker" "got: ${hkps_out:-<empty = allow>}" ;;
  esac
  # (e) marker on disk with both proper lines → ALLOW subsequent writes.
  printf 'Routing: x\nLessons: none match\nLinear gate: none — single-step\n' > "$hkps_hm_gate"
  hkps_out="$(printf '{"hook_event_name":"pre_tool_call","tool_name":"write_file","tool_input":{"path":"/tmp/x.txt","content":"hi"},"session_id":"%s","cwd":"/tmp"}' "$hkps_hm_sid" | pwsh -NoProfile -File "$hkps_hm/hooks/session-agent.ps1" 2>/dev/null)"
  if [ -z "$hkps_out" ]; then
    _pass "hooks-ps-parity: hermes session-agent.ps1 ALLOWS once the full marker is on disk"
  else
    _fail "hooks-ps-parity: hermes session-agent.ps1 should ALLOW with the full marker on disk" "got: $hkps_out"
  fi

  rm -rf "$hkps_tmpdir"
  unset hkps_tmpdir hkps_codex_sa hkps_trans hkps_out hkps_fs hkps_sg hkps_stub hkps_fs2 hkps_cxfs hkps_sa365 hkps_sa365_fix hkps_sa365_sid hkps_sa365_gate hkps_wpayload hkps_hm hkps_hm_sid hkps_hm_gate
  unset -f hkps_hm_payload
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

# --- 5. <TEAM>-364 distillation-lag nudge — claude framework-surface.ps1 ----
# Mirrors the bash-side scenarios appended to tests/hooks-behavior.test.sh:
# lapse -> header + note name; distilled -> nudge absent; kill switch ->
# nudge absent; unresolvable vault -> silent (checker exit 2, fail-open).
# The repo source hook still carries the @@AI_CONFIG_DIR@@ placeholder (this
# file runs sources, not a build), so run a COPY with the placeholder
# substituted to REPO_ROOT — the same substitution install performs — so the
# block can find scripts/check-distillation-completeness.ps1. The other
# probe blocks are disabled via their kill switches for a deterministic
# payload. Skips when pwsh is absent (same convention as section 3).
if command -v pwsh >/dev/null 2>&1; then
  hkdn_tmp="$(mktemp -d)"
  mkdir -p "$hkdn_tmp/hooks" "$hkdn_tmp/cfg/projects/x/memory" "$hkdn_tmp/vault/04-Lessons"
  sed "s|@@AI_CONFIG_DIR@@|$REPO_ROOT|g" "$REPO_ROOT/harnesses/claude/hooks/framework-surface.ps1" \
    > "$hkdn_tmp/hooks/framework-surface.ps1"
  # In-scope note: kebab slug + frontmatter `metadata:`-nested `type: feedback`
  # (the shape the checker's frontmatter scan recognizes).
  cat > "$hkdn_tmp/cfg/projects/x/memory/feedback-test-lapse-note.md" <<'HKDN_NOTE'
---
title: test lapse note
metadata:
  type: feedback
---
A feedback note that has not been distilled into 04-Lessons.
HKDN_NOTE
  printf '# Memory index\n' > "$hkdn_tmp/cfg/projects/x/memory/MEMORY.md"
  printf '# Unrelated lesson\n' > "$hkdn_tmp/vault/04-Lessons/unrelated.md"
  hkdn_env=(CLAUDE_SKIP_MCP_PROBE=1 CLAUDE_SKIP_FRESHNESS_CHECK=1 CLAUDE_SKIP_LOCAL_HOOK_CHECK=1 CLAUDE_SKIP_SESSION_AGENT_DIRECTIVE=1)

  # lapse -> header names the count, list names the note.
  hkdn_out="$(printf '%s' '{"source":"startup"}' | env "${hkdn_env[@]}" \
    CLAUDE_CONFIG_DIR="$hkdn_tmp/cfg" OBSIDIAN_VAULT_PATH="$hkdn_tmp/vault" \
    pwsh -NoProfile -File "$hkdn_tmp/hooks/framework-surface.ps1" 2>/dev/null)"
  hkdn_rc=$?
  if [ "$hkdn_rc" -ne 0 ]; then
    _fail "hooks-ps-parity: claude framework-surface.ps1 distillation lapse exits 0" "exit $hkdn_rc"
  else
    _pass "hooks-ps-parity: claude framework-surface.ps1 distillation lapse exits 0"
  fi
  case "$hkdn_out" in
    *"Distillation lag — 1 feedback/decision note(s) not yet distilled"*)
      case "$hkdn_out" in
        *"feedback-test-lapse-note"*)
          _pass "hooks-ps-parity: claude framework-surface.ps1 surfaces the distillation lapse + note name" ;;
        *)
          _fail "hooks-ps-parity: claude framework-surface.ps1 lapse block should name the note" "got: $hkdn_out" ;;
      esac ;;
    *)
      _fail "hooks-ps-parity: claude framework-surface.ps1 should surface the distillation lapse" "got: $hkdn_out" ;;
  esac

  # distilled (name recorded in a lessons note) -> nudge absent.
  printf '# Thematic lesson\n\n## Source Notes\n\n- feedback-test-lapse-note\n' > "$hkdn_tmp/vault/04-Lessons/thematic-lesson.md"
  hkdn_out="$(printf '%s' '{"source":"startup"}' | env "${hkdn_env[@]}" \
    CLAUDE_CONFIG_DIR="$hkdn_tmp/cfg" OBSIDIAN_VAULT_PATH="$hkdn_tmp/vault" \
    pwsh -NoProfile -File "$hkdn_tmp/hooks/framework-surface.ps1" 2>/dev/null)"
  case "$hkdn_out" in
    *"Distillation lag"*)
      _fail "hooks-ps-parity: claude framework-surface.ps1 distilled note should drop the nudge" "got: $hkdn_out" ;;
    *)
      _pass "hooks-ps-parity: claude framework-surface.ps1 distilled note drops the nudge" ;;
  esac

  # kill switch (lapse restored) -> nudge absent.
  rm -f "$hkdn_tmp/vault/04-Lessons/thematic-lesson.md"
  hkdn_out="$(printf '%s' '{"source":"startup"}' | env "${hkdn_env[@]}" CLAUDE_SKIP_DISTILLATION_NUDGE=1 \
    CLAUDE_CONFIG_DIR="$hkdn_tmp/cfg" OBSIDIAN_VAULT_PATH="$hkdn_tmp/vault" \
    pwsh -NoProfile -File "$hkdn_tmp/hooks/framework-surface.ps1" 2>/dev/null)"
  case "$hkdn_out" in
    *"Distillation lag"*)
      _fail "hooks-ps-parity: claude framework-surface.ps1 CLAUDE_SKIP_DISTILLATION_NUDGE=1 should drop the nudge" "got: $hkdn_out" ;;
    *)
      _pass "hooks-ps-parity: claude framework-surface.ps1 CLAUDE_SKIP_DISTILLATION_NUDGE=1 drops the nudge" ;;
  esac

  # unresolvable vault (nonexistent dir) -> checker exit 2 -> fail-open silent.
  hkdn_out="$(printf '%s' '{"source":"startup"}' | env "${hkdn_env[@]}" \
    CLAUDE_CONFIG_DIR="$hkdn_tmp/cfg" OBSIDIAN_VAULT_PATH="$hkdn_tmp/nope" \
    pwsh -NoProfile -File "$hkdn_tmp/hooks/framework-surface.ps1" 2>/dev/null)"
  hkdn_rc=$?
  if [ "$hkdn_rc" -eq 0 ]; then
    _pass "hooks-ps-parity: claude framework-surface.ps1 unresolvable vault exits 0"
  else
    _fail "hooks-ps-parity: claude framework-surface.ps1 unresolvable vault exits 0" "exit $hkdn_rc"
  fi
  case "$hkdn_out" in
    *"Distillation lag"*)
      _fail "hooks-ps-parity: claude framework-surface.ps1 unresolvable vault should stay silent" "got: $hkdn_out" ;;
    *)
      _pass "hooks-ps-parity: claude framework-surface.ps1 unresolvable vault stays silent" ;;
  esac

  rm -rf "$hkdn_tmp"
  unset hkdn_tmp hkdn_env hkdn_out hkdn_rc
else
  _pass "hooks-ps-parity: skipping distillation-nudge PS behavioral checks (pwsh not on PATH)"
fi

# Cleanup of helper vars to avoid leakage into other test files (tests/run.sh
# dot-sources each test in the same shell).
unset hkps_root hkps_sh_pairs hkps_ps1_pairs hkps_missing_ps1 hkps_missing_sh sh_path ps1_path f hkps_ms hkps_hfs hkps_cfs hkps_sgsh hkps_sgps
