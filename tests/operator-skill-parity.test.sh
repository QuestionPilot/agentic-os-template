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
# a skill absent from a mirror → MISSING + exit 1; no mirror root present → FAIL;
# Hermes consumes the Capability Map subset, declared variants use their named
# source pair, and an absent Hermes root cannot pass through another mirror.
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

# osp_map <dir> — minimal Capability Map schema used by the Hermes lane. alpha
# is expected on Hermes; beta's absence is intentional because its Where cell
# excludes Hermes. session-agent proves managed skills remain excluded.
osp_map() {
  local d="$1"
  printf '%s\n' \
    '| Skill | What | Where |' \
    '| --- | --- | --- |' \
    '| `alpha` | expected | all |' \
    '| `beta` | intentional absence | claude, codex |' \
    '| `session-agent` | managed | all |' \
    > "$d/Capability Map.md"
}

# osp_case_map <dir> — same schema with mixed-case headers and Where tokens.
osp_case_map() {
  local d="$1"
  printf '%s\n' \
    '| sKiLl | What | wHeRe |' \
    '| --- | --- | --- |' \
    '| `alpha` | Hermes casing | HeRmEs |' \
    '| `beta` | All casing | ALL |' \
    '| `session-agent` | managed | aLl |' \
    > "$d/Capability Map.md"
}

# osp_two_column_map <dir> <with-final-pipe> — the minimum accepted Skill /
# Where schema, with either trailing-pipe form.
osp_two_column_map() {
  local d="$1" final_pipe="$2"
  if [ "$final_pipe" = "yes" ]; then
    printf '%s\n' \
      '| Skill | Where |' \
      '| :--- | :--- |' \
      '| `alpha` | all |' \
      '| `session-agent` | all |' \
      > "$d/Capability Map.md"
  else
    printf '%s\n' \
      '| Skill | Where' \
      '| :--- | :---' \
      '| `alpha` | all' \
      '| `session-agent` | all' \
      > "$d/Capability Map.md"
  fi
}

# osp_run <dir> [ALLOWLIST] [MIRRORS-override] [MAP] [VARIANTS] — run against a fixture.
# AI_CONFIG_LOCAL_ENV points at a nonexistent file so the operator's real
# local.env can never leak into a fixture run.
osp_run() {
  local d="$1" allow="${2:-}" mirrors="${3:-}" map="${4:-}" variants="${5:-}"
  [ -n "$mirrors" ] || mirrors="m1=$d/m1/skills,m2=$d/m2/skills"
  env AI_CONFIG_LOCAL_ENV="$d/no-such-local.env" \
      SKILL_PARITY_CANONICAL="$d/home a/skills" \
      SKILL_PARITY_MIRRORS="$mirrors" \
      SKILL_PARITY_ALLOWLIST="$allow" \
      SKILL_PARITY_CAPABILITY_MAP="$map" \
      SKILL_PARITY_VARIANTS="$variants" \
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

# --- Hermes consumes the Capability Map, not the canonical full roster ------
D8="$(mktemp -d)"; osp_fixture "$D8"; osp_map "$D8"
mkdir -p "$D8/hermes/skills/alpha"
printf 'alpha body\n' > "$D8/hermes/skills/alpha/SKILL.md"
o="$(osp_run "$D8" "" "m1=$D8/m1/skills,m2=$D8/m2/skills,hermes=$D8/hermes/skills" "$D8/Capability Map.md")"; rc=$?
assert_eq       "operator-skill-parity: Hermes intentional absence exits 0" 0 "$rc"
assert_contains "operator-skill-parity: Hermes subset reports its map source" "$o" "NOTE   Hermes expected subset: 2 skill(s) from $D8/Capability Map.md"
assert_not_contains "operator-skill-parity: map-omitted Hermes skill is not missing" "$o" "MISSING hermes   beta"

rm -rf "$D8/hermes/skills/alpha"
o="$(osp_run "$D8" "" "m1=$D8/m1/skills,m2=$D8/m2/skills,hermes=$D8/hermes/skills" "$D8/Capability Map.md")"; rc=$?
assert_eq       "operator-skill-parity: expected Hermes skill missing exits 1" 1 "$rc"
assert_contains "operator-skill-parity: expected Hermes skill is reported" "$o" "MISSING hermes   alpha"
rm -rf "$D8"

# A declared Hermes variant must match its declared Codex source, not merely
# escape a canonical-root comparison. The Codex copy itself remains allowlisted.
D9="$(mktemp -d)"; osp_fixture "$D9"; osp_map "$D9"
printf 'codex variant\n' > "$D9/m1/skills/alpha/SKILL.md"
mkdir -p "$D9/hermes/skills/alpha"
printf 'codex variant\n' > "$D9/hermes/skills/alpha/SKILL.md"
o="$(osp_run "$D9" "codex/alpha" "codex=$D9/m1/skills,hermes=$D9/hermes/skills" "$D9/Capability Map.md" "hermes/alpha=codex/alpha")"; rc=$?
assert_eq       "operator-skill-parity: declared Hermes variant exits 0" 0 "$rc"
assert_contains "operator-skill-parity: declared Hermes variant names its source pair" "$o" "VARIANT hermes   alpha (matched codex/alpha)"

# A declared pair is enforcement, not an allowlist: a Hermes body that differs
# from its named Codex source must stay red and name that expected source.
printf 'wrong variant\n' > "$D9/hermes/skills/alpha/SKILL.md"
o="$(osp_run "$D9" "codex/alpha" "codex=$D9/m1/skills,hermes=$D9/hermes/skills" "$D9/Capability Map.md" "hermes/alpha=codex/alpha")"; rc=$?
assert_eq       "operator-skill-parity: declared Hermes variant mismatch exits 1" 1 "$rc"
assert_contains "operator-skill-parity: declared Hermes variant mismatch names expected source" "$o" "DRIFT   hermes   alpha (expected codex/alpha)"
rm -rf "$D9"

# A configured Hermes home cannot disappear while another mirror still passes.
D10="$(mktemp -d)"; osp_fixture "$D10"; osp_map "$D10"
o="$(osp_run "$D10" "" "m1=$D10/m1/skills,hermes=$D10/absent-hermes/skills" "$D10/Capability Map.md")"; rc=$?
assert_eq       "operator-skill-parity: absent Hermes home exits 1" 1 "$rc"
assert_contains "operator-skill-parity: absent Hermes home fails loudly" "$o" "FAIL Hermes skill root missing: $D10/absent-hermes/skills"
assert_not_contains "operator-skill-parity: absent Hermes home cannot PASS" "$o" "PASS operator-skill parity"
rm -rf "$D10"

# Capability Map header and Where tokens are case-insensitive in both twins.
D11="$(mktemp -d)"; osp_fixture "$D11"; osp_case_map "$D11"
mkdir -p "$D11/hermes/skills/alpha" "$D11/hermes/skills/beta"
printf 'alpha body\n' > "$D11/hermes/skills/alpha/SKILL.md"
printf 'beta body\n' > "$D11/hermes/skills/beta/SKILL.md"
o="$(osp_run "$D11" "" "m1=$D11/m1/skills,hermes=$D11/hermes/skills" "$D11/Capability Map.md")"; rc=$?
assert_eq       "operator-skill-parity: mixed-case Hermes and All map tokens exit 0" 0 "$rc"
assert_contains "operator-skill-parity: mixed-case map finds all expected skills" "$o" "NOTE   Hermes expected subset: 3 skill(s) from $D11/Capability Map.md"
rm -rf "$D11"

# A canonical root with no skill dirs is a normal no-work result on macOS Bash 3.2.
D12="$(mktemp -d)"
mkdir -p "$D12/canonical" "$D12/m1/skills"
o="$(env AI_CONFIG_LOCAL_ENV="$D12/no-such-local.env" SKILL_PARITY_CANONICAL="$D12/canonical" SKILL_PARITY_MIRRORS="m1=$D12/m1/skills" bash "$OSP" 2>&1)"; rc=$?
assert_eq       "operator-skill-parity: empty canonical root exits 0" 0 "$rc"
assert_contains "operator-skill-parity: empty canonical root SKIPs cleanly" "$o" "SKIP   no unmanaged skills to compare"
rm -rf "$D12"

# Bash rejects the same extra-slash pair shapes as the PowerShell twin.
D13="$(mktemp -d)"; osp_fixture "$D13"
o="$(osp_run "$D13" "" "m1=$D13/m1/skills" "" "m1/alpha/extra=canonical/alpha")"; rc=$?
assert_eq       "operator-skill-parity: extra-slash variant target exits 1" 1 "$rc"
assert_contains "operator-skill-parity: extra-slash variant target is rejected" "$o" "FAIL invalid variant target: m1/alpha/extra"
o="$(osp_run "$D13" "" "m1=$D13/m1/skills" "" "m1/alpha=canonical/alpha/extra")"; rc=$?
assert_eq       "operator-skill-parity: extra-slash variant source exits 1" 1 "$rc"
assert_contains "operator-skill-parity: extra-slash variant source is rejected" "$o" "FAIL invalid variant source: canonical/alpha/extra"
rm -rf "$D13"

# A target can have exactly one case-sensitive mapping. Do not choose the first
# pair (Bash) or overwrite it with the last pair (PowerShell).
D14="$(mktemp -d)"; osp_fixture "$D14"
o="$(osp_run "$D14" "" "target=$D14/m1/skills,good=$D14/m2/skills" "" "target/alpha=good/alpha,target/alpha=canonical/alpha")"; rc=$?
assert_eq       "operator-skill-parity: duplicate variant target exits 1" 1 "$rc"
assert_contains "operator-skill-parity: duplicate variant target fails loudly" "$o" "FAIL duplicate variant target: target/alpha"
rm -rf "$D14"

# A literal self-pair would make the comparison vacuous before it reaches the
# filesystem. It must fail in both twins.
D15="$(mktemp -d)"; osp_fixture "$D15"
o="$(osp_run "$D15" "" "target=$D15/m1/skills" "" "target/alpha=target/alpha")"; rc=$?
assert_eq       "operator-skill-parity: literal self-pair exits 1" 1 "$rc"
assert_contains "operator-skill-parity: literal self-pair fails loudly" "$o" "FAIL variant source matches target: target/alpha"
rm -rf "$D15"

# A different label may still lead to the same skill directory through a link.
# That comparison is equally vacuous and must not mask canonical drift.
D16="$(mktemp -d)"; osp_fixture "$D16"
printf 'alias-only copy\n' > "$D16/m1/skills/alpha/SKILL.md"
mkdir -p "$D16/source/skills"
ln -s "$D16/m1/skills/alpha" "$D16/source/skills/alpha"
o="$(osp_run "$D16" "" "target=$D16/m1/skills,source=$D16/source/skills" "" "target/alpha=source/alpha")"; rc=$?
assert_eq       "operator-skill-parity: physical self-alias exits 1" 1 "$rc"
assert_contains "operator-skill-parity: physical self-alias fails loudly" "$o" "FAIL variant source aliases target: target/alpha = source/alpha"
rm -rf "$D16"

# Separate labels can directly name the same directory without a symlink.
D17="$(mktemp -d)"; osp_fixture "$D17"
o="$(osp_run "$D17" "" "target=$D17/m1/skills,source=$D17/m1/skills" "" "target/alpha=source/alpha")"; rc=$?
assert_eq       "operator-skill-parity: direct physical self-alias exits 1" 1 "$rc"
assert_contains "operator-skill-parity: direct physical self-alias fails loudly" "$o" "FAIL variant source aliases target: target/alpha = source/alpha"
rm -rf "$D17"

# A symlinked mirror root has the same physical target as the direct root.
D18="$(mktemp -d)"; osp_fixture "$D18"
printf 'alias-only copy\n' > "$D18/m1/skills/alpha/SKILL.md"
ln -s "$D18/m1/skills" "$D18/source-skills"
o="$(osp_run "$D18" "" "target=$D18/m1/skills,source=$D18/source-skills" "" "target/alpha=source/alpha")"; rc=$?
assert_eq       "operator-skill-parity: symlink-root self-alias exits 1" 1 "$rc"
assert_contains "operator-skill-parity: symlink-root self-alias fails loudly" "$o" "FAIL variant source aliases target: target/alpha = source/alpha"
rm -rf "$D18"

# Pair keys are case-sensitive in both twins. These distinct labels must not be
# misread as a duplicate mapping during configuration parsing.
D19="$(mktemp -d)"; osp_fixture "$D19"
o="$(osp_run "$D19" "" "lower=$D19/m1/skills,Lower=$D19/m2/skills" "" "lower/alpha=canonical/alpha,Lower/alpha=canonical/alpha")"; rc=$?
assert_eq       "operator-skill-parity: case-distinct variant targets exit 0" 0 "$rc"
assert_contains "operator-skill-parity: case-distinct variant targets PASS" "$o" "PASS operator-skill parity"
rm -rf "$D19"

# Mirror labels are case-sensitive. An uppercase Hermes label is ordinary and
# must compare the full canonical roster instead of taking the Hermes subset.
D20="$(mktemp -d)"; osp_fixture "$D20"
printf 'uppercase label drift\n' > "$D20/m2/skills/alpha/SKILL.md"
o="$(osp_run "$D20" "" "m1=$D20/m1/skills,Hermes=$D20/m2/skills")"; rc=$?
assert_eq       "operator-skill-parity: uppercase Hermes label detects drift" 1 "$rc"
assert_contains "operator-skill-parity: uppercase Hermes label is ordinary mirror" "$o" "DRIFT   Hermes   alpha"
rm -rf "$D20"

# A missing Hermes root must stay failed when an empty canonical root leaves no
# comparisons. The no-work result cannot overwrite an accumulated failure.
D21="$(mktemp -d)"; osp_map "$D21"
mkdir -p "$D21/canonical" "$D21/m1/skills"
o="$(env AI_CONFIG_LOCAL_ENV="$D21/no-such-local.env" \
    SKILL_PARITY_CANONICAL="$D21/canonical" \
    SKILL_PARITY_MIRRORS="m1=$D21/m1/skills,hermes=$D21/absent-hermes/skills" \
    SKILL_PARITY_CAPABILITY_MAP="$D21/Capability Map.md" \
    SKILL_PARITY_VARIANTS="" \
    bash "$OSP" 2>&1)"; rc=$?
assert_eq       "operator-skill-parity: missing Hermes plus no-work exits 1" 1 "$rc"
assert_contains "operator-skill-parity: missing Hermes plus no-work FAILs" "$o" "FAIL Hermes skill root missing: $D21/absent-hermes/skills"
rm -rf "$D21"

# The Capability Map is required for the exact lowercase Hermes label. A
# missing map must fail, while a real map and in-sync subset pass.
D22="$(mktemp -d)"; osp_fixture "$D22"
mkdir -p "$D22/hermes/skills/alpha"
printf 'alpha body\n' > "$D22/hermes/skills/alpha/SKILL.md"
o="$(osp_run "$D22" "" "m1=$D22/m1/skills,hermes=$D22/hermes/skills" "$D22/missing-map.md")"; rc=$?
assert_eq       "operator-skill-parity: missing Hermes map exits 1" 1 "$rc"
assert_contains "operator-skill-parity: missing Hermes map fails loudly" "$o" "FAIL Hermes Capability Map missing"
osp_map "$D22"
o="$(osp_run "$D22" "" "m1=$D22/m1/skills,hermes=$D22/hermes/skills" "$D22/Capability Map.md")"; rc=$?
assert_eq       "operator-skill-parity: present Hermes map positive control exits 0" 0 "$rc"
assert_contains "operator-skill-parity: present Hermes map reports subset count" "$o" "NOTE   Hermes expected subset: 2 skill(s)"
rm -rf "$D22"

# A readable table with no Hermes/all skill rows is also a failure. A populated
# table is the paired control above, so this cannot pass by skipping the parser.
D23="$(mktemp -d)"; osp_fixture "$D23"
mkdir -p "$D23/hermes/skills"
printf '%s\n' '| Skill | What | Where |' '| --- | --- | --- |' '| `beta` | other harnesses | codex |' > "$D23/Capability Map.md"
o="$(osp_run "$D23" "" "m1=$D23/m1/skills,hermes=$D23/hermes/skills" "$D23/Capability Map.md")"; rc=$?
assert_eq       "operator-skill-parity: empty Hermes expected subset exits 1" 1 "$rc"
assert_contains "operator-skill-parity: empty Hermes expected subset fails loudly" "$o" "FAIL Hermes Capability Map has no expected skills"
rm -rf "$D23"

# Variant labels must resolve to canonical or an exact configured mirror label.
D24="$(mktemp -d)"; osp_fixture "$D24"
o="$(osp_run "$D24" "" "m1=$D24/m1/skills" "" "m1/alpha=unknown/alpha")"; rc=$?
assert_eq       "operator-skill-parity: unknown variant source label exits 1" 1 "$rc"
assert_contains "operator-skill-parity: unknown variant source label fails loudly" "$o" "FAIL variant source missing: unknown/alpha"
o="$(osp_run "$D24" "" "m1=$D24/m1/skills" "" "m1/alpha=canonical/alpha")"; rc=$?
assert_eq       "operator-skill-parity: known variant source positive control exits 0" 0 "$rc"
assert_contains "operator-skill-parity: known variant source is compared" "$o" "VARIANT m1       alpha (matched canonical/alpha)"
rm -rf "$D24"

# Every map skill must have a canonical source before Hermes can compare it.
D25="$(mktemp -d)"; osp_fixture "$D25"
mkdir -p "$D25/hermes/skills/gamma"
printf 'gamma body\n' > "$D25/hermes/skills/gamma/SKILL.md"
printf '%s\n' '| Skill | What | Where |' '| --- | --- | --- |' '| `gamma` | missing canonical source | hermes |' > "$D25/Capability Map.md"
o="$(osp_run "$D25" "" "m1=$D25/m1/skills,hermes=$D25/hermes/skills" "$D25/Capability Map.md")"; rc=$?
assert_eq       "operator-skill-parity: map skill absent from canonical exits 1" 1 "$rc"
assert_contains "operator-skill-parity: map skill absent from canonical is reported" "$o" "MISSING canonical gamma"
for root in "$D25/home a/skills" "$D25/m1/skills" "$D25/m2/skills"; do
  mkdir -p "$root/gamma"
  printf 'gamma body\n' > "$root/gamma/SKILL.md"
done
o="$(osp_run "$D25" "" "m1=$D25/m1/skills,m2=$D25/m2/skills,hermes=$D25/hermes/skills" "$D25/Capability Map.md")"; rc=$?
assert_eq       "operator-skill-parity: canonical map skill recovery exits 0" 0 "$rc"
assert_contains "operator-skill-parity: canonical map skill recovery preserves count" "$o" "7 comparison(s) across 3 of 3 mirror root(s)"
rm -rf "$D25"

# A two-column map with an omitted final pipe and aligned separator accepts the
# minimum schema in both twins. Literal mixed-case/punctuated names also work.
# The report count is contractual; diagnostic-line order is not.
D26="$(mktemp -d)"; osp_fixture "$D26"; osp_two_column_map "$D26" no
mkdir -p "$D26/hermes/skills/alpha"
printf 'alpha body\n' > "$D26/hermes/skills/alpha/SKILL.md"
for skill in 'Alpha-1' 'zeta_2'; do
  for root in "$D26/home a/skills" "$D26/m1/skills" "$D26/m2/skills"; do
    mkdir -p "$root/$skill"
    printf '%s body\n' "$skill" > "$root/$skill/SKILL.md"
  done
done
o="$(osp_run "$D26" "" "m1=$D26/m1/skills,m2=$D26/m2/skills,hermes=$D26/hermes/skills" "$D26/Capability Map.md")"; rc=$?
assert_eq       "operator-skill-parity: mixed-case punctuated skills exit 0" 0 "$rc"
assert_contains "operator-skill-parity: two-column omitted final pipe loads Hermes subset" "$o" "NOTE   Hermes expected subset: 2 skill(s)"
assert_contains "operator-skill-parity: mixed-case punctuated skills preserve count" "$o" "9 comparison(s) across 3 of 3 mirror root(s)"
osp_two_column_map "$D26" yes
o="$(osp_run "$D26" "" "m1=$D26/m1/skills,m2=$D26/m2/skills,hermes=$D26/hermes/skills" "$D26/Capability Map.md")"; rc=$?
assert_eq       "operator-skill-parity: two-column final pipe exits 0" 0 "$rc"
assert_contains "operator-skill-parity: two-column final pipe preserves count" "$o" "9 comparison(s) across 3 of 3 mirror root(s)"
printf 'Alpha-1 changed\n' > "$D26/m2/skills/Alpha-1/SKILL.md"
o="$(osp_run "$D26" "" "m1=$D26/m1/skills,m2=$D26/m2/skills,hermes=$D26/hermes/skills" "$D26/Capability Map.md")"; rc=$?
assert_eq       "operator-skill-parity: mixed-case punctuated drift exits 1" 1 "$rc"
assert_contains "operator-skill-parity: mixed-case punctuated drift names literal skill" "$o" "DRIFT   m2       Alpha-1"
rm -rf "$D26"
