#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/operator-skill-parity.test.sh — unit acceptance for
# scripts/operator-skill-parity-check.sh.
#
# The script diffs the CONTENT of every UNMANAGED (operator-copied) skill in a
# canonical render home against each mirror render home — the gap check-drift
# cannot see, because the build manifest only tracks the managed spine skills.
#
# Verified here: in-sync → PASS with the right denominator; planted content
# drift → DRIFT + exit 1 (positive control); allowlisted pair → VARIANT + exit 0;
# a skill absent from a mirror → MISSING + exit 1; no mirror root present → FAIL
# (never a silent PASS); manifest-managed skills excluded from the comparison;
# a missing canonical root → FAIL; a path containing a space handled intact.
#
# Sourced by tests/run.sh — must not call exit or set -e/-u/pipefail.

OSP="$REPO_ROOT/scripts/operator-skill-parity-check.sh"
assert_file "operator-skill-parity-check.sh present" "$OSP"

# osp_fixture <dir> — canonical root at "<dir>/home a/skills" (SPACE in the path
# is deliberate: the parallel-array contract exists because render-home paths
# contain spaces) with two unmanaged skills (alpha, beta) plus one
# manifest-managed skill (session-agent, whose mirror copy DIFFERS so an
# exclusion regression shows up as a DRIFT line). Mirrors m1 + m2 start in sync.
osp_fixture() {
  local d="$1" c="$1/home a/skills"
  mkdir -p "$c/alpha" "$c/beta" "$c/session-agent"
  printf 'alpha body\n' > "$c/alpha/SKILL.md"
  printf 'beta body\n'  > "$c/beta/SKILL.md"
  printf 'canonical spine render\n' > "$c/session-agent/SKILL.md"
  printf '{"harness":"claude","generated":{"skills/session-agent/SKILL.md":"deadbeef","settings.json":"cafe"}}\n' \
    > "$d/home a/.build-manifest.json"
  local m
  for m in m1 m2; do
    mkdir -p "$d/$m/skills/alpha" "$d/$m/skills/beta" "$d/$m/skills/session-agent"
    printf 'alpha body\n' > "$d/$m/skills/alpha/SKILL.md"
    printf 'beta body\n'  > "$d/$m/skills/beta/SKILL.md"
    printf 'per-harness %s spine render\n' "$m" > "$d/$m/skills/session-agent/SKILL.md"
  done
}

# osp_run <dir> [ALLOWLIST] [MIRRORS-override] — run the script against a fixture.
# AI_CONFIG_LOCAL_ENV points at a nonexistent file so the operator's real
# local.env can never leak into a fixture run.
osp_run() {
  local d="$1" allow="${2:-}" mirrors="${3:-}"
  [ -n "$mirrors" ] || mirrors="m1=$d/m1/skills,m2=$d/m2/skills"
  env AI_CONFIG_LOCAL_ENV="$d/no-such-local.env" \
      SKILL_PARITY_CANONICAL="$d/home a/skills" \
      SKILL_PARITY_MIRRORS="$mirrors" \
      SKILL_PARITY_ALLOWLIST="$allow" \
      bash "$OSP" 2>&1
}

# --- (a) in-sync mirrors PASS with the correct denominator ------------------
# 2 unmanaged skills x 2 mirror roots = 4 comparisons. The denominator is
# load-bearing: a PASS that compared nothing is the failure mode this gate
# exists to prevent.
D1="$(mktemp -d)"; osp_fixture "$D1"
o="$(osp_run "$D1")"; rc=$?
assert_eq       "operator-skill-parity: in-sync exits 0"        0 "$rc"
assert_contains "operator-skill-parity: in-sync prints PASS"    "$o" "PASS operator-skill parity"
assert_contains "operator-skill-parity: denominator is 4 across 2 of 2" \
  "$o" "4 comparison(s) across 2 of 2 mirror root(s)"

# --- (f) manifest-managed (spine) skills are excluded -----------------------
# session-agent differs in BOTH mirrors by construction; the run above passed,
# which only proves exclusion if no DRIFT line names it.
assert_not_contains "operator-skill-parity: manifest-managed skill not compared" \
  "$o" "session-agent"

# --- no-manifest fallback compares everything (and says so) -----------------
mv "$D1/home a/.build-manifest.json" "$D1/manifest.bak"
o="$(osp_run "$D1")"; rc=$?
assert_eq       "operator-skill-parity: no manifest → exit 1 (spine now compared)" 1 "$rc"
assert_contains "operator-skill-parity: no manifest prints NOTE"    "$o" "NOTE   no build manifest at"
assert_contains "operator-skill-parity: no manifest compares spine" "$o" "DRIFT   m1       session-agent"
mv "$D1/manifest.bak" "$D1/home a/.build-manifest.json"
rm -rf "$D1"

# --- (b) planted content drift → DRIFT + exit 1 (positive control) ----------
D2="$(mktemp -d)"; osp_fixture "$D2"
printf 'alpha body EDITED\n' > "$D2/m2/skills/alpha/SKILL.md"
o="$(osp_run "$D2")"; rc=$?
assert_eq       "operator-skill-parity: planted drift exits 1"      1 "$rc"
assert_contains "operator-skill-parity: planted drift names the pair" "$o" "DRIFT   m2       alpha"
assert_contains "operator-skill-parity: planted drift prints FAIL"  "$o" "FAIL operator-skill parity drift"
assert_not_contains "operator-skill-parity: clean mirror not flagged" "$o" "DRIFT   m1"

# --- (c) allowlisted variant → VARIANT + exit 0 -----------------------------
o="$(osp_run "$D2" "m2/alpha")"; rc=$?
assert_eq       "operator-skill-parity: allowlisted variant exits 0" 0 "$rc"
assert_contains "operator-skill-parity: allowlisted prints VARIANT"  "$o" "VARIANT m2       alpha (allowlisted)"
assert_not_contains "operator-skill-parity: allowlisted prints no DRIFT" "$o" "DRIFT"
assert_contains "operator-skill-parity: allowlisted still PASSes with denominator" \
  "$o" "4 comparison(s) across 2 of 2 mirror root(s)"

# An allowlist entry for a DIFFERENT root must not excuse this one — the
# membership test is on the whole `<label>/<skill>` pair, not the skill name.
o="$(osp_run "$D2" "m1/alpha")"; rc=$?
assert_eq       "operator-skill-parity: allowlist is per-root, not per-skill" 1 "$rc"
assert_contains "operator-skill-parity: wrong-root allowlist still DRIFTs"    "$o" "DRIFT   m2       alpha"
rm -rf "$D2"

# --- (d) missing skill dir in a mirror → MISSING + exit 1 -------------------
D3="$(mktemp -d)"; osp_fixture "$D3"
rm -rf "$D3/m1/skills/beta"
o="$(osp_run "$D3")"; rc=$?
assert_eq       "operator-skill-parity: missing skill exits 1"     1 "$rc"
assert_contains "operator-skill-parity: missing skill reported"    "$o" "MISSING m1       beta"
assert_not_contains "operator-skill-parity: missing is not reported as DRIFT" "$o" "DRIFT"
rm -rf "$D3"

# --- (e) zero mirror roots present → FAIL, never a silent PASS --------------
D4="$(mktemp -d)"; osp_fixture "$D4"
o="$(osp_run "$D4" "" "m1=$D4/absent-1/skills,m2=$D4/absent-2/skills")"; rc=$?
assert_eq       "operator-skill-parity: zero present roots exits 1" 1 "$rc"
assert_contains "operator-skill-parity: zero present roots FAILs loudly" \
  "$o" "FAIL no mirror root was present"
assert_not_contains "operator-skill-parity: zero present roots never PASSes" "$o" "PASS"
assert_contains "operator-skill-parity: absent root SKIP is loud" "$o" "SKIP   m1       root not present"

# --- one root present, one absent → compares, denominator says 1 of 2 -------
o="$(osp_run "$D4" "" "m1=$D4/m1/skills,gone=$D4/absent/skills")"; rc=$?
assert_eq       "operator-skill-parity: partial roots exits 0"      0 "$rc"
assert_contains "operator-skill-parity: partial roots denominator is 2 across 1 of 2" \
  "$o" "2 comparison(s) across 1 of 2 mirror root(s)"
rm -rf "$D4"

# --- missing canonical root → FAIL (fail loud, never open) ------------------
D5="$(mktemp -d)"
o="$(env AI_CONFIG_LOCAL_ENV="$D5/no-such-local.env" \
        SKILL_PARITY_CANONICAL="$D5/nope/skills" \
        SKILL_PARITY_MIRRORS="m1=$D5/m1/skills" \
        bash "$OSP" 2>&1)"; rc=$?
assert_eq       "operator-skill-parity: missing canonical root exits 1" 1 "$rc"
assert_contains "operator-skill-parity: missing canonical root FAILs"   "$o" "FAIL canonical skill root missing"

# --- no canonical root configured at all → FAIL -----------------------------
o="$(env AI_CONFIG_LOCAL_ENV="$D5/no-such-local.env" \
        SKILL_PARITY_CANONICAL="" CLAUDE_CONFIG_DIR="" \
        SKILL_PARITY_MIRRORS="m1=$D5/m1/skills" \
        bash "$OSP" 2>&1)"; rc=$?
assert_eq       "operator-skill-parity: unconfigured canonical exits 1" 1 "$rc"
assert_contains "operator-skill-parity: unconfigured canonical names the key" \
  "$o" "set SKILL_PARITY_CANONICAL"

# --- no mirror configured at all → FAIL, not a vacuous PASS -----------------
o="$(env AI_CONFIG_LOCAL_ENV="$D5/no-such-local.env" \
        SKILL_PARITY_CANONICAL="$D5" SKILL_PARITY_MIRRORS="" \
        CODEX_HOME="" AGENTS_DIR="" CURSOR_CONFIG_DIR="" \
        bash "$OSP" 2>&1)"; rc=$?
assert_eq       "operator-skill-parity: no mirror configured exits 1" 1 "$rc"
assert_contains "operator-skill-parity: no mirror configured FAILs"   "$o" "FAIL no mirror skill root configured"
rm -rf "$D5"

# --- bare-path mirror entry derives its label from the render home ----------
# `<home>/.codex/skills` → label `codex` (leading dot stripped).
D6="$(mktemp -d)"; osp_fixture "$D6"
mkdir -p "$D6/.codex"
cp -R "$D6/m1/skills" "$D6/.codex/skills"
printf 'alpha body EDITED\n' > "$D6/.codex/skills/alpha/SKILL.md"
o="$(osp_run "$D6" "" "$D6/.codex/skills")"; rc=$?
assert_eq       "operator-skill-parity: bare-path mirror exits 1 on drift" 1 "$rc"
assert_contains "operator-skill-parity: bare-path mirror label is 'codex'"  "$o" "DRIFT   codex    alpha"
rm -rf "$D6"

# --- canonical with no unmanaged skills → SKIP, exit 0 ----------------------
D7="$(mktemp -d)"
mkdir -p "$D7/home a/skills/session-agent" "$D7/m1/skills"
printf 'x\n' > "$D7/home a/skills/session-agent/SKILL.md"
printf '{"generated":{"skills/session-agent/SKILL.md":"h"}}\n' > "$D7/home a/.build-manifest.json"
o="$(osp_run "$D7" "" "m1=$D7/m1/skills")"; rc=$?
assert_eq       "operator-skill-parity: nothing unmanaged exits 0"  0 "$rc"
assert_contains "operator-skill-parity: nothing unmanaged SKIPs"    "$o" "SKIP   no unmanaged skills to compare"
rm -rf "$D7"
