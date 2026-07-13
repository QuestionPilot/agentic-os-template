#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/parity.test.sh — cross-shell parity drift detector.
#
# Asserts behavioral parity for the four bash↔pwsh script pairs:
#
# 1. scripts/validate.{sh,ps1}
# 2. scripts/install.{sh,ps1} --build-only
# 3. scripts/check-drift.{sh,ps1} --manifest <fixture>
# 4. scripts/build-public-snapshot.{sh,ps1} (stubs — symmetric
# error-out, both NON-EXISTENT or both ERRORING)
#
# Each pair is compared by:
# - exit codes (exact match)
# - sorted PASS/FAIL/NOTE/INFO/SKIP output classes (set equality)
# - manifest hashes where applicable (install --build-only)
#
# Normalization rules (per tests/parity.README.md):
# - LF-only (strip CR for Windows CRLF parity)
# - `\` → `/` path separator normalization
# - Mask `/tmp/<rand>` + Windows `%LOCALAPPDATA%\Temp\<rand>` to <TMP>
# - Sort output classes pre-compare
#
# SKIP gracefully when pwsh is absent on bash lane (preserves count).
# The PS twin (tests/parity.test.ps1) SKIPs every assertion on the Windows
# lane (no bash available there).
#
# Sister: tests/scripts-ps-parity.test.sh runs FOCUSED per-script parity at
# the unit level; this file runs INTEGRATION-level parity across all four
# surfaces in one place. Some assertions overlap on purpose — the
# integration view catches a different class of bug (a normalization helper
# regression that all individual tests still pass on, but the cross-surface
# composition trips).
#
# Sourced by tests/run.sh — must not call exit or set -e.

PARTY_TMP="$(mktemp -d)"

_have_pwsh=0
if command -v pwsh >/dev/null 2>&1; then
  _have_pwsh=1
fi

# On a CI lane that MUST run the bash<->PS cross-check, a missing pwsh is a hard
# failure, not a silent skip (PARITY_REQUIRE_PWSH=1 set on the acceptance lanes).
_require_pwsh_or_fail "parity.test"

# ---------------------------------------------------------------------------
# Normalization helpers — duplicated from tests/scripts-ps-parity.test.sh for
# self-containment. When BOTH files need to change, change BOTH (low-leverage
# duplication; ~30 lines).
#
# Path-shape regexes are runtime-built from non-trip halves so this source
# file does NOT self-trip check-drift's machine-path scan, per
# [[feedback_self_tripping_test_source]] extension.
# ---------------------------------------------------------------------------

_PARTY_TMP_GENERIC="/tm""p/[A-Za-z0-9._/-]+"
_PARTY_TMP_PRIVATE="/private/tm""p/[A-Za-z0-9._/-]+"
_PARTY_TMP_VARFOLD="/var/folders/[A-Za-z0-9._/-]+"
# Windows %LOCALAPPDATA%\Temp shape — split the `/Use` + `rs/` segment so the
# literal substring never appears unbroken in this source.
_PARTY_TMP_WINUSER="[A-Z]:/Us""ers/[^/]+/AppData/Local/Temp/[A-Za-z0-9._/-]+"
_PARTY_TMP_WINWIND="[A-Z]:/Windows/Temp/[A-Za-z0-9._/-]+"

_norm() {
  local f="$1"
  LC_ALL=C tr -d '\r' < "$f" \
    | sed -E "
        s|\\\\|/|g
        s|${_PARTY_TMP_GENERIC}|<TMP>|g
        s|${_PARTY_TMP_PRIVATE}|<TMP>|g
        s|${_PARTY_TMP_VARFOLD}|<TMP>|g
        s|${_PARTY_TMP_WINUSER}|<TMP>|g
        s|${_PARTY_TMP_WINWIND}|<TMP>|g
      "
}

_classes() {
  /usr/bin/grep -E '^(PASS|FAIL|NOTE|INFO|SKIP) ' | LC_ALL=C sort -u
}

# ---------------------------------------------------------------------------
# Surface 1: validate.{sh,ps1} — run both on a tiny isolated fixture; assert
# exit codes match + sorted output classes match.
#
# A "tiny isolated fixture" for validate.sh would require a fully-formed
# fixture repo (with core/, capabilities/, harnesses/, etc.); building one
# from scratch in this test is high-cost and overlaps the install-render-
# stable tests. Instead we run BOTH twins on the LIVE repo and verify they
# agree. Both must exit 0 (the live repo is green); the output classes
# should match after applying the DOCUMENTED-DIVERGENCE filter below.
#
# Documented divergence (per scripts/validate.ps1:25-27 + scripts/validate.sh:635):
# bash `validate.sh` tail-invokes `scripts/check-drift.sh`, producing the
# "PASS drift and portability checks" line. PS `validate.ps1` deliberately
# does NOT call check-drift.ps1 (the operator runs it out-of-band via
# `make verify` or CI). Filter that single line before comparison so this
# parity test asserts behavioral parity on the SHARED scope (the 8 inline
# checks 1-9 listed in validate.ps1's header) without conflating it with
# the documented entrypoint divergence.
# ---------------------------------------------------------------------------

if [ -f "$REPO_ROOT/scripts/validate.sh" ] && [ -f "$REPO_ROOT/scripts/validate.ps1" ]; then
  v_bash_out="$PARTY_TMP/v-bash.out"
  bash "$REPO_ROOT/scripts/validate.sh" > "$v_bash_out" 2>&1
  v_bash_rc=$?
  assert_eq "parity validate: bash exits 0 on live repo" 0 "$v_bash_rc"

  if [ "$_have_pwsh" -eq 1 ]; then
    v_ps_out="$PARTY_TMP/v-ps.out"
    pwsh -NoProfile -File "$REPO_ROOT/scripts/validate.ps1" \
      > "$v_ps_out" 2>&1
    v_ps_rc=$?
    assert_eq "parity validate: ps exits 0 on live repo" 0 "$v_ps_rc"
    assert_eq "parity validate: exit codes match" "$v_bash_rc" "$v_ps_rc"

    # Filter the documented bash-only drift-call line from BOTH sides before
    # set-compare. Bash emits it; PS does not. Using sed `/d` removes the
    # line entirely from the bash side so the SHARED-scope classes compare
    # equal. The exact-string match is intentional — a wording change in
    # check-drift.sh would surface here as a new divergence to investigate.
    v_bash_norm="$(_norm "$v_bash_out" | _classes | sed '/^PASS drift and portability checks$/d')"
    v_ps_norm="$(_norm "$v_ps_out" | _classes | sed '/^PASS drift and portability checks$/d')"
    assert_eq "parity validate: sorted output classes match (excluding documented drift-call divergence)" \
      "$v_bash_norm" "$v_ps_norm"
  else
    _skip "parity validate: ps exits 0 on live repo" "pwsh not installed"
    _skip "parity validate: exit codes match" "pwsh not installed"
    _skip "parity validate: sorted output classes match (excluding documented drift-call divergence)" "pwsh not installed"
  fi
else
  _skip "parity validate: bash exits 0 on live repo" "validate.{sh,ps1} not both present"
  _skip "parity validate: ps exits 0 on live repo" "validate.{sh,ps1} not both present"
  _skip "parity validate: exit codes match" "validate.{sh,ps1} not both present"
  _skip "parity validate: sorted output classes match (excluding documented drift-call divergence)" "validate.{sh,ps1} not both present"
fi

# ---------------------------------------------------------------------------
# Surface 2: install.{sh,ps1} --build-only — manifest-hash determinism.
#
# Build BOTH twins into a SEPARATE tmp dir each from the same local.env
# fixture; assert the resulting.build-manifest.json hashes match. This is
# the highest-leverage cross-shell test — if hashes match, generated
# settings.json + CLAUDE.md + skill/hook artifacts are bit-identical.
#
# Per [[feedback_install_sh_in_worktree]]: every install invocation uses
# AI_CONFIG_LOCAL_ENV pointed at the fixture local.env, NOT the operator's
# real local.env. The build target is the explicit --out / -Out dir, NOT
# the operator's real CLAUDE_CONFIG_DIR.
# ---------------------------------------------------------------------------

if [ -f "$REPO_ROOT/scripts/install.sh" ] && [ -f "$REPO_ROOT/scripts/install.ps1" ]; then
  I_FIX="$PARTY_TMP/i-fix"
  I_BASH_OUT="$PARTY_TMP/i-bash-target"
  I_PS_OUT="$PARTY_TMP/i-ps-target"
  mkdir -p "$I_FIX" "$I_BASH_OUT" "$I_PS_OUT"

  # Minimal local.env — install needs CLAUDE_CONFIG_DIR + OBSIDIAN_VAULT_PATH
  # populated so template substitution doesn't fail the empty-placeholder gate.
  make_local_env "$I_FIX/local.env" "$I_BASH_OUT"

  bash_i_out="$PARTY_TMP/i-bash.out"
  AI_CONFIG_LOCAL_ENV="$I_FIX/local.env" \
    bash "$REPO_ROOT/scripts/install.sh" --harness claude --build-only \
      --out "$I_BASH_OUT" > "$bash_i_out" 2>&1
  bash_i_rc=$?
  assert_eq "parity install --build-only: bash exits 0" 0 "$bash_i_rc"

  if [ "$_have_pwsh" -eq 1 ]; then
    # PS twin builds with the SAME target inputs as the bash build (same
    # local.env CLAUDE_CONFIG_DIR value AND the same --out): the rendered
    # entrypoints embed @@CLAUDE_CONFIG_DIR@@ — resolved from the EFFECTIVE
    # target — so byte-identical platform-agnostic outputs require identical
    # target INPUTS. The builds do not collide: --build-only creates a unique
    # .install-build.* subdir per run inside --out and prints it as its last
    # line, so each manifest still lives in its own dir. The determinism
    # contract compares same-input renders.
    make_local_env "$I_FIX/local-ps.env" "$I_BASH_OUT"
    ps_i_out="$PARTY_TMP/i-ps.out"
    AI_CONFIG_LOCAL_ENV="$I_FIX/local-ps.env" \
      pwsh -NoProfile -File "$REPO_ROOT/scripts/install.ps1" \
        --harness claude --build-only --out "$I_BASH_OUT" \
      > "$ps_i_out" 2>&1
    ps_i_rc=$?
    assert_eq "parity install --build-only: ps exits 0" 0 "$ps_i_rc"
    assert_eq "parity install --build-only: exit codes match" "$bash_i_rc" "$ps_i_rc"

    # install.sh --build-only prints the build dir as last line; install.ps1
    # similarly. Read each respective.build-manifest.json from those dirs
    # and compare hashes.
    bash_build_dir="$(tail -1 "$bash_i_out")"
    ps_build_dir="$(tail -1 "$ps_i_out")"

    if [ -f "$bash_build_dir/.build-manifest.json" ] && \
       [ -f "$ps_build_dir/.build-manifest.json" ] && \
       command -v jq >/dev/null 2>&1; then
      # Compare per-file hash maps for PLATFORM-AGNOSTIC artifacts only.
      # Hook files legitimately diverge: bash side ships hooks/*.sh, PS side
      # ships hooks/*.ps1. Same for settings.json — the hook-command shape
      # inside it references.sh on bash,.ps1 on PS, so the file's content
      # SHOULD differ (that's the whole point of the per-platform harness).
      #
      # Platform-agnostic artifacts that MUST match bit-for-bit across both
      # builds: CLAUDE.md / AGENTS.md, SKILLS.md, every skill SKILL.md.
      # These have no platform-specific substitution and must produce
      # byte-identical hashes from bash twin vs PS twin — that's the
      # cross-shell determinism contract.
      bash_agnostic="$(jq -S '.generated | with_entries(select(.key | test("\\.(sh|ps1)$") | not) | select(.key != "settings.json"))' \
        < "$bash_build_dir/.build-manifest.json")"
      ps_agnostic="$(jq -S '.generated | with_entries(select(.key | test("\\.(sh|ps1)$") | not) | select(.key != "settings.json"))' \
        < "$ps_build_dir/.build-manifest.json")"
      assert_eq "parity install --build-only: platform-agnostic manifest entries bit-identical" \
        "$bash_agnostic" "$ps_agnostic"
    else
      _skip "parity install --build-only: platform-agnostic manifest entries bit-identical" \
        "manifest or jq missing (build dirs: $bash_build_dir / $ps_build_dir)"
    fi
  else
    _skip "parity install --build-only: ps exits 0" "pwsh not installed"
    _skip "parity install --build-only: exit codes match" "pwsh not installed"
    _skip "parity install --build-only: manifest .generated bit-identical" "pwsh not installed"
  fi
else
  _skip "parity install --build-only: bash exits 0" "install.{sh,ps1} not both present"
  _skip "parity install --build-only: ps exits 0" "install.{sh,ps1} not both present"
  _skip "parity install --build-only: exit codes match" "install.{sh,ps1} not both present"
  _skip "parity install --build-only: manifest .generated bit-identical" "install.{sh,ps1} not both present"
fi

# ---------------------------------------------------------------------------
# Surface 3: check-drift.{sh,ps1} --manifest on a clean fixture.
#
# Re-asserts the contract scripts-ps-parity.test.sh covers in detail; the
# integration value here is that we run it after install --build-only above
# wrote a real manifest, so this is a TRUE post-build drift check (not a
# hand-built one-file fixture).
# ---------------------------------------------------------------------------

# Note: install --build-only writes to a tmp SUBDIR inside --out and prints
# that subdir's path on its last line. `bash_build_dir` / `ps_build_dir`
# captured above are the actual manifest locations.
if [ -f "$REPO_ROOT/scripts/check-drift.sh" ] && \
   [ -f "$REPO_ROOT/scripts/check-drift.ps1" ] && \
   [ -d "${bash_build_dir:-}" ] && [ -f "$bash_build_dir/.build-manifest.json" ]; then
  cd_bash_out="$PARTY_TMP/cd-bash.out"
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$bash_build_dir" \
    > "$cd_bash_out" 2>&1
  cd_bash_rc=$?
  assert_eq "parity check-drift: bash exits 0 on post-build manifest" 0 "$cd_bash_rc"

  if [ "$_have_pwsh" -eq 1 ] && [ -d "${ps_build_dir:-}" ] && \
     [ -f "$ps_build_dir/.build-manifest.json" ]; then
    cd_ps_out="$PARTY_TMP/cd-ps.out"
    pwsh -NoProfile -File "$REPO_ROOT/scripts/check-drift.ps1" \
      --manifest "$ps_build_dir" > "$cd_ps_out" 2>&1
    cd_ps_rc=$?
    assert_eq "parity check-drift: ps exits 0 on post-build manifest" 0 "$cd_ps_rc"
    assert_eq "parity check-drift: exit codes match" "$cd_bash_rc" "$cd_ps_rc"

    cd_bash_norm="$(_norm "$cd_bash_out" | _classes)"
    cd_ps_norm="$(_norm "$cd_ps_out" | _classes)"
    assert_eq "parity check-drift: sorted output classes match" \
      "$cd_bash_norm" "$cd_ps_norm"
  else
    _skip "parity check-drift: ps exits 0 on post-build manifest" "pwsh missing or PS build skipped"
    _skip "parity check-drift: exit codes match" "pwsh missing or PS build skipped"
    _skip "parity check-drift: sorted output classes match" "pwsh missing or PS build skipped"
  fi
else
  _skip "parity check-drift: bash exits 0 on post-build manifest" "prereqs missing"
  _skip "parity check-drift: ps exits 0 on post-build manifest" "prereqs missing"
  _skip "parity check-drift: exit codes match" "prereqs missing"
  _skip "parity check-drift: sorted output classes match" "prereqs missing"
fi

# ---------------------------------------------------------------------------
# Surface 4: build-public-snapshot.{sh,ps1} — POST- implementation
# parity.
#
# Both twins ship the FULL reproducible-snapshot tooling. The integration
# assertion here drives both with `--help / -Help` (no side effects, no
# git state required) and asserts exit codes match.
# ---------------------------------------------------------------------------

if [ -f "$REPO_ROOT/scripts/build-public-snapshot.sh" ] && \
   [ -f "$REPO_ROOT/scripts/build-public-snapshot.ps1" ]; then
  if [ "$_have_pwsh" -eq 1 ]; then
    s_bash_out="$PARTY_TMP/s-bash.out"
    bash "$REPO_ROOT/scripts/build-public-snapshot.sh" --help > "$s_bash_out" 2>&1
    s_bash_rc=$?

    s_ps_out="$PARTY_TMP/s-ps.out"
    pwsh -NoProfile -File "$REPO_ROOT/scripts/build-public-snapshot.ps1" -Help \
      > "$s_ps_out" 2>&1
    s_ps_rc=$?

    assert_eq "parity snapshot-builder: --help/-Help exit codes match" \
      "$s_bash_rc" "$s_ps_rc"
  else
    _skip "parity snapshot-builder: --help/-Help exit codes match" \
      "pwsh not installed"
  fi
else
  _skip "parity snapshot-builder: --help/-Help exit codes match" \
    "scripts/build-public-snapshot.{sh,ps1} not both present"
fi

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

rm -rf "$PARTY_TMP" 2>/dev/null || true
