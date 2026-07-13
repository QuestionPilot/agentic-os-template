#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/install-multi-harness.test.sh — install.sh repeatable --harness.
#
# Regression for the scalar-vs-list bug: `--harness` was parsed last-wins, so the
# DOCUMENTED `bash scripts/install.sh --harness claude --harness codex` (asserted
# present in the entrypoints by entrypoint-deps.test.sh, and claimed to install
# "Both harnesses... in one pass") silently built ONLY codex — a half-synced
# machine with no error. The fix makes --harness repeatable: every requested
# harness builds in one pass via a per-harness re-exec dispatcher.
#
# The bash twin builds BOTH claude and codex. The PowerShell twin's asymmetry
# (codex WARN-skipped on Windows) is covered by install-multi-harness.test.ps1.

# A local.env that resolves BOTH harness targets + the vault path the entrypoint
# templates reference. %q quotes the values so a path with a space/'&' round-trips
# through install.sh's `. local.env`.
_mh_dual_env() {
  { printf 'CLAUDE_CONFIG_DIR=%q\n' "$2"
    printf 'CODEX_HOME=%q\n'        "$3"
    printf 'OBSIDIAN_VAULT_PATH=%q\n' "${4:-/tmp/test-vault}"
  } > "$1"
}

# --- 1. The core fix: `--harness claude --harness codex` builds BOTH ---------
MH_DIR="$(mktemp -d)"
MH_CC="$MH_DIR/claude"; MH_CX="$MH_DIR/codex"; mkdir -p "$MH_CC" "$MH_CX"
MH_ENV="$MH_DIR/local.env"
_mh_dual_env "$MH_ENV" "$MH_CC" "$MH_CX" "$MH_DIR/vault"

mh_status=0
AI_CONFIG_LOCAL_ENV="$MH_ENV" bash "$REPO_ROOT/scripts/install.sh" \
  --harness claude --harness codex >/dev/null 2>&1 || mh_status=$?
assert_eq "install.sh --harness claude --harness codex exits 0" "0" "$mh_status"
# The regression guard: pre-fix this file was ABSENT (last-wins built only codex).
assert_file "two-harness install builds the claude entrypoint (regression)" "$MH_CC/CLAUDE.md"
assert_file "two-harness install builds a claude skill"                      "$MH_CC/skills/session-agent/SKILL.md"
assert_file "two-harness install builds the codex entrypoint"                "$MH_CX/AGENTS.md"
assert_file "two-harness install builds a codex skill"                       "$MH_CX/skills/session-agent/SKILL.md"
# Each harness landed in its OWN target (no cross-contamination).
[ -e "$MH_CC/AGENTS.md" ] \
  && _fail "claude target has no codex entrypoint" "AGENTS.md leaked into CLAUDE_CONFIG_DIR" \
  || _pass "claude target has no codex entrypoint"
[ -e "$MH_CX/CLAUDE.md" ] \
  && _fail "codex target has no claude entrypoint" "CLAUDE.md leaked into CODEX_HOME" \
  || _pass "codex target has no claude entrypoint"
rm -rf "$MH_DIR"

# --- 2. Order independence: codex first still builds both --------------------
OI_DIR="$(mktemp -d)"
OI_CC="$OI_DIR/claude"; OI_CX="$OI_DIR/codex"; mkdir -p "$OI_CC" "$OI_CX"
OI_ENV="$OI_DIR/local.env"
_mh_dual_env "$OI_ENV" "$OI_CC" "$OI_CX" "$OI_DIR/vault"
oi_status=0
AI_CONFIG_LOCAL_ENV="$OI_ENV" bash "$REPO_ROOT/scripts/install.sh" \
  --harness codex --harness claude >/dev/null 2>&1 || oi_status=$?
assert_eq "install.sh --harness codex --harness claude exits 0" "0" "$oi_status"
assert_file "reversed order still builds the claude entrypoint" "$OI_CC/CLAUDE.md"
assert_file "reversed order still builds the codex entrypoint"  "$OI_CX/AGENTS.md"
rm -rf "$OI_DIR"

# --- 3. Dedup: a repeated harness builds once, succeeds ----------------------
DD_DIR="$(mktemp -d)"
DD_CC="$DD_DIR/claude"; mkdir -p "$DD_CC"
DD_ENV="$DD_DIR/local.env"
make_local_env "$DD_ENV" "$DD_CC" "$DD_DIR/vault"
dd_status=0
AI_CONFIG_LOCAL_ENV="$DD_ENV" bash "$REPO_ROOT/scripts/install.sh" \
  --harness claude --harness claude >/dev/null 2>&1 || dd_status=$?
assert_eq "install.sh --harness claude --harness claude (dedup) exits 0" "0" "$dd_status"
assert_file "deduped repeat builds the claude entrypoint" "$DD_CC/CLAUDE.md"
rm -rf "$DD_DIR"

# --- 4. --out cannot target multiple harnesses ------------------------------
# Each harness has its own target dir, so --out (a single override) is ambiguous
# with >1 harness and must fail loudly rather than build both into one dir.
OC_DIR="$(mktemp -d)"
OC_CC="$OC_DIR/claude"; OC_CX="$OC_DIR/codex"; mkdir -p "$OC_CC" "$OC_CX"
OC_ENV="$OC_DIR/local.env"
_mh_dual_env "$OC_ENV" "$OC_CC" "$OC_CX" "$OC_DIR/vault"
oc_status=0
oc_out="$(AI_CONFIG_LOCAL_ENV="$OC_ENV" bash "$REPO_ROOT/scripts/install.sh" \
  --harness claude --harness codex --out "$OC_DIR/tgt" 2>&1 >/dev/null)" || oc_status=$?
assert_eq "install.sh --out + multiple --harness exits 1" "1" "$oc_status"
assert_contains "install.sh --out + multiple --harness names the conflict" "$oc_out" "--out"
# The conflict must fire BEFORE any build — the --out target stays uncreated.
[ -e "$OC_DIR/tgt" ] \
  && _fail "--out + multi-harness conflict makes no partial build" "$OC_DIR/tgt was created" \
  || _pass "--out + multi-harness conflict makes no partial build"
rm -rf "$OC_DIR"

# --- 5. Single --harness still builds exactly that harness (no regression) ---
# Guards against the dispatcher accidentally firing for a single harness.
SG_DIR="$(mktemp -d)"
SG_CX="$SG_DIR/codex"; mkdir -p "$SG_CX"
SG_ENV="$SG_DIR/local.env"
make_codex_env "$SG_ENV" "$SG_CX" "$SG_DIR/vault"
sg_status=0
AI_CONFIG_LOCAL_ENV="$SG_ENV" bash "$REPO_ROOT/scripts/install.sh" \
  --harness codex >/dev/null 2>&1 || sg_status=$?
assert_eq "single install.sh --harness codex exits 0" "0" "$sg_status"
assert_file "single --harness codex builds AGENTS.md" "$SG_CX/AGENTS.md"
[ -e "$SG_CX/CLAUDE.md" ] \
  && _fail "single codex install builds no claude entrypoint" "CLAUDE.md present in a codex-only install" \
  || _pass "single codex install builds no claude entrypoint"
rm -rf "$SG_DIR"

# --- 6. Preflight: a missing second-harness target aborts BEFORE any mutation -
# The dispatcher must validate every requested harness (name / adapter / target
# env var) up front. Otherwise harness 1 swaps its live config, harness 2 dies
# on its unset target, and the operator is left with a half-synced machine + a
# non-zero exit. CODEX_HOME must be GENUINELY unset for this — `env -u CODEX_HOME`
# strips it from the ambient env, not just from the fixture local.env. Without
# that, a run from the operator's co-located folder (where ~/.zshenv exports
# CODEX_HOME=<repo>/.codex) would let the inherited value satisfy the preflight
# AND render codex into the LIVE .codex — the exact corruption this file guards.
PF_DIR="$(mktemp -d)"
PF_CC="$PF_DIR/claude"; mkdir -p "$PF_CC"
PF_ENV="$PF_DIR/local.env"
make_local_env "$PF_ENV" "$PF_CC" "$PF_DIR/vault"   # CLAUDE_CONFIG_DIR set, CODEX_HOME unset
pf_status=0
pf_out="$(env -u CODEX_HOME AI_CONFIG_LOCAL_ENV="$PF_ENV" bash "$REPO_ROOT/scripts/install.sh" \
  --harness claude --harness codex 2>&1 >/dev/null)" || pf_status=$?
assert_eq "multi-harness with an unset target exits 1 (preflight)" "1" "$pf_status"
assert_contains "preflight names the unset target env var" "$pf_out" "CODEX_HOME is not set"
# The keystone: the FIRST harness must NOT have been built — no partial install.
[ -e "$PF_CC/CLAUDE.md" ] \
  && _fail "preflight failure leaves no partial install" "CLAUDE.md built before codex preflight failed" \
  || _pass "preflight failure leaves no partial install"
rm -rf "$PF_DIR"

# --- 7. A whitespace/glob harness value is rejected, not split or expanded ----
# `--harness 'claude codex'` is ONE (invalid) harness name — it must be rejected,
# not word-split into two valid requests. `--harness '*'` must not glob against
# the CWD. (Regression for the array vs space-string implementation.)
WS_DIR="$(mktemp -d)"
WS_CC="$WS_DIR/claude"; WS_CX="$WS_DIR/codex"; mkdir -p "$WS_CC" "$WS_CX"
WS_ENV="$WS_DIR/local.env"
_mh_dual_env "$WS_ENV" "$WS_CC" "$WS_CX" "$WS_DIR/vault"
ws_status=0
ws_out="$(AI_CONFIG_LOCAL_ENV="$WS_ENV" bash "$REPO_ROOT/scripts/install.sh" \
  --harness 'claude codex' --build-only 2>&1 >/dev/null)" || ws_status=$?
assert_eq "install.sh --harness 'claude codex' (space) exits 1" "1" "$ws_status"
assert_contains "space-valued harness rejected as unknown" "$ws_out" "unknown harness 'claude codex'"
glob_status=0
glob_out="$(cd / && AI_CONFIG_LOCAL_ENV="$WS_ENV" bash "$REPO_ROOT/scripts/install.sh" \
  --harness '*' --build-only 2>&1 >/dev/null)" || glob_status=$?
assert_eq "install.sh --harness '*' (glob) exits 1" "1" "$glob_status"
assert_contains "glob harness value rejected, not expanded" "$glob_out" "unknown harness '*'"
rm -rf "$WS_DIR"

# --- 8. Case-insensitive: --harness CLAUDE resolves, and dedupes with claude --
# Names are lowercased, so a casing variant builds the right harness and a
# repeat under different case builds once (no duplicate build of the same target).
CS_DIR="$(mktemp -d)"
CS_CC="$CS_DIR/claude"; mkdir -p "$CS_CC"
CS_ENV="$CS_DIR/local.env"
make_local_env "$CS_ENV" "$CS_CC" "$CS_DIR/vault"
cs_status=0
AI_CONFIG_LOCAL_ENV="$CS_ENV" bash "$REPO_ROOT/scripts/install.sh" \
  --harness claude --harness CLAUDE >/dev/null 2>&1 || cs_status=$?
assert_eq "install.sh --harness claude --harness CLAUDE (case dedup) exits 0" "0" "$cs_status"
assert_file "case-variant repeat still builds the claude entrypoint" "$CS_CC/CLAUDE.md"
rm -rf "$CS_DIR"

# --- 9. --build-only cannot be combined with multiple --harness --------------
# --build-only prints a single build dir, so it is a single-target operation
# (like --out) and must be rejected with >1 harness rather than print N paths.
BO_DIR="$(mktemp -d)"
BO_CC="$BO_DIR/claude"; BO_CX="$BO_DIR/codex"; mkdir -p "$BO_CC" "$BO_CX"
BO_ENV="$BO_DIR/local.env"
_mh_dual_env "$BO_ENV" "$BO_CC" "$BO_CX" "$BO_DIR/vault"
bo_status=0
bo_out="$(AI_CONFIG_LOCAL_ENV="$BO_ENV" bash "$REPO_ROOT/scripts/install.sh" \
  --harness claude --harness codex --build-only 2>&1 >/dev/null)" || bo_status=$?
assert_eq "install.sh --build-only + multiple --harness exits 1" "1" "$bo_status"
assert_contains "install.sh --build-only + multiple --harness names the conflict" "$bo_out" "--build-only"
rm -rf "$BO_DIR"

# --- 10. Live config-dir guard: a throwaway build can't overwrite a live dir --
# Regression for the corruption where a fixture local.env omitted CODEX_HOME, so
# the target fell back to the INHERITED (live co-located) CODEX_HOME and the build
# overwrote the operator's real AGENTS.md with a temp OBSIDIAN_VAULT_PATH. The
# guard in install.sh refuses to render a throwaway-env build into a forbidden
# live dir and exits non-zero WITHOUT writing it. Exercised SAFELY against a temp
# dir via AI_CONFIG_FORBID_TARGETS — never the operator's real .codex — so a guard
# regression can never corrupt a live entrypoint even when this runs from the
# co-located folder. The inline CODEX_HOME simulates the leaked inherited value.
GD_DIR="$(mktemp -d)"
GD_LIVE="$GD_DIR/live-codex"; mkdir -p "$GD_LIVE"
printf 'SENTINEL-DO-NOT-OVERWRITE\n' > "$GD_LIVE/AGENTS.md"
GD_ENV="$GD_DIR/local.env"
# Fixture sets OBSIDIAN_VAULT_PATH but NOT CODEX_HOME — the leak precondition.
printf 'OBSIDIAN_VAULT_PATH=%q\n' "$GD_DIR/vault" > "$GD_ENV"
gd_status=0
gd_out="$(AI_CONFIG_FORBID_TARGETS="$GD_LIVE" CODEX_HOME="$GD_LIVE" \
  AI_CONFIG_LOCAL_ENV="$GD_ENV" bash "$REPO_ROOT/scripts/install.sh" \
  --harness codex 2>&1 >/dev/null)" || gd_status=$?
assert_eq "guard: throwaway build into a forbidden live dir exits 1" "1" "$gd_status"
assert_contains "guard: names the refusal" "$gd_out" "refusing to render"
gd_sentinel="$(cat "$GD_LIVE/AGENTS.md" 2>/dev/null)"
assert_eq "guard: the live AGENTS.md is NOT overwritten" "SENTINEL-DO-NOT-OVERWRITE" "$gd_sentinel"
# The escape hatch lets a deliberate custom-env co-located install through: with
# AI_CONFIG_ALLOW_LIVE_TARGET=1 the same render now SUCCEEDS (and replaces AGENTS.md).
ov_status=0
AI_CONFIG_ALLOW_LIVE_TARGET=1 AI_CONFIG_FORBID_TARGETS="$GD_LIVE" CODEX_HOME="$GD_LIVE" \
  AI_CONFIG_LOCAL_ENV="$GD_ENV" bash "$REPO_ROOT/scripts/install.sh" \
  --harness codex >/dev/null 2>&1 || ov_status=$?
assert_eq "guard: AI_CONFIG_ALLOW_LIVE_TARGET=1 overrides the refusal (exits 0)" "0" "$ov_status"
assert_file "guard: override actually rendered the codex entrypoint" "$GD_LIVE/AGENTS.md"
[ -f "$GD_LIVE/AGENTS.md" ] && grep -q 'SENTINEL-DO-NOT-OVERWRITE' "$GD_LIVE/AGENTS.md" \
  && _fail "guard: override replaced the sentinel" "sentinel still present after override render" \
  || _pass "guard: override replaced the sentinel with a real render"
rm -rf "$GD_DIR"

# --- 11. Guard refuses BEFORE creating a missing forbidden dir (no mutation) --
# The guard runs before `mkdir -p "$TARGET"`, so a refusal must not even CREATE
# the live dir — the read-only-until-the-guard-passes property is total. Point a
# throwaway build at a forbidden dir that does NOT exist yet and assert it stays
# absent. (cross-model adversarial finding: pre-fix the guard ran after mkdir.)
GM_DIR="$(mktemp -d)"
GM_MISSING="$GM_DIR/never-created"   # forbidden target, deliberately absent
GM_ENV="$GM_DIR/local.env"
printf 'OBSIDIAN_VAULT_PATH=%q\n' "$GM_DIR/vault" > "$GM_ENV"
gm_status=0
AI_CONFIG_FORBID_TARGETS="$GM_MISSING" CODEX_HOME="$GM_MISSING" \
  AI_CONFIG_LOCAL_ENV="$GM_ENV" bash "$REPO_ROOT/scripts/install.sh" \
  --harness codex >/dev/null 2>&1 || gm_status=$?
assert_eq "guard: build into a missing forbidden dir exits 1" "1" "$gm_status"
[ -e "$GM_MISSING" ] \
  && _fail "guard: refusal does NOT create the forbidden dir" "$GM_MISSING was created before the guard fired" \
  || _pass "guard: refusal does NOT create the forbidden dir"
rm -rf "$GM_DIR"

# --- 12. Guard fires for --build-only too — no transient under the live dir ---
# --build-only never swaps, but it does `mktemp -d "$TARGET/.install-build.*"` —
# which, into a forbidden live dir, would still scribble a transient build tree
# there. The guard must block it first: exit 1, AGENTS.md intact, and NO
# .install-build* left behind. (cross-model adversarial finding.)
GB_DIR="$(mktemp -d)"
GB_LIVE="$GB_DIR/live-codex"; mkdir -p "$GB_LIVE"
printf 'SENTINEL-BUILD-ONLY\n' > "$GB_LIVE/AGENTS.md"
GB_ENV="$GB_DIR/local.env"
printf 'OBSIDIAN_VAULT_PATH=%q\n' "$GB_DIR/vault" > "$GB_ENV"
gb_status=0
AI_CONFIG_FORBID_TARGETS="$GB_LIVE" CODEX_HOME="$GB_LIVE" \
  AI_CONFIG_LOCAL_ENV="$GB_ENV" bash "$REPO_ROOT/scripts/install.sh" \
  --harness codex --build-only >/dev/null 2>&1 || gb_status=$?
assert_eq "guard: --build-only into a forbidden live dir exits 1" "1" "$gb_status"
gb_sentinel="$(cat "$GB_LIVE/AGENTS.md" 2>/dev/null)"
assert_eq "guard: --build-only leaves AGENTS.md intact" "SENTINEL-BUILD-ONLY" "$gb_sentinel"
gb_transient="$(find "$GB_LIVE" -maxdepth 1 -name '.install-build.*' 2>/dev/null)"
assert_eq "guard: --build-only leaves no .install-build transient" "" "$gb_transient"
rm -rf "$GB_DIR"

# --- 13. Bootstrap form: --harness claude --out <dir> with a local.env that
# omits CLAUDE_CONFIG_DIR (bootstrap.sh's invocation shape). The claude
# entrypoint templates reference @@CLAUDE_CONFIG_DIR@@, which must resolve from
# the EFFECTIVE target (--out) instead of dying on the empty env var — the
# Windows PS lane caught exactly this regression (its twin already carried the
# scenario; this is the bash mirror). The rendered catalog path must name the
# --out target.
BF_DIR="$(mktemp -d)"
BF_CC="$BF_DIR/cc"; mkdir -p "$BF_CC"
BF_ENV="$BF_DIR/local.env"
printf 'OBSIDIAN_VAULT_PATH=%q\n' "$BF_DIR/vault" > "$BF_ENV"
bf_status=0
env -u CLAUDE_CONFIG_DIR AI_CONFIG_LOCAL_ENV="$BF_ENV" bash "$REPO_ROOT/scripts/install.sh" \
  --harness claude --out "$BF_CC" >/dev/null 2>&1 || bf_status=$?
assert_eq "bootstrap form --harness claude --out <dir> exits 0" "0" "$bf_status"
assert_file "bootstrap form --harness/--out builds the claude entrypoint" "$BF_CC/CLAUDE.md"
if [ -f "$BF_CC/CLAUDE.md" ]; then
  # Compare against the CANONICALIZED target — install.sh canonicalizes via
  # `cd && pwd` (macOS mktemp paths resolve /var → /private/var).
  BF_CC_CANON="$(CDPATH= cd "$BF_CC" && pwd)"
  assert_contains "bootstrap form: rendered catalog path names the effective --out target" \
    "$(cat "$BF_CC/CLAUDE.md")" "$BF_CC_CANON/SKILLS.md"
fi
rm -rf "$BF_DIR"
