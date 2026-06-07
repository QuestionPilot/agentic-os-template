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

  rm -rf "$hkps_tmpdir"
  unset hkps_tmpdir hkps_codex_sa hkps_trans hkps_out hkps_fs
else
  _pass "hooks-ps-parity: skipping pwsh behavioral parity (pwsh not on PATH)"
fi

# Cleanup of helper vars to avoid leakage into other test files (tests/run.sh
# dot-sources each test in the same shell).
unset hkps_root hkps_sh_pairs hkps_ps1_pairs hkps_missing_ps1 hkps_missing_sh sh_path ps1_path f
