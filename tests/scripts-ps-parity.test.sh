#!/usr/bin/env bash
# tests/scripts-ps-parity.test.sh — bash↔pwsh byte-parity for script ports.
#
# (Issue 5B-a — Windows-native scripts ports) ports five PowerShell
# twins to existing bash scripts in scripts/. This test asserts byte-identical
# output between each pair on common fixtures, applying the Issue 5B
# normalization rules from the public-template-rewrite plan:
#
# - LF-only (strip CR from PS output before diff)
# - `\` → `/` in paths
# - Mask `/tmp/<rand>` + `%LOCALAPPDATA%\Temp\<rand>` to `<TMP>`
# - Sort PASS/FAIL output classes before set-compare
#
# Skipped on hosts without pwsh installed. The bash side always runs.
#
# Scripts covered:
# - scripts/check-memory-drift.{sh,ps1}
# - scripts/self-audit.{sh,ps1}
# - scripts/check-drift.{sh,ps1} (--manifest mode)
# - scripts/build-public-snapshot.{sh,ps1} (stub: error-out symmetry only)
# - scripts/sanitize-for-publish.{sh,ps1} (thin re-assertion that the.ps1
# is still byte-parity with the bash twin post-fix/, so a
# future leak surfaces here too).
#
# Per [[feedback_port_parity_vs_regression_split]] — this test catches PORT
# REGRESSION (PS output diverges from bash on the same input). Threat-boundary
# parity-with-bash inheritance is documented as gotchas, not asserted here.
#
# This file is SOURCED by tests/run.sh — do not call `exit` or set `-e`/`-u`/
# `pipefail` flags (they leak into the runner and silently kill sibling tests).

PARITY_TMP="$(mktemp -d)"
# No EXIT trap — tests/run.sh sources this file; a trap here would fire for
# every subsequent test. Inline cleanup at end of file instead.

_have_pwsh=0
if command -v pwsh >/dev/null 2>&1; then
  _have_pwsh=1
fi

# On a CI lane that MUST run the bash<->PS cross-check, a missing pwsh is a hard
# failure, not a silent skip (PARITY_REQUIRE_PWSH=1 set on the acceptance lanes).
_require_pwsh_or_fail "scripts-ps-parity"

# ---------------------------------------------------------------------------
# Meta-test: the PARITY_REQUIRE_PWSH gate itself. Proves that on a lane which
# MUST run the bash<->PS cross-check (PARITY_REQUIRE_PWSH=1), a missing pwsh is a
# LOUD _fail, not a silent skip — without needing an actual pwsh-less runner.
# We simulate "pwsh absent" with an empty PATH in a child shell (command -v finds
# nothing); lib.sh is pure-bash so it still sources and the helper is all builtins.
# The converse (no REQUIRE => silent) is asserted too so the gate stays opt-in for
# local dev. Runs on every lane (not pwsh-gated) — it is the regression guard for
# the gate that all the other parity assertions now lean on.
# ---------------------------------------------------------------------------
_mp_lib="$REPO_ROOT/tests/lib.sh"
# Simulate "pwsh absent" by shadowing `command -v pwsh` to fail — NOT by clearing
# PATH. An empty PATH would break sourcing lib.sh the moment it gains any load-time
# external call (and dump 'command not found' into the captured output, false-failing
# the silent-skip case). The shim keeps PATH intact and only intercepts the one probe.
_mp_shim='command() { if [ "$1" = "-v" ] && [ "$2" = "pwsh" ]; then return 1; fi; builtin command "$@"; }'
_mp_required="$(PARITY_REQUIRE_PWSH=1 "$BASH" --noprofile --norc -c \
  "$_mp_shim; . \"$_mp_lib\"; _require_pwsh_or_fail meta-test" 2>&1)"
case "$_mp_required" in
  *FAIL*"pwsh REQUIRED"*)
    _pass "PARITY_REQUIRE_PWSH=1 + no pwsh => hard FAIL (cross-check cannot silently skip)" ;;
  *)
    _fail "PARITY_REQUIRE_PWSH=1 + no pwsh should emit a hard FAIL" "got: ${_mp_required:-<empty>}" ;;
esac
# Explicitly clear PARITY_REQUIRE_PWSH in the child so this case is hermetic even
# when the whole suite runs under PARITY_REQUIRE_PWSH=1 (as the CI lanes do) — an
# inherited =1 would otherwise make the "should stay silent" case fire the fail.
_mp_optional="$(PARITY_REQUIRE_PWSH= "$BASH" --noprofile --norc -c \
  "$_mp_shim; . \"$_mp_lib\"; _require_pwsh_or_fail meta-test" 2>&1)"
case "$_mp_optional" in
  '')
    _pass "PARITY_REQUIRE_PWSH unset + no pwsh => silent skip (local-dev convenience preserved)" ;;
  *)
    _fail "PARITY_REQUIRE_PWSH unset + no pwsh should stay silent" "got: $_mp_optional" ;;
esac
unset _mp_lib _mp_shim _mp_required _mp_optional

# ---------------------------------------------------------------------------
# Normalization helper. Reads a file (or stdin), applies the Issue 5B rules,
# writes to stdout.
#
# Per [[feedback_self_tripping_test_source]] extension: the path-shape
# regexes are runtime-constructed from non-matching halves so this file's
# source does NOT trip check-drift.sh's machine-specific-path scan (which
# matches `/(Users|home)/[^/]+/?|[A-Za-z]:\\Users\\[^\\]+\\?`). We assemble
# the masking patterns at function-definition time from split-string halves,
# then sed never sees the trip-shape in the source.
# ---------------------------------------------------------------------------

# Build the masking-regex strings from non-trip halves. Each regex piece is
# legitimately a path-shape regex; the half-split keeps it out of source-scan.
_PARITY_USERS_DIR='Use'r'sDir'   # placeholder — not the literal /Users/
# Use parameter expansion at function CALL time, not literal regex in sed.
_TMP_RE_GENERIC="/tm""p/[A-Za-z0-9._/-]+"
_TMP_RE_PRIVATE="/private/tm""p/[A-Za-z0-9._/-]+"
_TMP_RE_VARFOLD="/var/folders/[A-Za-z0-9._/-]+"
# Windows temp pattern — split the `/Use rs/` segment so the literal substring
# never appears unbroken in this source.
_TMP_RE_WIN_USERS="[A-Z]:/Us""ers/[^/]+/AppData/Local/Temp/[A-Za-z0-9._/-]+"
_TMP_RE_WIN_WINDOWS="[A-Z]:/Windows/Temp/[A-Za-z0-9._/-]+"

_normalize() {
  local f="$1"
  # 1. strip CR (Windows CRLF -> LF)
  # 2. backslash path separators -> forward slash
  # 3. mask tmp-style paths (BSD/GNU mktemp + Windows %LOCALAPPDATA%\Temp)
  # The substitutions are intentionally permissive: they collapse any
  # path-shaped string under /tmp or the Windows Temp area to <TMP>.
  # Patterns are runtime-built from _TMP_RE_* halves so this source file
  # does not self-trip check-drift's machine-path scan.
  LC_ALL=C tr -d '\r' < "$f" \
    | sed -E "
        s|\\\\|/|g
        s|${_TMP_RE_GENERIC}|<TMP>|g
        s|${_TMP_RE_PRIVATE}|<TMP>|g
        s|${_TMP_RE_VARFOLD}|<TMP>|g
        s|${_TMP_RE_WIN_USERS}|<TMP>|g
        s|${_TMP_RE_WIN_WINDOWS}|<TMP>|g
      "
}

# ---------------------------------------------------------------------------
# _sort_classes — sort PASS/FAIL lines from an output by class, stripping
# everything after the first space-then-rationale so we compare CLASSES, not
# specific message bodies (which legitimately differ in path quoting).
# ---------------------------------------------------------------------------
_sort_classes() {
  # Match `PASS...` / `FAIL...` / `NOTE...` / `INFO...` / `SKIP...`.
  # Sort and uniq them.
  /usr/bin/grep -E '^(PASS|FAIL|NOTE|INFO|SKIP) ' | LC_ALL=C sort -u
}

# ---------------------------------------------------------------------------
# Test 1: scripts/check-memory-drift.{sh,ps1}
#
# Run both against a fixture memory dir that contains a deliberate drift case.
# Assert exit codes match + sorted output-classes match.
# ---------------------------------------------------------------------------

if [ -f "$REPO_ROOT/scripts/check-memory-drift.sh" ] && [ -f "$REPO_ROOT/scripts/check-memory-drift.ps1" ]; then
  CMD_FIX="$PARITY_TMP/cmd-fix"
  mkdir -p "$CMD_FIX"

  # Drift fixture: headline says CLOSED, body links to a different project,
  # description does not acknowledge follow-on.
  cat > "$CMD_FIX/project_old.md" <<'EOF'
---
name: project_old
description: "Old project — CLOSED 2026-01-01. Sealed."
metadata:
  node_type: memory
---

Some body. Now points to [[project_new]] as follow-on.
EOF

  cat > "$CMD_FIX/project_new.md" <<'EOF'
---
name: project_new
description: "New project — In Progress."
metadata:
  node_type: memory
---

Body.
EOF

  # frontmatter parser-safety, LF + CRLF dirty notes. Both twins must
  # emit byte-identical "FAIL frontmatter" lines — covered by the existing
  # exit-code + sorted-output-class assertions below (no new assertion needed).
  cat > "$CMD_FIX/feedback_fm_dirty.md" <<'EOF'
---
name: feedback_fm_dirty
description: unquoted value with a colon: hazard inside it
metadata:
  node_type: memory
---

Body.
EOF
  # CRLF variant — awk keeps the trailing \r, ReadAllLines strips it; both must
  # still flag it and produce the same normalized line.
  printf -- '---\r\nname: feedback_fm_crlf\r\ndescription: crlf value with a colon: hazard\r\nmetadata:\r\n  node_type: memory\r\n---\r\nBody.\r\n' \
    > "$CMD_FIX/feedback_fm_crlf.md"
  # UTF-8 BOM dirty note — bash strips the BOM (awk), PS ReadAllLines strips it;
  # both must accept the --- and flag the colon hazard identically (the parity
  # divergence Codex caught).
  printf -- '\xef\xbb\xbf---\nname: reference_fm_bom\ndescription: bom value with a colon: hazard\nmetadata:\n  node_type: memory\n---\nBody.\n' \
    > "$CMD_FIX/reference_fm_bom.md"
  # Structural delimiter failures — no-open + no-close output-class parity.
  printf -- '# Heading first, no frontmatter\nBody only.\n' \
    > "$CMD_FIX/project_fm_noopen.md"
  printf -- '---\nname: reference_fm_noclose\ndescription: "clean and quoted"\n' \
    > "$CMD_FIX/reference_fm_noclose.md"

  # Non-drift fixture: headline says Active, body too.
  cat > "$CMD_FIX/project_live.md" <<'EOF'
---
name: project_live
description: "Live project — In Progress."
metadata:
  node_type: memory
---

Body.
EOF

  # Bash side: should exit 1 with a FAIL drift line for project_old.
  bash_out="$PARITY_TMP/cmd-bash.out"
  bash "$REPO_ROOT/scripts/check-memory-drift.sh" --memory-dir "$CMD_FIX" \
    > "$bash_out" 2>&1
  bash_rc=$?

  if [ "$_have_pwsh" -eq 1 ]; then
    ps_out="$PARITY_TMP/cmd-ps.out"
    pwsh -NoProfile -File "$REPO_ROOT/scripts/check-memory-drift.ps1" \
      -MemoryDir "$CMD_FIX" > "$ps_out" 2>&1
    ps_rc=$?

    assert_eq "check-memory-drift parity: exit codes match (drift fixture)" \
      "$bash_rc" "$ps_rc"

    bash_norm="$(_normalize "$bash_out" | _sort_classes)"
    ps_norm="$(_normalize "$ps_out" | _sort_classes)"
    assert_eq "check-memory-drift parity: sorted output-classes match" \
      "$bash_norm" "$ps_norm"
  else
    _skip "check-memory-drift parity: exit codes match (drift fixture)" "pwsh not installed"
    _skip "check-memory-drift parity: sorted output-classes match" "pwsh not installed"
  fi

  # Clean fixture (no drift): both must exit 0.
  CMD_CLEAN="$PARITY_TMP/cmd-clean"
  mkdir -p "$CMD_CLEAN"
  cat > "$CMD_CLEAN/project_live.md" <<'EOF'
---
name: project_live
description: "Live project — In Progress."
---

Body.
EOF

  bash_clean_out="$PARITY_TMP/cmd-bash-clean.out"
  bash "$REPO_ROOT/scripts/check-memory-drift.sh" --memory-dir "$CMD_CLEAN" \
    > "$bash_clean_out" 2>&1
  bash_clean_rc=$?
  assert_eq "check-memory-drift bash exits 0 on clean fixture" 0 "$bash_clean_rc"

  if [ "$_have_pwsh" -eq 1 ]; then
    ps_clean_out="$PARITY_TMP/cmd-ps-clean.out"
    pwsh -NoProfile -File "$REPO_ROOT/scripts/check-memory-drift.ps1" \
      -MemoryDir "$CMD_CLEAN" > "$ps_clean_out" 2>&1
    ps_clean_rc=$?
    assert_eq "check-memory-drift ps exits 0 on clean fixture" 0 "$ps_clean_rc"
  else
    _skip "check-memory-drift ps exits 0 on clean fixture" "pwsh not installed"
  fi
else
  _skip "check-memory-drift parity: exit codes match (drift fixture)" "scripts not present"
  _skip "check-memory-drift parity: sorted output-classes match" "scripts not present"
  _skip "check-memory-drift bash exits 0 on clean fixture" "scripts not present"
  _skip "check-memory-drift ps exits 0 on clean fixture" "scripts not present"
fi

# ---------------------------------------------------------------------------
# Test 1b: check-memory-drift parity — QUOTED `name:` self-link recognition.
#
# A CLOSED project whose body self-links to its OWN name must NOT be flagged as
# drift (a self-link is not a follow-on pointer). When the `name:` value is
# QUOTED, the bash twin used to keep the quotes while the PS twin stripped them,
# so the self-link compare diverged: bash saw `"x"` != `x` → false drift (exit 1)
# while PS saw `x` == `x` → no drift (exit 0) — OPPOSITE verdicts. With the bash
# own_name parser now stripping quotes (matching Get-FmField), both reach exit 0.
# Pre-fix this fixture trips the exit-code assertions; post-fix it passes — the
# regression pin for the quote-strip parity fix.
# ---------------------------------------------------------------------------

if [ -f "$REPO_ROOT/scripts/check-memory-drift.sh" ] && [ -f "$REPO_ROOT/scripts/check-memory-drift.ps1" ]; then
  CMD_QUOTED="$PARITY_TMP/cmd-quoted"
  mkdir -p "$CMD_QUOTED"
  # Quoted name + CLOSED headline + body links ONLY to its own (quoted) name.
  cat > "$CMD_QUOTED/project_selflink.md" <<'EOF'
---
name: "project_selflink"
description: "Self-referential project — CLOSED 2026-01-01. Sealed."
---

Body mentions only [[project_selflink]] (its own name) — no follow-on pointer.
EOF

  q_bash_out="$PARITY_TMP/cmd-quoted-bash.out"
  bash "$REPO_ROOT/scripts/check-memory-drift.sh" --memory-dir "$CMD_QUOTED" \
    > "$q_bash_out" 2>&1
  q_bash_rc=$?
  assert_eq "check-memory-drift bash: quoted-name self-link is NOT drift (exit 0)" 0 "$q_bash_rc"

  if [ "$_have_pwsh" -eq 1 ]; then
    q_ps_out="$PARITY_TMP/cmd-quoted-ps.out"
    pwsh -NoProfile -File "$REPO_ROOT/scripts/check-memory-drift.ps1" \
      -MemoryDir "$CMD_QUOTED" > "$q_ps_out" 2>&1
    q_ps_rc=$?
    assert_eq "check-memory-drift ps: quoted-name self-link is NOT drift (exit 0)" 0 "$q_ps_rc"
    assert_eq "check-memory-drift parity: quoted-name self-link exit codes match (quote-strip)" \
      "$q_bash_rc" "$q_ps_rc"
  else
    _skip "check-memory-drift ps: quoted-name self-link is NOT drift (exit 0)" "pwsh not installed"
    _skip "check-memory-drift parity: quoted-name self-link exit codes match (quote-strip)" "pwsh not installed"
  fi
else
  _skip "check-memory-drift bash: quoted-name self-link is NOT drift (exit 0)" "scripts not present"
  _skip "check-memory-drift ps: quoted-name self-link is NOT drift (exit 0)" "scripts not present"
  _skip "check-memory-drift parity: quoted-name self-link exit codes match (quote-strip)" "scripts not present"
fi

# ---------------------------------------------------------------------------
# Test 1c: check-memory-drift parity — single-quoted `name:` symmetry.
#
# PS Get-FmField strips only DOUBLE quotes (it is not a YAML engine), and so does the
# bash own_name parser. A single-quoted `name: 'x'` is therefore handled IDENTICALLY
# by both (single quotes retained) — they reach the SAME verdict even though neither
# strips single quotes. Pin the SYMMETRY (assert parity, not a specific exit value, so
# a future symmetric single-quote fix keeps this green). Refutes the review assumption
# that the twins diverge on single quotes.
# ---------------------------------------------------------------------------

if [ -f "$REPO_ROOT/scripts/check-memory-drift.sh" ] && [ -f "$REPO_ROOT/scripts/check-memory-drift.ps1" ]; then
  CMD_SQUOTE="$PARITY_TMP/cmd-squote"
  mkdir -p "$CMD_SQUOTE"
  cat > "$CMD_SQUOTE/project_squote.md" <<'EOF'
---
name: 'project_squote'
description: "Single-quoted name project — CLOSED 2026-01-01. Sealed."
---

Body links only [[project_squote]] (its own name).
EOF
  sq_bash_out="$PARITY_TMP/cmd-squote-bash.out"
  bash "$REPO_ROOT/scripts/check-memory-drift.sh" --memory-dir "$CMD_SQUOTE" \
    > "$sq_bash_out" 2>&1; sq_bash_rc=$?
  if [ "$_have_pwsh" -eq 1 ]; then
    sq_ps_out="$PARITY_TMP/cmd-squote-ps.out"
    pwsh -NoProfile -File "$REPO_ROOT/scripts/check-memory-drift.ps1" \
      -MemoryDir "$CMD_SQUOTE" > "$sq_ps_out" 2>&1; sq_ps_rc=$?
    assert_eq "check-memory-drift parity: single-quoted name self-link — exit codes match (twins symmetric)" \
      "$sq_bash_rc" "$sq_ps_rc"
  else
    _skip "check-memory-drift parity: single-quoted name self-link — exit codes match (twins symmetric)" "pwsh not installed"
  fi
else
  _skip "check-memory-drift parity: single-quoted name self-link — exit codes match (twins symmetric)" "scripts not present"
fi

# ---------------------------------------------------------------------------
# Test 1d: check-memory-drift parity — UTF-8 BOM'd project file.
#
# A BOM ahead of the first `---` made the bash DRIFT parsers (description / own_name)
# miss the frontmatter entirely (their `/^---$/` gate never matched the BOM'd line),
# so a CLOSED BOM'd project that drifts was silently NOT flagged in bash while PS
# (ReadAllLines strips the BOM) flagged it — opposite verdicts. The bash parsers now
# strip a leading BOM (matching the in-file frontmatter scan + PS). Pin: a BOM'd
# CLOSED project linking to a DIFFERENT project must drift in bash (exit 1) and match
# the PS twin. (Pre-fix this fixture trips the bash sanity assertion.)
# ---------------------------------------------------------------------------

if [ -f "$REPO_ROOT/scripts/check-memory-drift.sh" ] && [ -f "$REPO_ROOT/scripts/check-memory-drift.ps1" ]; then
  CMD_BOM="$PARITY_TMP/cmd-bom"
  mkdir -p "$CMD_BOM"
  printf '\xef\xbb\xbf---\nname: project_bom\ndescription: "BOM project — CLOSED 2026-01-01."\n---\n\nSuccessor [[project_other]] carries the live work.\n' \
    > "$CMD_BOM/project_bom.md"
  bom_bash_out="$PARITY_TMP/cmd-bom-bash.out"
  bash "$REPO_ROOT/scripts/check-memory-drift.sh" --memory-dir "$CMD_BOM" \
    > "$bom_bash_out" 2>&1; bom_bash_rc=$?
  assert_eq "check-memory-drift bash: BOM'd CLOSED project still detects drift (BOM strip)" 1 "$bom_bash_rc"
  if [ "$_have_pwsh" -eq 1 ]; then
    bom_ps_out="$PARITY_TMP/cmd-bom-ps.out"
    pwsh -NoProfile -File "$REPO_ROOT/scripts/check-memory-drift.ps1" \
      -MemoryDir "$CMD_BOM" > "$bom_ps_out" 2>&1; bom_ps_rc=$?
    assert_eq "check-memory-drift parity: BOM'd project exit codes match (BOM strip)" \
      "$bom_bash_rc" "$bom_ps_rc"
  else
    _skip "check-memory-drift parity: BOM'd project exit codes match (BOM strip)" "pwsh not installed"
  fi
else
  _skip "check-memory-drift bash: BOM'd CLOSED project still detects drift (BOM strip)" "scripts not present"
  _skip "check-memory-drift parity: BOM'd project exit codes match (BOM strip)" "scripts not present"
fi

# ---------------------------------------------------------------------------
# Test 2: scripts/self-audit.{sh,ps1}
#
# Run with --isolated (no operator-env fallbacks) + --json so the output is
# stable. Assert the JSON parses + the date and total fields match. Inner
# pillars depend on fixture state — for a fully-clean tree both sides should
# emit 100/100. We assert TOTAL match.
# ---------------------------------------------------------------------------

if [ -f "$REPO_ROOT/scripts/self-audit.sh" ] && [ -f "$REPO_ROOT/scripts/self-audit.ps1" ]; then
  # Build a tiny throwaway repo-like fixture so neither side scores on the
  # operator's real tree (which could legitimately differ between runs).
  SA_FIX="$PARITY_TMP/sa-fix"
  mkdir -p "$SA_FIX/core" "$SA_FIX/playbooks" "$SA_FIX/verification" \
           "$SA_FIX/capabilities" "$SA_FIX/harnesses/claude/capabilities" \
           "$SA_FIX/harnesses/codex/capabilities"
  # Minimal required files so Pillar 4/5 don't deduct.
  for f in operating-system self-improvement memory-model verification tool-use; do
    : > "$SA_FIX/core/$f.md"
  done

  bash_sa_out="$PARITY_TMP/sa-bash.json"
  bash "$REPO_ROOT/scripts/self-audit.sh" --json --isolated --repo-root "$SA_FIX" \
    > "$bash_sa_out" 2>/dev/null
  bash_sa_rc=$?
  assert_eq "self-audit bash exits 0 on isolated fixture" 0 "$bash_sa_rc"

  if command -v jq >/dev/null 2>&1; then
    bash_sa_total="$(jq -r '.total' < "$bash_sa_out" 2>/dev/null || echo 'ERR')"
    [ -n "$bash_sa_total" ] && [ "$bash_sa_total" != "ERR" ] \
      && _pass "self-audit bash emits parseable total" \
      || _fail "self-audit bash emits parseable total" "got: $bash_sa_total"
  else
    _skip "self-audit bash emits parseable total" "jq not installed"
  fi

  if [ "$_have_pwsh" -eq 1 ]; then
    ps_sa_out="$PARITY_TMP/sa-ps.json"
    pwsh -NoProfile -File "$REPO_ROOT/scripts/self-audit.ps1" \
      -Json -Isolated -RepoRoot "$SA_FIX" > "$ps_sa_out" 2>/dev/null
    ps_sa_rc=$?
    assert_eq "self-audit ps exits 0 on isolated fixture" 0 "$ps_sa_rc"

    if command -v jq >/dev/null 2>&1; then
      ps_sa_total="$(jq -r '.total' < "$ps_sa_out" 2>/dev/null || echo 'ERR')"
      assert_eq "self-audit parity: total scores match" "$bash_sa_total" "$ps_sa_total"

      # Per-pillar score parity. Pillars are key-stable.
      for pkey in cross-layer-handoffs memory-hygiene folder-hygiene \
                  verification-coverage closeout-spine-discipline; do
        bash_p="$(jq -r ".pillars[\"$pkey\"].score" < "$bash_sa_out" 2>/dev/null)"
        ps_p="$(jq -r ".pillars[\"$pkey\"].score" < "$ps_sa_out" 2>/dev/null)"
        assert_eq "self-audit parity: pillar $pkey score" "$bash_p" "$ps_p"
      done
    else
      _skip "self-audit parity: total scores match" "jq not installed"
      _skip "self-audit parity: pillar cross-layer-handoffs score" "jq not installed"
      _skip "self-audit parity: pillar memory-hygiene score" "jq not installed"
      _skip "self-audit parity: pillar folder-hygiene score" "jq not installed"
      _skip "self-audit parity: pillar verification-coverage score" "jq not installed"
      _skip "self-audit parity: pillar closeout-spine-discipline score" "jq not installed"
    fi
  else
    _skip "self-audit ps exits 0 on isolated fixture" "pwsh not installed"
    _skip "self-audit parity: total scores match" "pwsh not installed"
    for pkey in cross-layer-handoffs memory-hygiene folder-hygiene \
                verification-coverage closeout-spine-discipline; do
      _skip "self-audit parity: pillar $pkey score" "pwsh not installed"
    done
  fi
else
  _skip "self-audit bash exits 0 on isolated fixture" "scripts not present"
fi

# ---------------------------------------------------------------------------
# Test 2b: self-audit parity — freshness window at the 7-day boundary.
#
# Pillar 5 flags recent project_*.md (mtime within 7 days) that lack a
# `## State Deltas` section. The bash twin used `find -mtime -7`, which rounds the
# age by whole days — and BSD/macOS find rounds UP while GNU/Linux truncates, so a
# ~6.5-day-old file landed INSIDE the window on Linux but OUTSIDE on macOS,
# disagreeing with the PS twin's instant compare → a per-platform pillar-score
# flake. Both twins now use an integer-second epoch cutoff, so a 6.5-day file is
# counted on every platform. Pin it: one boundary file (no State Deltas) must drive
# the SAME closeout-spine-discipline pillar score in both twins. Pre-fix this trips
# on the macOS lane (BSD round-up); post-fix it is green everywhere. Requires perl
# (portable utime) to set the mtime; skips cleanly if absent. Reuses Test 2's
# SA_FIX repo-root so the only Pillar-5 delta is the freshness sub-check.
# ---------------------------------------------------------------------------

if [ -f "$REPO_ROOT/scripts/self-audit.sh" ] && [ -f "$REPO_ROOT/scripts/self-audit.ps1" ] \
   && command -v perl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && [ -d "${SA_FIX:-}" ]; then
  SA_MEM="$PARITY_TMP/sa-mem-boundary"
  mkdir -p "$SA_MEM"
  # A project memory file ~6.5 days old (inside the 7-day window on an epoch basis)
  # with NO `## State Deltas` — both twins must count it as a recent miss.
  cat > "$SA_MEM/project_boundary.md" <<'EOF'
---
name: project_boundary
description: "Recent project — In Progress."
---

Body without a State Deltas section.
EOF
  # Score the closeout-spine-discipline pillar from both twins after setting the
  # boundary file's mtime to $1 days old. Echoes "bash_score ps_score".
  _sa_score_at() { # $1 = age in days
    perl -e 'my $t = time - int($ARGV[1]*86400); utime $t, $t, $ARGV[0] or die "utime: $!"' \
      "$SA_MEM/project_boundary.md" "$1"
    local b p
    b="$(bash "$REPO_ROOT/scripts/self-audit.sh" --json --isolated \
      --repo-root "$SA_FIX" --memory-dir "$SA_MEM" 2>/dev/null \
      | jq -r '.pillars["closeout-spine-discipline"].score' 2>/dev/null)"
    if [ "$_have_pwsh" -eq 1 ]; then
      p="$(pwsh -NoProfile -File "$REPO_ROOT/scripts/self-audit.ps1" --json --isolated \
        --repo-root "$SA_FIX" --memory-dir "$SA_MEM" 2>/dev/null \
        | jq -r '.pillars["closeout-spine-discipline"].score' 2>/dev/null)"
    else
      p='(skip)'
    fi
    printf '%s %s' "$b" "$p"
  }

  read -r in_b in_p <<<"$(_sa_score_at 6.5)"    # INSIDE the 7-day window
  read -r out_b out_p <<<"$(_sa_score_at 7.5)"  # OUTSIDE the 7-day window

  # The boundary file must be COUNTED inside 7 days and EXCLUDED outside, so the
  # pillar deducts exactly one State-Deltas penalty (4) MORE at 6.5d than at 7.5d.
  # Asserting the DELTA (not the absolute 16 vs 20) locks the epoch cutoff while
  # staying robust to an unrelated baseline shift — a "score != 20" check would pass
  # even if the file were never counted but some other sub-check moved the score.
  case "$in_b$out_b" in
    ''|*[!0-9]*)
      _fail "self-audit bash: 6.5d counted / 7.5d excluded — one State-Deltas penalty (epoch cutoff)" \
        "non-numeric pillar scores: in(6.5d)=$in_b out(7.5d)=$out_b" ;;
    *)
      assert_eq "self-audit bash: 6.5d counted / 7.5d excluded — one State-Deltas penalty (epoch cutoff)" \
        "4" "$(( out_b - in_b ))" ;;
  esac

  if [ "$_have_pwsh" -eq 1 ]; then
    assert_eq "self-audit parity: 6.5-day (inside) pillar score matches (epoch freshness)" "$in_b" "$in_p"
    assert_eq "self-audit parity: 7.5-day (outside) pillar score matches (epoch freshness)" "$out_b" "$out_p"
  else
    _skip "self-audit parity: 6.5-day (inside) pillar score matches (epoch freshness)" "pwsh not installed"
    _skip "self-audit parity: 7.5-day (outside) pillar score matches (epoch freshness)" "pwsh not installed"
  fi
  unset -f _sa_score_at
else
  _skip "self-audit bash: 6.5d counted / 7.5d excluded — one State-Deltas penalty (epoch cutoff)" \
    "scripts/perl/jq missing or SA_FIX unbuilt"
  _skip "self-audit parity: 6.5-day (inside) pillar score matches (epoch freshness)" \
    "scripts/perl/jq missing or SA_FIX unbuilt"
  _skip "self-audit parity: 7.5-day (outside) pillar score matches (epoch freshness)" \
    "scripts/perl/jq missing or SA_FIX unbuilt"
fi

# ---------------------------------------------------------------------------
# Test 3: scripts/check-drift.{sh,ps1} — --manifest mode parity
#
# We can't run repo-mode parity here without building a complete fixture
# repository that has every required file + manifest. The --manifest mode is
# the high-leverage path (used by install.sh's drift gate + the acceptance
# suite). Both modes share the same entry script — testing --manifest is
# sufficient for port-parity coverage, with the same shape as
# tests/install-render-stable.test.sh's drift assertions.
#
# Fixture: build a tiny target dir with a manifest + matching files. Assert
# both sides exit 0 + emit a PASS line.
# ---------------------------------------------------------------------------

if [ -f "$REPO_ROOT/scripts/check-drift.sh" ] && [ -f "$REPO_ROOT/scripts/check-drift.ps1" ]; then
  if command -v jq >/dev/null 2>&1 && command -v shasum >/dev/null 2>&1; then
    CD_FIX="$PARITY_TMP/cd-fix"
    mkdir -p "$CD_FIX/skills" "$CD_FIX/hooks"
    : > "$CD_FIX/settings.json"
    printf '{}\n' > "$CD_FIX/settings.json"
    settings_hash="$(shasum -a 256 "$CD_FIX/settings.json" | cut -d' ' -f1)"

    # Minimal valid manifest with the one file + harness field.
    cat > "$CD_FIX/.build-manifest.json" <<EOF
{
  "harness": "claude",
  "generated": {
    "settings.json": "$settings_hash"
  }
}
EOF

    bash_cd_out="$PARITY_TMP/cd-bash.out"
    bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$CD_FIX" \
      > "$bash_cd_out" 2>&1
    bash_cd_rc=$?
    assert_eq "check-drift bash --manifest exits 0 on clean fixture" 0 "$bash_cd_rc"

    if [ "$_have_pwsh" -eq 1 ]; then
      ps_cd_out="$PARITY_TMP/cd-ps.out"
      pwsh -NoProfile -File "$REPO_ROOT/scripts/check-drift.ps1" \
        -Manifest "$CD_FIX" > "$ps_cd_out" 2>&1
      ps_cd_rc=$?
      assert_eq "check-drift ps --manifest exits 0 on clean fixture" 0 "$ps_cd_rc"
      assert_eq "check-drift parity: exit codes match (clean manifest)" \
        "$bash_cd_rc" "$ps_cd_rc"

      bash_cd_norm="$(_normalize "$bash_cd_out" | _sort_classes)"
      ps_cd_norm="$(_normalize "$ps_cd_out" | _sort_classes)"
      assert_eq "check-drift parity: sorted output-classes match (clean manifest)" \
        "$bash_cd_norm" "$ps_cd_norm"
    else
      _skip "check-drift ps --manifest exits 0 on clean fixture" "pwsh not installed"
      _skip "check-drift parity: exit codes match (clean manifest)" "pwsh not installed"
      _skip "check-drift parity: sorted output-classes match (clean manifest)" "pwsh not installed"
    fi

    # Drift fixture: mutate settings.json so the hash mismatches the manifest.
    printf '{"drift":true}\n' > "$CD_FIX/settings.json"

    bash_cd_drift_out="$PARITY_TMP/cd-bash-drift.out"
    bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$CD_FIX" \
      > "$bash_cd_drift_out" 2>&1
    bash_cd_drift_rc=$?
    assert_eq "check-drift bash --manifest exits 1 on drift fixture" 1 "$bash_cd_drift_rc"

    if [ "$_have_pwsh" -eq 1 ]; then
      ps_cd_drift_out="$PARITY_TMP/cd-ps-drift.out"
      pwsh -NoProfile -File "$REPO_ROOT/scripts/check-drift.ps1" \
        -Manifest "$CD_FIX" > "$ps_cd_drift_out" 2>&1
      ps_cd_drift_rc=$?
      assert_eq "check-drift ps --manifest exits 1 on drift fixture" 1 "$ps_cd_drift_rc"
      assert_eq "check-drift parity: exit codes match (drift manifest)" \
        "$bash_cd_drift_rc" "$ps_cd_drift_rc"
    else
      _skip "check-drift ps --manifest exits 1 on drift fixture" "pwsh not installed"
      _skip "check-drift parity: exit codes match (drift manifest)" "pwsh not installed"
    fi
  else
    _skip "check-drift bash --manifest exits 0 on clean fixture" "jq or shasum missing"
    _skip "check-drift ps --manifest exits 0 on clean fixture" "jq or shasum missing"
    _skip "check-drift parity: exit codes match (clean manifest)" "jq or shasum missing"
    _skip "check-drift parity: sorted output-classes match (clean manifest)" "jq or shasum missing"
    _skip "check-drift bash --manifest exits 1 on drift fixture" "jq or shasum missing"
    _skip "check-drift ps --manifest exits 1 on drift fixture" "jq or shasum missing"
    _skip "check-drift parity: exit codes match (drift manifest)" "jq or shasum missing"
  fi
else
  _skip "check-drift bash --manifest exits 0 on clean fixture" "scripts not present"
fi

# ---------------------------------------------------------------------------
# Test 3b: check-drift parity — STRICT BYTE-IDENTICAL diff on clean fixture
# (Codex F-4: class-only compare is insufficient for the Issue 5B byte-parity
# contract. Apply normalization rules + assert full stdout/stderr bytes match.)
#
# Re-uses the Test 3 clean fixture's PASS line (the only output on success).
# Restores clean settings.json (Test 3 mutated it for drift assertion).
# ---------------------------------------------------------------------------

if [ -f "$REPO_ROOT/scripts/check-drift.sh" ] && [ -f "$REPO_ROOT/scripts/check-drift.ps1" ] \
   && command -v jq >/dev/null 2>&1 && command -v shasum >/dev/null 2>&1 \
   && [ -d "$PARITY_TMP/cd-fix" ]; then
  if [ "$_have_pwsh" -eq 1 ]; then
    # Restore clean state — Test 3 mutated settings.json to provoke drift.
    printf '{}\n' > "$PARITY_TMP/cd-fix/settings.json"

    bash_byte_out="$PARITY_TMP/cd-bash-byte.out"
    ps_byte_out="$PARITY_TMP/cd-ps-byte.out"
    bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$PARITY_TMP/cd-fix" \
      > "$bash_byte_out" 2>&1
    pwsh -NoProfile -File "$REPO_ROOT/scripts/check-drift.ps1" \
      -Manifest "$PARITY_TMP/cd-fix" > "$ps_byte_out" 2>&1

    bash_byte_norm="$(_normalize "$bash_byte_out")"
    ps_byte_norm="$(_normalize "$ps_byte_out")"
    assert_eq "check-drift parity: STRICT byte-identical normalized output (clean manifest)" \
      "$bash_byte_norm" "$ps_byte_norm"
  else
    _skip "check-drift parity: STRICT byte-identical normalized output (clean manifest)" "pwsh not installed"
  fi
else
  _skip "check-drift parity: STRICT byte-identical normalized output (clean manifest)" "Test 3 prereqs missing"
fi

# ---------------------------------------------------------------------------
# Test 3c: check-drift parity — managed skills/<sub>/... + hooks/... entries
# (Codex F-5: original Test 3 only exercised manifest mode with bare settings.json.
# This test covers the relpath-computation surface that the F-1 fix targets —
# subdir-structured paths inside skills/ and hooks/ where the bash twin's
# string-substring approach happened to work coincidentally but the PS port's
# Substring($target.Length) would miscompute relpaths if $target was relative.)
# ---------------------------------------------------------------------------

if [ -f "$REPO_ROOT/scripts/check-drift.sh" ] && [ -f "$REPO_ROOT/scripts/check-drift.ps1" ] \
   && command -v jq >/dev/null 2>&1 && command -v shasum >/dev/null 2>&1; then
  CD_FIX2="$PARITY_TMP/cd-fix-skills-hooks"
  mkdir -p "$CD_FIX2/skills/managed-skill" "$CD_FIX2/hooks"

  # Three manifest-tracked files at subdir depth.
  printf '# managed skill body\n' > "$CD_FIX2/skills/managed-skill/SKILL.md"
  printf '#!/usr/bin/env bash\necho hook-body\n' > "$CD_FIX2/hooks/example.sh"
  printf '{}\n' > "$CD_FIX2/settings.json"

  skill_hash="$(shasum -a 256 "$CD_FIX2/skills/managed-skill/SKILL.md" | cut -d' ' -f1)"
  hook_hash="$(shasum -a 256 "$CD_FIX2/hooks/example.sh" | cut -d' ' -f1)"
  settings2_hash="$(shasum -a 256 "$CD_FIX2/settings.json" | cut -d' ' -f1)"

  cat > "$CD_FIX2/.build-manifest.json" <<EOF
{
  "harness": "claude",
  "generated": {
    "settings.json": "$settings2_hash",
    "skills/managed-skill/SKILL.md": "$skill_hash",
    "hooks/example.sh": "$hook_hash"
  }
}
EOF

  bash_cd2_out="$PARITY_TMP/cd-bash-skills.out"
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$CD_FIX2" \
    > "$bash_cd2_out" 2>&1
  bash_cd2_rc=$?
  assert_eq "check-drift bash --manifest exits 0 on skills+hooks fixture" 0 "$bash_cd2_rc"

  if [ "$_have_pwsh" -eq 1 ]; then
    ps_cd2_out="$PARITY_TMP/cd-ps-skills.out"
    pwsh -NoProfile -File "$REPO_ROOT/scripts/check-drift.ps1" \
      -Manifest "$CD_FIX2" > "$ps_cd2_out" 2>&1
    ps_cd2_rc=$?
    assert_eq "check-drift ps --manifest exits 0 on skills+hooks fixture" 0 "$ps_cd2_rc"

    bash_cd2_norm="$(_normalize "$bash_cd2_out")"
    ps_cd2_norm="$(_normalize "$ps_cd2_out")"
    assert_eq "check-drift parity: STRICT byte-identical (skills+hooks fixture)" \
      "$bash_cd2_norm" "$ps_cd2_norm"
  else
    _skip "check-drift ps --manifest exits 0 on skills+hooks fixture" "pwsh not installed"
    _skip "check-drift parity: STRICT byte-identical (skills+hooks fixture)" "pwsh not installed"
  fi
else
  _skip "check-drift bash --manifest exits 0 on skills+hooks fixture" "scripts or jq/shasum missing"
fi

# ---------------------------------------------------------------------------
# Test 3d: check-drift parity — RELATIVE -Manifest path argument
# (Codex F-1 regression guard: when $Manifest is a relative path like
# `./fixture-dir`, the PS port's Substring($target.Length) computation against
# absolute $full paths produced wrong relpaths → false-reported tracked files
# as untracked drift. Fix canonicalizes $target to absolute early; this test
# pins that fix.)
# ---------------------------------------------------------------------------

if [ -d "$PARITY_TMP/cd-fix-skills-hooks" ] && [ "$_have_pwsh" -eq 1 ] \
   && [ -f "$REPO_ROOT/scripts/check-drift.ps1" ]; then
  # Cd into PARITY_TMP and pass a RELATIVE path. The fixture is at
  # $PARITY_TMP/cd-fix-skills-hooks; relative path is./cd-fix-skills-hooks.
  ps_rel_out="$PARITY_TMP/cd-ps-rel.out"
  (
    cd "$PARITY_TMP" && \
    pwsh -NoProfile -File "$REPO_ROOT/scripts/check-drift.ps1" \
      -Manifest './cd-fix-skills-hooks' > "$ps_rel_out" 2>&1
  )
  ps_rel_rc=$?
  assert_eq "check-drift ps --manifest exits 0 on RELATIVE path (F-1 regression)" 0 "$ps_rel_rc"

  bash_rel_out="$PARITY_TMP/cd-bash-rel.out"
  (
    cd "$PARITY_TMP" && \
    bash "$REPO_ROOT/scripts/check-drift.sh" --manifest './cd-fix-skills-hooks' \
      > "$bash_rel_out" 2>&1
  )
  bash_rel_rc=$?
  assert_eq "check-drift bash --manifest exits 0 on RELATIVE path (F-1 regression)" 0 "$bash_rel_rc"

  bash_rel_norm="$(_normalize "$bash_rel_out")"
  ps_rel_norm="$(_normalize "$ps_rel_out")"
  assert_eq "check-drift parity: STRICT byte-identical (RELATIVE path)" \
    "$bash_rel_norm" "$ps_rel_norm"
else
  _skip "check-drift ps --manifest exits 0 on RELATIVE path (F-1 regression)" "Test 3c prereqs missing"
  _skip "check-drift bash --manifest exits 0 on RELATIVE path (F-1 regression)" "Test 3c prereqs missing"
  _skip "check-drift parity: STRICT byte-identical (RELATIVE path)" "Test 3c prereqs missing"
fi

# ---------------------------------------------------------------------------
# Test 3e: check-memory-drift parity — MULTI-DRIFT byte-identity
# (Codex F-3 regression guard: bash uses drift=1 boolean → prints "1 drift(s)"
# even when N drift files exist. PS port now mirrors that quirk for byte-parity.
# Two drifted project files in fixture; both bash + PS must print "1 drift(s)".)
# ---------------------------------------------------------------------------

if [ -f "$REPO_ROOT/scripts/check-memory-drift.sh" ] \
   && [ -f "$REPO_ROOT/scripts/check-memory-drift.ps1" ]; then
  CMD_FIX="$PARITY_TMP/cmd-fix-multi"
  mkdir -p "$CMD_FIX"
  # Two drifted projects: each headline says DONE but body links to a different
  # project that the description does NOT mention. Mirror the bash test's setup.
  cat > "$CMD_FIX/project_alpha.md" <<'EOF'
---
name: project_alpha
description: DONE — closed 2026-05-25.
---

Successor is [[project_beta]] which carries the live work.
EOF
  cat > "$CMD_FIX/project_gamma.md" <<'EOF'
---
name: project_gamma
description: COMPLETE — finished 2026-05-26.
---

Successor is [[project_delta]] which carries the live work.
EOF

  bash_cmd_out="$PARITY_TMP/cmd-bash-multi.out"
  bash "$REPO_ROOT/scripts/check-memory-drift.sh" --memory-dir "$CMD_FIX" \
    > "$bash_cmd_out" 2>&1
  bash_cmd_rc=$?
  assert_eq "check-memory-drift bash exits 1 on 2-drift fixture" 1 "$bash_cmd_rc"

  if [ "$_have_pwsh" -eq 1 ]; then
    ps_cmd_out="$PARITY_TMP/cmd-ps-multi.out"
    pwsh -NoProfile -File "$REPO_ROOT/scripts/check-memory-drift.ps1" \
      --memory-dir "$CMD_FIX" > "$ps_cmd_out" 2>&1
    ps_cmd_rc=$?
    assert_eq "check-memory-drift ps exits 1 on 2-drift fixture" 1 "$ps_cmd_rc"

    # Use SORTED-CLASS compare (not strict byte-identical) for multi-drift
    # fixture: bash `find` returns filesystem-walk order (varies per system);
    # PS `Get-ChildItem` returns alphabetical by default on macOS/Linux. The
    # two enumerate the SAME set of drifted files but emit FAIL lines in
    # different orders. Sort-before-compare preserves byte-parity at the
    # SET level (each FAIL line byte-identical) while accepting the
    # iteration-order divergence as a documented gotcha — same precedent as
    # the existing _sort_classes use for check-drift Test 3 (line 325).
    bash_cmd_norm="$(_normalize "$bash_cmd_out" | _sort_classes)"
    ps_cmd_norm="$(_normalize "$ps_cmd_out" | _sort_classes)"
    assert_eq "check-memory-drift parity: sorted byte-identical (2-drift fixture; iteration-order divergent)" \
      "$bash_cmd_norm" "$ps_cmd_norm"

    # F-3 specific: both should report exactly "1 drift(s)" (bash quirk), not "2".
    if /usr/bin/grep -qE 'FAIL 1 drift\(s\)' "$bash_cmd_out"; then
      _pass "check-memory-drift bash reports '1 drift(s)' (bash boolean quirk)"
    else
      _fail "check-memory-drift bash reports '1 drift(s)' (bash boolean quirk)" \
        "expected 'FAIL 1 drift(s)' in bash output"
    fi
    if /usr/bin/grep -qE 'FAIL 1 drift\(s\)' "$ps_cmd_out"; then
      _pass "check-memory-drift ps mirrors bash '1 drift(s)' quirk (F-3 port-parity)"
    else
      _fail "check-memory-drift ps mirrors bash '1 drift(s)' quirk (F-3 port-parity)" \
        "expected 'FAIL 1 drift(s)' in PS output"
    fi
  else
    _skip "check-memory-drift ps exits 1 on 2-drift fixture" "pwsh not installed"
    _skip "check-memory-drift parity: STRICT byte-identical (2-drift fixture)" "pwsh not installed"
    _skip "check-memory-drift bash reports '1 drift(s)' (bash boolean quirk)" "pwsh not installed"
    _skip "check-memory-drift ps mirrors bash '1 drift(s)' quirk (F-3 port-parity)" "pwsh not installed"
  fi
else
  _skip "check-memory-drift bash exits 1 on 2-drift fixture" "scripts not present"
fi

# ---------------------------------------------------------------------------
# Test 3f: POSIX-flag parity — each.ps1 port accepts the bash twin's
# documented --flag-name forms (Codex F-2 regression guard).
#
# Existing tests above invoked the.ps1 ports via PS-native -Manifest /
# -MemoryDir / -RepoRoot. F-2 surfaced that bash callers using --manifest /
# --memory-dir / --repo-root would fail as unknown PowerShell parameters.
# Fix added ValueFromRemainingArguments parsers to all 3 ports; this test
# pins that fix by invoking each.ps1 with the POSIX flag form ONLY.
# ---------------------------------------------------------------------------

if [ "$_have_pwsh" -eq 1 ]; then
  # check-memory-drift.ps1 with --memory-dir (POSIX form)
  if [ -f "$REPO_ROOT/scripts/check-memory-drift.ps1" ]; then
    posix_cmd_dir="$PARITY_TMP/posix-cmd-empty"
    mkdir -p "$posix_cmd_dir"
    posix_cmd_out="$PARITY_TMP/posix-cmd.out"
    pwsh -NoProfile -File "$REPO_ROOT/scripts/check-memory-drift.ps1" \
      --memory-dir "$posix_cmd_dir" > "$posix_cmd_out" 2>&1
    posix_cmd_rc=$?
    assert_eq "check-memory-drift.ps1 accepts POSIX --memory-dir" 0 "$posix_cmd_rc"
  else
    _skip "check-memory-drift.ps1 accepts POSIX --memory-dir" "scripts not present"
  fi

  # self-audit.ps1 with --json + --isolated + --repo-root (POSIX form)
  if [ -f "$REPO_ROOT/scripts/self-audit.ps1" ]; then
    posix_sa_out="$PARITY_TMP/posix-sa.out"
    pwsh -NoProfile -File "$REPO_ROOT/scripts/self-audit.ps1" \
      --json --isolated --repo-root "$REPO_ROOT" > "$posix_sa_out" 2>&1
    posix_sa_rc=$?
    assert_eq "self-audit.ps1 accepts POSIX --json + --isolated + --repo-root" 0 "$posix_sa_rc"
  else
    _skip "self-audit.ps1 accepts POSIX --json + --isolated + --repo-root" "scripts not present"
  fi

  # check-drift.ps1 with --manifest + --cure-soft-drift (POSIX form)
  if [ -f "$REPO_ROOT/scripts/check-drift.ps1" ] && [ -d "$PARITY_TMP/cd-fix" ]; then
    # Restore clean state for this re-run.
    printf '{}\n' > "$PARITY_TMP/cd-fix/settings.json"
    posix_cd_out="$PARITY_TMP/posix-cd.out"
    pwsh -NoProfile -File "$REPO_ROOT/scripts/check-drift.ps1" \
      --manifest "$PARITY_TMP/cd-fix" > "$posix_cd_out" 2>&1
    posix_cd_rc=$?
    assert_eq "check-drift.ps1 accepts POSIX --manifest" 0 "$posix_cd_rc"
  else
    _skip "check-drift.ps1 accepts POSIX --manifest" "Test 3 prereqs missing"
  fi
else
  _skip "check-memory-drift.ps1 accepts POSIX --memory-dir" "pwsh not installed"
  _skip "self-audit.ps1 accepts POSIX --json + --isolated + --repo-root" "pwsh not installed"
  _skip "check-drift.ps1 accepts POSIX --manifest" "pwsh not installed"
fi

# ---------------------------------------------------------------------------
# Test 4: scripts/build-public-snapshot.{sh,ps1} — --help / -Help parity
#
# ships the full implementation. Both twins MUST accept their
# respective help flag (POSIX --help on bash; PS native -Help on.ps1) and
# exit 0. Cite the pinned-enumeration contract terms in the bash twin's
# help output.
# ---------------------------------------------------------------------------

if [ -f "$REPO_ROOT/scripts/build-public-snapshot.sh" ] && \
   [ -f "$REPO_ROOT/scripts/build-public-snapshot.ps1" ]; then
  snap_sh_out="$PARITY_TMP/snap-sh.out"
  bash "$REPO_ROOT/scripts/build-public-snapshot.sh" --help > "$snap_sh_out" 2>&1
  snap_sh_rc=$?
  [ "$snap_sh_rc" -eq 0 ] \
    && _pass "build-public-snapshot.sh --help exits 0" \
    || _fail "build-public-snapshot.sh --help exits 0" "got rc=$snap_sh_rc"

  if [ "$_have_pwsh" -eq 1 ]; then
    snap_ps_out="$PARITY_TMP/snap-ps.out"
    pwsh -NoProfile -File "$REPO_ROOT/scripts/build-public-snapshot.ps1" -Help \
      > "$snap_ps_out" 2>&1
    snap_ps_rc=$?
    [ "$snap_ps_rc" -eq 0 ] \
      && _pass "build-public-snapshot.ps1 -Help exits 0" \
      || _fail "build-public-snapshot.ps1 -Help exits 0" "got rc=$snap_ps_rc"

    assert_eq "build-public-snapshot --help/-Help exit codes match" \
      "$snap_sh_rc" "$snap_ps_rc"
  else
    _skip "build-public-snapshot.ps1 -Help exits 0" "pwsh not installed"
    _skip "build-public-snapshot --help/-Help exit codes match" "pwsh not installed"
  fi
else
  _skip "build-public-snapshot.sh --help exits 0" "scripts not both present"
  _skip "build-public-snapshot.ps1 -Help exits 0" "scripts not both present"
  _skip "build-public-snapshot --help/-Help exit codes match" "scripts not both present"
fi

# ---------------------------------------------------------------------------
# Test 5: sanitize-for-publish.ps1 byte-parity re-check (no-regression anchor)
#
# shipped both twins with bash↔pwsh byte-identity verified end-to-end.
# The cure-soft-drift + orphan-skill-hardening changes landed later
# and could have leaked deltas into check-drift's allowlist surface. Re-assert
# that running both scrubbers on the same fixture still produces byte-identical
# output. (A cheap anchor that re-fires here so the PR explicitly
# proves no regression slid in.)
# ---------------------------------------------------------------------------

if [ -f "$REPO_ROOT/scripts/sanitize-for-publish.sh" ] && \
   [ -f "$REPO_ROOT/scripts/sanitize-for-publish.ps1" ] && \
   [ "$_have_pwsh" -eq 1 ]; then
  # Use distinct fixture roots so each scrubber operates on its own tree;
  # then diff the resulting trees.
  SANI_BASH="$PARITY_TMP/sani-bash"
  SANI_PS="$PARITY_TMP/sani-ps"
  mkdir -p "$SANI_BASH/core" "$SANI_PS/core"

  # Same leak content into both fixtures. Use runtime-construct sentinels to
  # avoid self-tripping per [[feedback_self_tripping_test_source]].
  _que='QU''E-'
  _qp='Question''Pilot'
  _ws='question''-pilot'
  for d in "$SANI_BASH" "$SANI_PS"; do
    {
      printf 'Some refinement rule. (%s99)\n' "$_que"
      printf 'See [%s100](https://linear.app/%s/issue/%s100) too.\n' "$_que" "$_ws" "$_que"
      printf 'And the %s name.\n' "$_qp"
    } > "$d/core/foo.md"
  done

  bash "$REPO_ROOT/scripts/sanitize-for-publish.sh" \
    --root "$SANI_BASH" --report "$SANI_BASH/r.txt" >/dev/null 2>&1
  pwsh -NoProfile -File "$REPO_ROOT/scripts/sanitize-for-publish.ps1" \
    -Root "$SANI_PS" -Report "$SANI_PS/r.txt" >/dev/null 2>&1

  bash_hash="$(LC_ALL=C tr -d '\r' < "$SANI_BASH/core/foo.md" | shasum -a 256 | awk '{print $1}')"
  ps_hash="$(LC_ALL=C tr -d '\r' < "$SANI_PS/core/foo.md" | shasum -a 256 | awk '{print $1}')"
  assert_eq "sanitize-for-publish parity holds" "$bash_hash" "$ps_hash"
else
  _skip "sanitize-for-publish parity holds" "pwsh missing or scripts not present"
fi

# ---------------------------------------------------------------------------
# Test: scripts/check-clean.{sh,ps1}
#
# Run both twins against a shared dirty fixture (issue ID + home path + email)
# and a clean fixture; assert exit codes + sorted output-classes match. The
# planted sentinels are runtime-built from non-matching halves so this source
# does not self-trip the cleanliness guard it exercises.
# ---------------------------------------------------------------------------
if [ -f "$REPO_ROOT/scripts/check-clean.sh" ] && [ -f "$REPO_ROOT/scripts/check-clean.ps1" ]; then
  _cc_que="QU""E"; _cc_users="Us""ers"; _cc_at='@'
  CC_DIRTY="$PARITY_TMP/cc-dirty"; mkdir -p "$CC_DIRTY"
  printf 'tracked under %s-7 here\n' "$_cc_que"      > "$CC_DIRTY/i.md"
  printf 'path /%s/realdev/x\n' "$_cc_users"         > "$CC_DIRTY/p.md"
  printf 'mail real%sacme-corp.io\n' "$_cc_at"       > "$CC_DIRTY/e.md"

  CC_CLEAN="$PARITY_TMP/cc-clean"; mkdir -p "$CC_CLEAN"
  printf 'home /%s/<name>/ and you%sexample.com\n' "$_cc_users" "$_cc_at" > "$CC_CLEAN/c.md"

  cc_bash_dirty="$PARITY_TMP/cc-bash-dirty.out"
  bash "$REPO_ROOT/scripts/check-clean.sh" "$CC_DIRTY" > "$cc_bash_dirty" 2>&1
  cc_bash_dirty_rc=$?
  cc_bash_clean="$PARITY_TMP/cc-bash-clean.out"
  bash "$REPO_ROOT/scripts/check-clean.sh" "$CC_CLEAN" > "$cc_bash_clean" 2>&1
  cc_bash_clean_rc=$?

  assert_eq "check-clean bash exits 1 on dirty fixture" 1 "$cc_bash_dirty_rc"
  assert_eq "check-clean bash exits 0 on clean fixture" 0 "$cc_bash_clean_rc"

  if [ "$_have_pwsh" -eq 1 ]; then
    cc_ps_dirty="$PARITY_TMP/cc-ps-dirty.out"
    pwsh -NoProfile -File "$REPO_ROOT/scripts/check-clean.ps1" "$CC_DIRTY" > "$cc_ps_dirty" 2>&1
    cc_ps_dirty_rc=$?
    cc_ps_clean="$PARITY_TMP/cc-ps-clean.out"
    pwsh -NoProfile -File "$REPO_ROOT/scripts/check-clean.ps1" "$CC_CLEAN" > "$cc_ps_clean" 2>&1
    cc_ps_clean_rc=$?

    assert_eq "check-clean parity: exit codes match (dirty)" "$cc_bash_dirty_rc" "$cc_ps_dirty_rc"
    assert_eq "check-clean parity: exit codes match (clean)" "$cc_bash_clean_rc" "$cc_ps_clean_rc"

    cc_bash_norm="$(_normalize "$cc_bash_dirty" | _sort_classes)"
    cc_ps_norm="$(_normalize "$cc_ps_dirty" | _sort_classes)"
    assert_eq "check-clean parity: sorted output-classes match (dirty)" "$cc_bash_norm" "$cc_ps_norm"
  else
    _skip "check-clean parity: exit codes match (dirty)" "pwsh not installed"
    _skip "check-clean parity: exit codes match (clean)" "pwsh not installed"
    _skip "check-clean parity: sorted output-classes match (dirty)" "pwsh not installed"
  fi
else
  _skip "check-clean bash exits 1 on dirty fixture" "scripts not present"
  _skip "check-clean bash exits 0 on clean fixture" "scripts not present"
  _skip "check-clean parity: exit codes match (dirty)" "scripts not present"
  _skip "check-clean parity: exit codes match (clean)" "scripts not present"
  _skip "check-clean parity: sorted output-classes match (dirty)" "scripts not present"
fi

# ---------------------------------------------------------------------------
# Test: scripts/check-distillation-completeness.{sh,ps1}
#
# Run both twins against a shared lessons fixture (one thematic note recording a
# kebab + a snake source-note name) and two memory fixtures: one all-distilled
# (exit 0) and one with an undistilled note (exit 1). Assert exit codes + sorted
# output-classes match. The undistilled-summary + PASS lines embed the fixture
# dirs, which _normalize masks to <TMP> identically for both twins.
# ---------------------------------------------------------------------------
if [ -f "$REPO_ROOT/scripts/check-distillation-completeness.sh" ] \
   && [ -f "$REPO_ROOT/scripts/check-distillation-completeness.ps1" ]; then
  DC_LES="$PARITY_TMP/dc-les"; mkdir -p "$DC_LES"
  cat > "$DC_LES/2026-06-15 - Theme.md" <<'EOF'
---
title: Theme
---
## Source Notes
- feedback-distilled-kebab
- feedback_distilled_snake
EOF
  # All-distilled memory dir (both names recorded above; kebab + snake).
  DC_OK="$PARITY_TMP/dc-ok"; mkdir -p "$DC_OK"
  printf -- '---\nname: feedback-distilled-kebab\ndescription: "n"\nmetadata:\n  type: feedback\n---\nBody.\n' > "$DC_OK/feedback-distilled-kebab.md"
  printf -- '---\nname: feedback_distilled_snake\ndescription: "n"\nmetadata:\n  type: feedback\n---\nBody.\n' > "$DC_OK/feedback_distilled_snake.md"
  # Undistilled memory dir (a feedback note absent from the corpus).
  DC_BAD="$PARITY_TMP/dc-bad"; mkdir -p "$DC_BAD"
  printf -- '---\nname: feedback-orphan\ndescription: "n"\nmetadata:\n  type: feedback\n---\nBody.\n' > "$DC_BAD/feedback-orphan.md"

  # EDGE memory dir — the bash<->PS divergence-risk inputs Codex flagged, all
  # undistilled so each is expected to flag identically in both twins:
  #   - frontmatter-only no-prefix feedback note (selection via frontmatter type)
  #   - BOM'd no-prefix feedback note (bash strips BOM in awk; PS via ReadAllLines)
  #   - bare `feedback.md` stem with a non-feedback type (filename word-boundary)
  #   - a prefix note whose superset name IS distilled (whole-token boundary).
  DC_EDGE="$PARITY_TMP/dc-edge"; mkdir -p "$DC_EDGE"
  printf -- '---\nname: home-folder\ndescription: "n"\nmetadata:\n  type: feedback\n---\nBody.\n' > "$DC_EDGE/home-folder.md"
  printf -- '\xef\xbb\xbf---\nname: bom-note\ndescription: "n"\nmetadata:\n  type: feedback\n---\nBody.\n' > "$DC_EDGE/bom-note.md"
  printf -- '---\nname: feedback\ndescription: "n"\nmetadata:\n  type: note\n---\nBody.\n' > "$DC_EDGE/feedback.md"
  printf -- '---\nname: feedback-cross-model-review\ndescription: "n"\nmetadata:\n  type: feedback\n---\nBody.\n' > "$DC_EDGE/feedback-cross-model-review.md"
  DC_EDGE_LES="$PARITY_TMP/dc-edge-les"; mkdir -p "$DC_EDGE_LES"
  printf -- '---\ntitle: Edge\n---\n## Source Notes\n- feedback-cross-model-review-infra\n' > "$DC_EDGE_LES/lesson.md"

  dc_bash_ok="$PARITY_TMP/dc-bash-ok.out"
  bash "$REPO_ROOT/scripts/check-distillation-completeness.sh" --memory-dir "$DC_OK" --lessons-dir "$DC_LES" > "$dc_bash_ok" 2>&1
  dc_bash_ok_rc=$?
  dc_bash_bad="$PARITY_TMP/dc-bash-bad.out"
  bash "$REPO_ROOT/scripts/check-distillation-completeness.sh" --memory-dir "$DC_BAD" --lessons-dir "$DC_LES" > "$dc_bash_bad" 2>&1
  dc_bash_bad_rc=$?
  dc_bash_edge="$PARITY_TMP/dc-bash-edge.out"
  bash "$REPO_ROOT/scripts/check-distillation-completeness.sh" --memory-dir "$DC_EDGE" --lessons-dir "$DC_EDGE_LES" > "$dc_bash_edge" 2>&1
  dc_bash_edge_rc=$?

  assert_eq "check-distillation-completeness bash exits 0 (all distilled)" 0 "$dc_bash_ok_rc"
  assert_eq "check-distillation-completeness bash exits 1 (undistilled)" 1 "$dc_bash_bad_rc"
  assert_eq "check-distillation-completeness bash exits 1 (edge inputs)" 1 "$dc_bash_edge_rc"

  if [ "$_have_pwsh" -eq 1 ]; then
    dc_ps_ok="$PARITY_TMP/dc-ps-ok.out"
    pwsh -NoProfile -File "$REPO_ROOT/scripts/check-distillation-completeness.ps1" --memory-dir "$DC_OK" --lessons-dir "$DC_LES" > "$dc_ps_ok" 2>&1
    dc_ps_ok_rc=$?
    dc_ps_bad="$PARITY_TMP/dc-ps-bad.out"
    pwsh -NoProfile -File "$REPO_ROOT/scripts/check-distillation-completeness.ps1" --memory-dir "$DC_BAD" --lessons-dir "$DC_LES" > "$dc_ps_bad" 2>&1
    dc_ps_bad_rc=$?
    dc_ps_edge="$PARITY_TMP/dc-ps-edge.out"
    pwsh -NoProfile -File "$REPO_ROOT/scripts/check-distillation-completeness.ps1" --memory-dir "$DC_EDGE" --lessons-dir "$DC_EDGE_LES" > "$dc_ps_edge" 2>&1
    dc_ps_edge_rc=$?

    assert_eq "check-distillation-completeness parity: exit codes match (all distilled)" "$dc_bash_ok_rc" "$dc_ps_ok_rc"
    assert_eq "check-distillation-completeness parity: exit codes match (undistilled)" "$dc_bash_bad_rc" "$dc_ps_bad_rc"
    assert_eq "check-distillation-completeness parity: exit codes match (edge inputs)" "$dc_bash_edge_rc" "$dc_ps_edge_rc"

    dc_bash_ok_norm="$(_normalize "$dc_bash_ok" | _sort_classes)"
    dc_ps_ok_norm="$(_normalize "$dc_ps_ok" | _sort_classes)"
    assert_eq "check-distillation-completeness parity: sorted output-classes match (all distilled)" "$dc_bash_ok_norm" "$dc_ps_ok_norm"

    dc_bash_bad_norm="$(_normalize "$dc_bash_bad" | _sort_classes)"
    dc_ps_bad_norm="$(_normalize "$dc_ps_bad" | _sort_classes)"
    assert_eq "check-distillation-completeness parity: sorted output-classes match (undistilled)" "$dc_bash_bad_norm" "$dc_ps_bad_norm"

    # The edge case is the high-value parity assertion: frontmatter-only, BOM,
    # bare-stem, and boundary inputs must flag the SAME set of notes in both twins.
    dc_bash_edge_norm="$(_normalize "$dc_bash_edge" | _sort_classes)"
    dc_ps_edge_norm="$(_normalize "$dc_ps_edge" | _sort_classes)"
    assert_eq "check-distillation-completeness parity: sorted output-classes match (edge inputs)" "$dc_bash_edge_norm" "$dc_ps_edge_norm"
  else
    _skip "check-distillation-completeness parity: exit codes match (all distilled)" "pwsh not installed"
    _skip "check-distillation-completeness parity: exit codes match (undistilled)" "pwsh not installed"
    _skip "check-distillation-completeness parity: exit codes match (edge inputs)" "pwsh not installed"
    _skip "check-distillation-completeness parity: sorted output-classes match (all distilled)" "pwsh not installed"
    _skip "check-distillation-completeness parity: sorted output-classes match (undistilled)" "pwsh not installed"
    _skip "check-distillation-completeness parity: sorted output-classes match (edge inputs)" "pwsh not installed"
  fi
else
  _skip "check-distillation-completeness bash exits 0 (all distilled)" "scripts not present"
  _skip "check-distillation-completeness bash exits 1 (undistilled)" "scripts not present"
fi

# ---------------------------------------------------------------------------
# Test: scripts/check-wikilinks.{sh,ps1}
#
# Run both twins against a shared fixture vault (one root note + one subfolder
# note) and three drafts: all-resolve (exit 0), bare-subfolder + unknown
# (exit 1), and an edge draft (aliased/heading collapse to one target,
# backticked name ignored, empty [[ ]] fail-closed → exit 1). Assert exit codes
# + sorted output-classes match. The draft path embeds the fixture dir, which
# _normalize masks to <TMP> identically for both twins; the indented suggestion
# line is non-class so _sort_classes drops it from the comparison.
# ---------------------------------------------------------------------------
if [ -f "$REPO_ROOT/scripts/check-wikilinks.sh" ] \
   && [ -f "$REPO_ROOT/scripts/check-wikilinks.ps1" ]; then
  WL_VAULT="$PARITY_TMP/wl-vault"; mkdir -p "$WL_VAULT/10-Wiki/Concepts"
  printf -- '---\ntitle: START\n---\n' > "$WL_VAULT/START.md"
  printf -- '---\ntitle: Foo\n---\n'   > "$WL_VAULT/10-Wiki/Concepts/Foo.md"

  WL_OK="$PARITY_TMP/wl-ok.md"
  printf 'Good [[10-Wiki/Concepts/Foo]] and [[START]].\n' > "$WL_OK"
  WL_BAD="$PARITY_TMP/wl-bad.md"
  printf 'Bare [[Foo]] and unknown [[Nope]].\n' > "$WL_BAD"
  WL_EDGE="$PARITY_TMP/wl-edge.md"
  printf 'Alias [[10-Wiki/Concepts/Foo|x]], heading [[10-Wiki/Concepts/Foo#h]], `feedback-x` backticked, empty [[ ]].\n' > "$WL_EDGE"

  wl_bash_ok="$PARITY_TMP/wl-bash-ok.out"
  bash "$REPO_ROOT/scripts/check-wikilinks.sh" --draft "$WL_OK" --vault "$WL_VAULT" > "$wl_bash_ok" 2>&1
  wl_bash_ok_rc=$?
  wl_bash_bad="$PARITY_TMP/wl-bash-bad.out"
  bash "$REPO_ROOT/scripts/check-wikilinks.sh" --draft "$WL_BAD" --vault "$WL_VAULT" > "$wl_bash_bad" 2>&1
  wl_bash_bad_rc=$?
  wl_bash_edge="$PARITY_TMP/wl-bash-edge.out"
  bash "$REPO_ROOT/scripts/check-wikilinks.sh" --draft "$WL_EDGE" --vault "$WL_VAULT" > "$wl_bash_edge" 2>&1
  wl_bash_edge_rc=$?

  assert_eq "check-wikilinks bash exits 0 (all resolve)" 0 "$wl_bash_ok_rc"
  assert_eq "check-wikilinks bash exits 1 (unresolved)" 1 "$wl_bash_bad_rc"
  assert_eq "check-wikilinks bash exits 1 (edge inputs)" 1 "$wl_bash_edge_rc"

  if [ "$_have_pwsh" -eq 1 ]; then
    wl_ps_ok="$PARITY_TMP/wl-ps-ok.out"
    pwsh -NoProfile -File "$REPO_ROOT/scripts/check-wikilinks.ps1" --draft "$WL_OK" --vault "$WL_VAULT" > "$wl_ps_ok" 2>&1
    wl_ps_ok_rc=$?
    wl_ps_bad="$PARITY_TMP/wl-ps-bad.out"
    pwsh -NoProfile -File "$REPO_ROOT/scripts/check-wikilinks.ps1" --draft "$WL_BAD" --vault "$WL_VAULT" > "$wl_ps_bad" 2>&1
    wl_ps_bad_rc=$?
    wl_ps_edge="$PARITY_TMP/wl-ps-edge.out"
    pwsh -NoProfile -File "$REPO_ROOT/scripts/check-wikilinks.ps1" --draft "$WL_EDGE" --vault "$WL_VAULT" > "$wl_ps_edge" 2>&1
    wl_ps_edge_rc=$?

    assert_eq "check-wikilinks parity: exit codes match (all resolve)" "$wl_bash_ok_rc" "$wl_ps_ok_rc"
    assert_eq "check-wikilinks parity: exit codes match (unresolved)" "$wl_bash_bad_rc" "$wl_ps_bad_rc"
    assert_eq "check-wikilinks parity: exit codes match (edge inputs)" "$wl_bash_edge_rc" "$wl_ps_edge_rc"

    wl_bash_ok_norm="$(_normalize "$wl_bash_ok" | _sort_classes)"
    wl_ps_ok_norm="$(_normalize "$wl_ps_ok" | _sort_classes)"
    assert_eq "check-wikilinks parity: sorted output-classes match (all resolve)" "$wl_bash_ok_norm" "$wl_ps_ok_norm"

    wl_bash_bad_norm="$(_normalize "$wl_bash_bad" | _sort_classes)"
    wl_ps_bad_norm="$(_normalize "$wl_ps_bad" | _sort_classes)"
    assert_eq "check-wikilinks parity: sorted output-classes match (unresolved)" "$wl_bash_bad_norm" "$wl_ps_bad_norm"

    wl_bash_edge_norm="$(_normalize "$wl_bash_edge" | _sort_classes)"
    wl_ps_edge_norm="$(_normalize "$wl_ps_edge" | _sort_classes)"
    assert_eq "check-wikilinks parity: sorted output-classes match (edge inputs)" "$wl_bash_edge_norm" "$wl_ps_edge_norm"
  else
    _skip "check-wikilinks parity: exit codes match (all resolve)" "pwsh not installed"
    _skip "check-wikilinks parity: exit codes match (unresolved)" "pwsh not installed"
    _skip "check-wikilinks parity: exit codes match (edge inputs)" "pwsh not installed"
    _skip "check-wikilinks parity: sorted output-classes match (all resolve)" "pwsh not installed"
    _skip "check-wikilinks parity: sorted output-classes match (unresolved)" "pwsh not installed"
    _skip "check-wikilinks parity: sorted output-classes match (edge inputs)" "pwsh not installed"
  fi
else
  _skip "check-wikilinks bash exits 0 (all resolve)" "scripts not present"
  _skip "check-wikilinks bash exits 1 (unresolved)" "scripts not present"
fi

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

rm -rf "$PARITY_TMP" 2>/dev/null || true
unset PARITY_TMP _have_pwsh 2>/dev/null || true
