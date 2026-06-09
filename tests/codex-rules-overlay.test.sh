#!/usr/bin/env bash
# tests/codex-rules-overlay.test.sh — exercises the operator-rules overlay splice
# for the codex AGENTS template in install.sh's compile_entrypoint, plus the
# spine-only template-source invariants.
#
# Replaces the former context7-rule.test.sh. A ctx7 doc-fetch block used to ship
# INSIDE harnesses/codex/AGENTS.template.md (a spine-only breach, allowlisted in
# spine-only.test). It now lives in an operator-local overlay spliced at
# @@OPERATOR_CODEX_RULES_OVERLAY@@, so this FRAMEWORK test guards the GENERIC
# overlay mechanism (any operator tool-policy block), not one tool specifically —
# a tool's own round-trip is now an operator-side concern. Twin of the SKILLS
# overlay (tests/skills-overlay.test.sh); Codex has no auto-loaded rules/ dir, so
# operator rules must land in the rendered AGENTS.md rather than a sidecar.
#
# Scenarios mirror skills-overlay.test.sh:
# 1. overlay present → content spliced, @@VAR@@ inside it resolves, marker consumed
# 2. overlay unset   → spine-only AGENTS.md (no content, marker consumed)
# 3. set-but-missing → warns + exits 0 + spine-only
# 4. marker in overlay → neutralized, no "resolves empty" die
# plus the template-source invariants + a full-install drift gate.
#
# Test files are SOURCED by tests/run.sh — do NOT `exit`, do NOT re-source lib.sh,
# do NOT set -e. Just call assert_*.

CRO_TEMPLATE="$REPO_ROOT/harnesses/codex/AGENTS.template.md"
# Build the marker from halves so this source isn't a stray second literal copy.
CRO_MARK="@@OPERATOR_CODEX_RULES""_OVERLAY@@"

# --- Template source: spine-only + carries the marker exactly once -----------
assert_file "codex AGENTS template exists" "$CRO_TEMPLATE"
assert_eq "codex template carries the operator-rules overlay marker exactly once" \
  "1" "$(grep -cF "$CRO_MARK" "$CRO_TEMPLATE")"
# The relocated ctx7 block must be GONE — zero ctx7/context7 in shipped content.
# Pattern built from halves so this test source doesn't trip the spine-only audit.
_cro_c7="con""text7"; _cro_cx="ct""x7"
assert_eq "codex template ships no ctx7/context7 (relocated to operator overlay)" \
  "0" "$(grep -ciE "$_cro_c7|$_cro_cx" "$CRO_TEMPLATE" || true)"

# --- Render machinery: shared driver mirroring skills-overlay.test.sh --------
CRO_DIR="$(mktemp -d)"
CRO_TGT="$CRO_DIR/codex-home"
CRO_FIXTURE="$REPO_ROOT/tests/fixtures/ci.local.env"

# _cro_build <overlay-path-or-empty> → echoes "<exit-status>|<build-dir>"; the
# install run's stderr is captured to $CRO_DIR/stderr.
_cro_build() {
  local overlay_path="$1" env_file="$CRO_DIR/local.env" status=0 out
  { cat "$CRO_FIXTURE"
    printf '\nCODEX_HOME=%q\n' "$CRO_TGT"
    [ -n "$overlay_path" ] && printf 'CODEX_RULES_OVERLAY_PATH=%q\n' "$overlay_path"
  } > "$env_file"
  out="$(AI_CONFIG_LOCAL_ENV="$env_file" bash "$REPO_ROOT/scripts/install.sh" \
    --harness codex --build-only 2>"$CRO_DIR/stderr")" || status=$?
  printf '%s|%s' "$status" "$out"
}
_cro_marker_count() { grep -cF "$CRO_MARK" "$1" 2>/dev/null || true; }

# 1. Happy path — overlay present: content spliced, path token resolves, marker consumed.
CRO_OV1="$CRO_DIR/overlay-ok.md"
printf '<!-- op-rule -->\nOperator rule: consult @@AI_CONFIG_DIR@@/README.md first.\nSENTINEL_CRO_ROW\n' > "$CRO_OV1"
_res="$(_cro_build "$CRO_OV1")"; _st="${_res%%|*}"; _bd="${_res#*|}"
assert_eq "codex overlay: present render exits 0" "0" "$_st"
if [ -f "$_bd/AGENTS.md" ]; then
  _built="$(cat "$_bd/AGENTS.md")"
  assert_contains "codex overlay: spliced content appears in rendered AGENTS.md" "$_built" "SENTINEL_CRO_ROW"
  assert_not_contains "codex overlay: @@VAR@@ inside the overlay resolved (no literal left)" "$_built" "@@AI_CONFIG_DIR@@"
  assert_eq "codex overlay: marker consumed in present render (0 left)" "0" "$(_cro_marker_count "$_bd/AGENTS.md")"
else
  _fail "codex overlay: present build produced an AGENTS.md" "no AGENTS.md under [$_bd]"
fi
[ -n "$_bd" ] && rm -rf "$_bd"

# 2. Overlay UNSET → spine-only AGENTS.md (no overlay content, marker consumed).
_res="$(_cro_build "")"; _st="${_res%%|*}"; _bd="${_res#*|}"
assert_eq "codex overlay: unset render exits 0 (spine-only)" "0" "$_st"
if [ -f "$_bd/AGENTS.md" ]; then
  _built="$(cat "$_bd/AGENTS.md")"
  assert_not_contains "codex overlay: unset render carries no overlay sentinel" "$_built" "SENTINEL_CRO_ROW"
  assert_eq "codex overlay: marker consumed in spine-only render (0 left)" "0" "$(_cro_marker_count "$_bd/AGENTS.md")"
fi
[ -n "$_bd" ] && rm -rf "$_bd"

# 3. SET-but-missing → warns on stderr + still exits 0 + spine-only (mirror SKILLS F2).
_res="$(_cro_build "$CRO_DIR/nope-not-here.md")"; _st="${_res%%|*}"; _bd="${_res#*|}"
assert_eq "codex overlay: set-but-missing render still exits 0 (spine-only fallback)" "0" "$_st"
assert_contains "codex overlay: set-but-missing warns on stderr" \
  "$(cat "$CRO_DIR/stderr")" "is set but the file does not exist"
[ -n "$_bd" ] && rm -rf "$_bd"

# 4. Overlay re-introduces the marker → neutralized, no resolves-empty die (mirror SKILLS F3).
CRO_OV4="$CRO_DIR/overlay-marker.md"
printf 'operators splice at the %s marker.\n' "$CRO_MARK" > "$CRO_OV4"
_res="$(_cro_build "$CRO_OV4")"; _st="${_res%%|*}"; _bd="${_res#*|}"
assert_eq "codex overlay: marker-in-overlay render exits 0 (no resolves-empty die)" "0" "$_st"
[ -f "$_bd/AGENTS.md" ] \
  && assert_eq "codex overlay: marker-in-overlay neutralized (0 markers left)" "0" "$(_cro_marker_count "$_bd/AGENTS.md")"
[ -n "$_bd" ] && rm -rf "$_bd"

# 5. Cross-overlay collision: the codex overlay carries the OTHER overlay's marker
# (the SKILLS marker). It must be neutralized, NOT survive into the @@VAR@@ loop and
# die "resolves empty" (the skills branch can't consume it — the AGENTS template
# never carried it). Marker built from halves so this source isn't a stray copy.
CRO_SKMARK="@@OPERATOR_SKILLS""_OVERLAY@@"
CRO_OV5="$CRO_DIR/overlay-skills-marker.md"
printf 'operator note mentioning the %s marker.\n' "$CRO_SKMARK" > "$CRO_OV5"
_res="$(_cro_build "$CRO_OV5")"; _st="${_res%%|*}"; _bd="${_res#*|}"
assert_eq "codex overlay: codex overlay carrying the SKILLS marker still renders (no resolves-empty die)" "0" "$_st"
[ -f "$_bd/AGENTS.md" ] \
  && assert_eq "codex overlay: cross-overlay SKILLS marker neutralized (0 left in AGENTS.md)" \
    "0" "$(grep -cF "$CRO_SKMARK" "$_bd/AGENTS.md" 2>/dev/null || true)"
[ -n "$_bd" ] && rm -rf "$_bd"

# --- Drift gate: a full spine-only install round-trips clean -----------------
CRO_FI_DIR="$(mktemp -d)"
CRO_FI_TGT="$CRO_FI_DIR/codex-home"
CRO_FI_ENV="$CRO_FI_DIR/local.env"
make_codex_env "$CRO_FI_ENV" "$CRO_FI_TGT"
AI_CONFIG_LOCAL_ENV="$CRO_FI_ENV" bash "$REPO_ROOT/scripts/install.sh" --harness codex >/dev/null 2>&1
assert_exit "codex full install (spine-only overlay) passes drift check" 0 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$CRO_FI_TGT"
rm -rf "$CRO_FI_DIR"

rm -rf "$CRO_DIR"
