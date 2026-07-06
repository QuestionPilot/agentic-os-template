#!/usr/bin/env bash
# tests/skills-overlay.test.sh — Exercises the operator-skills-overlay
# splice in install.sh's compile_entrypoint across the scenarios the Codex
# adversarial review flagged, plus the happy path:
# 1. overlay present → content spliced, marker consumed
# 2. set-but-missing → warns + exits 0 + spine-only (Codex F2)
# 3. marker in overlay → neutralized, no "resolves empty" die (Codex F3)
# 4. @@VAR@@ in overlay → resolved (splice precedes the @@VAR@@ loop)
# Mirrored by tests/skills-overlay.test.ps1 (twin-parity: each runner globs only
# its own extension, so per-file assertions must live in BOTH twins). Build the
# marker from halves so this source isn't a stray second literal copy.

SO_DIR="$(mktemp -d)"
SO_TGT="$SO_DIR/cfg"
SO_FIXTURE="$REPO_ROOT/tests/fixtures/ci.local.env"
SO_MARK="@@OPERATOR_SKILLS""_OVERLAY@@"

# _so_build <overlay-path-or-empty> → echoes "<exit-status>|<build-dir>"; stderr
# of the install run is captured to $SO_DIR/stderr.
_so_build() {
  local overlay_path="$1" env_file="$SO_DIR/local.env" status=0 out
  { cat "$SO_FIXTURE"
    printf '\nCLAUDE_CONFIG_DIR=%q\n' "$SO_TGT"
    [ -n "$overlay_path" ] && printf 'SKILLS_OVERLAY_PATH=%q\n' "$overlay_path"
  } > "$env_file"
  out="$(AI_CONFIG_LOCAL_ENV="$env_file" bash "$REPO_ROOT/scripts/install.sh" \
    --harness claude --build-only 2>"$SO_DIR/stderr")" || status=$?
  printf '%s|%s' "$status" "$out"
}

_so_marker_count() { grep -cF "$SO_MARK" "$1" 2>/dev/null || true; }

# 1. Happy path — overlay present.
SO_OV1="$SO_DIR/overlay-ok.md"
printf '### Operator routing\n\nSENTINEL_OVERLAY_ROW here\n' > "$SO_OV1"
_res="$(_so_build "$SO_OV1")"; _st="${_res%%|*}"; _bd="${_res#*|}"
assert_eq "overlay: present render exits 0" "0" "$_st"
if [ -f "$_bd/SKILLS.md" ]; then
  assert_contains "overlay: spliced content appears in rendered SKILLS.md" \
    "$(cat "$_bd/SKILLS.md")" "SENTINEL_OVERLAY_ROW"
  assert_eq "overlay: marker consumed in present render (0 left)" "0" "$(_so_marker_count "$_bd/SKILLS.md")"
else
  _fail "overlay: present build produced a SKILLS.md" "no SKILLS.md under [$_bd]"
fi
[ -n "$_bd" ] && rm -rf "$_bd"

# 2. Codex F2 — SET-but-missing path: warn + exit 0 + spine-only.
_res="$(_so_build "$SO_DIR/nope-not-here.md")"; _st="${_res%%|*}"; _bd="${_res#*|}"
assert_eq "overlay: set-but-missing render still exits 0 (spine-only fallback)" "0" "$_st"
assert_contains "overlay: set-but-missing warns on stderr" \
  "$(cat "$SO_DIR/stderr")" "is set but the file does not exist"
[ -f "$_bd/SKILLS.md" ] \
  && assert_eq "overlay: set-but-missing leaves no marker in output" "0" "$(_so_marker_count "$_bd/SKILLS.md")"
[ -n "$_bd" ] && rm -rf "$_bd"

# 3. Codex F3 — overlay re-introduces the marker: neutralized, no die.
SO_OV3="$SO_DIR/overlay-marker.md"
printf 'note: operators splice this at the %s marker.\n' "$SO_MARK" > "$SO_OV3"
_res="$(_so_build "$SO_OV3")"; _st="${_res%%|*}"; _bd="${_res#*|}"
assert_eq "overlay: marker-in-overlay render exits 0 (no resolves-empty die)" "0" "$_st"
[ -f "$_bd/SKILLS.md" ] \
  && assert_eq "overlay: marker-in-overlay neutralized (0 markers left)" "0" "$(_so_marker_count "$_bd/SKILLS.md")"
[ -n "$_bd" ] && rm -rf "$_bd"

# 4. @@VAR@@ inside the overlay resolves (splice precedes the @@VAR@@ loop).
SO_OV4="$SO_DIR/overlay-token.md"
printf 'see @@AI_CONFIG_DIR@@/skills/skill-authoring.md\n' > "$SO_OV4"
_res="$(_so_build "$SO_OV4")"; _st="${_res%%|*}"; _bd="${_res#*|}"
assert_eq "overlay: path-token-in-overlay render exits 0" "0" "$_st"
if [ -f "$_bd/SKILLS.md" ]; then
  _tok_n="$(grep -cF '@@AI_CONFIG_DIR@@' "$_bd/SKILLS.md" 2>/dev/null || true)"
  assert_eq "overlay: @@AI_CONFIG_DIR@@ inside overlay resolved (0 literal left)" "0" "$_tok_n"
fi
[ -n "$_bd" ] && rm -rf "$_bd"

# 5. Cross-overlay collision (the SEVERE leak case): a claude render with the skills
# overlay carrying the codex-rules marker AND CODEX_RULES_OVERLAY_PATH set must NOT
# splice codex rules into this claude SKILLS.md. Before the cross-overlay fix the
# surviving marker made the later codex-rules branch fire on post-splice content and
# leak the codex payload here. Marker built from halves so this source isn't a stray
# copy. Build a bespoke env (the _so_build helper sets only SKILLS_OVERLAY_PATH).
SO_CXMARK="@@OPERATOR_CODEX_RULES""_OVERLAY@@"
SO_OV5="$SO_DIR/overlay-codex-marker.md"
printf 'operator note mentioning the %s marker.\n' "$SO_CXMARK" > "$SO_OV5"
SO_CXPAY="$SO_DIR/codex-payload.md"
printf 'CODEX_LEAK_SENTINEL must never reach a claude SKILLS.md\n' > "$SO_CXPAY"
SO_ENV5="$SO_DIR/local.env"
{ cat "$SO_FIXTURE"
  printf '\nCLAUDE_CONFIG_DIR=%q\n' "$SO_TGT"
  printf 'SKILLS_OVERLAY_PATH=%q\n' "$SO_OV5"
  printf 'CODEX_RULES_OVERLAY_PATH=%q\n' "$SO_CXPAY"
} > "$SO_ENV5"
_st5=0
_bd="$(AI_CONFIG_LOCAL_ENV="$SO_ENV5" bash "$REPO_ROOT/scripts/install.sh" \
  --harness claude --build-only 2>/dev/null)" || _st5=$?
assert_eq "overlay: claude render with cross-overlay marker + codex path set exits 0" "0" "$_st5"
if [ -f "$_bd/SKILLS.md" ]; then
  assert_not_contains "overlay: codex rules do NOT leak into claude SKILLS.md (cross-overlay)" \
    "$(cat "$_bd/SKILLS.md")" "CODEX_LEAK_SENTINEL"
  assert_eq "overlay: cross-overlay codex-rules marker neutralized (0 left in SKILLS.md)" \
    "0" "$(grep -cF "$SO_CXMARK" "$_bd/SKILLS.md" 2>/dev/null || true)"
fi
[ -n "$_bd" ] && rm -rf "$_bd"

# 6. Catalog-honesty warn: a skill dir living in the live target but absent from
# the rendered SKILLS.md draws an advisory stderr warn on a FULL install — the
# install still exits 0 (warn-not-fail contract) and the warn names both the
# offending dir and the overlay fix.
CH_DIR="$(mktemp -d)"
CH_TGT="$CH_DIR/cfg"
mkdir -p "$CH_TGT/skills/mystery-operator-skill" "$CH_TGT/skills/zz aa"
printf '# operator skill\n' > "$CH_TGT/skills/mystery-operator-skill/SKILL.md"
printf '# spaced-name skill\n' > "$CH_TGT/skills/zz aa/SKILL.md"
CH_ENV="$CH_DIR/local.env"
make_local_env "$CH_ENV" "$CH_TGT" "$CH_DIR/vault"
ch_status=0
AI_CONFIG_LOCAL_ENV="$CH_ENV" bash "$REPO_ROOT/scripts/install.sh" \
  --harness claude >/dev/null 2>"$CH_DIR/stderr" || ch_status=$?
assert_eq "catalog-warn: install with an uncataloged skill dir still exits 0" "0" "$ch_status"
assert_contains "catalog-warn: warn names the uncataloged skill dir" \
  "$(cat "$CH_DIR/stderr")" "mystery-operator-skill"
# A skill dir named with a space reports as ONE skill (array accumulator, no
# word-splitting). "zz aa" is chosen so its halves would NOT sort adjacent if
# split — pre-fix output ("aa … zz") cannot contain the substring by accident.
assert_contains "catalog-warn: spaced skill-dir name reports as one skill" \
  "$(cat "$CH_DIR/stderr")" "zz aa"
assert_contains "catalog-warn: warn names the overlay fix" \
  "$(cat "$CH_DIR/stderr")" "SKILLS_OVERLAY_PATH"
# Spine skills are cataloged by the generated table — they must NOT be flagged.
ch_warnline="$(grep 'absent from the rendered SKILLS.md catalog' "$CH_DIR/stderr" || true)"
assert_not_contains "catalog-warn: cataloged spine skill draws no warn" \
  "$ch_warnline" "session-agent"
rm -rf "$CH_DIR"

# 7. Catalog-honesty warn suppressed when the overlay lists the skill: the same
# uncataloged dir plus an overlay row naming it backticked renders warn-free.
CQ_DIR="$(mktemp -d)"
CQ_TGT="$CQ_DIR/cfg"
mkdir -p "$CQ_TGT/skills/mystery-operator-skill"
printf '# operator skill\n' > "$CQ_TGT/skills/mystery-operator-skill/SKILL.md"
CQ_OV="$CQ_DIR/overlay.md"
printf '### Operator skills\n\n| `mystery-operator-skill` | test row |\n' > "$CQ_OV"
CQ_ENV="$CQ_DIR/local.env"
{ make_local_env "$CQ_ENV" "$CQ_TGT" "$CQ_DIR/vault"
  printf 'SKILLS_OVERLAY_PATH=%q\n' "$CQ_OV" >> "$CQ_ENV"
}
cq_status=0
AI_CONFIG_LOCAL_ENV="$CQ_ENV" bash "$REPO_ROOT/scripts/install.sh" \
  --harness claude >/dev/null 2>"$CQ_DIR/stderr" || cq_status=$?
assert_eq "catalog-warn: overlay-listed skill install exits 0" "0" "$cq_status"
assert_not_contains "catalog-warn: overlay-listed skill draws no warn" \
  "$(cat "$CQ_DIR/stderr")" "absent from the rendered SKILLS.md catalog"
rm -rf "$CQ_DIR"

rm -rf "$SO_DIR"
