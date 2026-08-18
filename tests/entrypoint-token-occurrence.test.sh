#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/entrypoint-token-occurrence.test.sh — assert each multi-line
# INJECTION-MARKER token (`@@CAPABILITY_CATALOG@@`) appears EXACTLY ONCE in
# every entrypoint template that uses it.
#
# Why this guard exists (see [[feedback_install_sh_global_substitution_prose_trap]]):
# scripts/install.sh substitutes `@@TOKEN@@` placeholders GLOBALLY — every
# occurrence in a template, including any in DESCRIPTIVE PROSE, gets replaced.
# For the catalog marker that substitution injects a whole multi-line table,
# so a second literal occurrence (e.g. a placeholder named in a sentence that
# explains the mechanism) silently clobbers that sentence with the full table.
# The failure mode is a corrupted rendered entrypoint, not a loud build error.
#
# Scope of the one-occurrence assertion — INJECTION-MARKER tokens only:
# @@CAPABILITY_CATALOG@@ — install.sh replaces it with the multi-line
# capability-catalog table (install.sh:234).
# PATH-CLASS tokens (`@@AI_CONFIG_DIR@@`, `@@OBSIDIAN_VAULT_PATH@@`) are
# DELIBERATELY EXCLUDED: install.sh resolves them to a single-line path value
# and they legitimately recur many times across a template (every reference to
# the agentic-os-template root / vault path). Asserting one-occurrence on those would be
# a false constraint. The clobber trap only bites the marker class, where a
# stray prose copy injects a whole block.
#
# rule-attribution.test.sh already pins @@CAPABILITY_CATALOG@@==1 for the
# SKILLS + AGENTS templates as a side-check; this file is the dedicated,
# template-complete home for the invariant and ADDS the previously-uncovered
# Claude global entrypoint template (harnesses/claude/CLAUDE.template.md).
#
# Per [[reference_shell_grep_overlay]] + [[reference_rg_shim]] use /usr/bin/grep
# explicitly so the bash subshell sees BSD grep, not the interactive zsh ugrep
# alias or the `rg` Claude shim.

GREP=/usr/bin/grep

# count_token <file> <literal-token> — echo the number of occurrences of
# <literal-token> in <file>. Counts occurrences (grep -o), not lines, so two
# tokens on one line are both counted. -F: fixed string (@@...@@ has no regex
# metachars but -F makes the intent explicit and immune to future renames).
count_token() {
  local file="$1" token="$2" n
  n="$($GREP -oF "$token" "$file" 2>/dev/null | $GREP -c .)"
  printf '%s\n' "${n:-0}"
}

# The injection-marker token whose global substitution injects a multi-line
# block. Add future multi-line-injection markers here in lockstep with any new
# `content="${content//@@NEW_MARKER@@/$value}"` line in install.sh.
MARKER_TOKEN='@@CAPABILITY_CATALOG@@'

# Every entrypoint template that legitimately carries the marker.
MARKER_TEMPLATES="harnesses/claude/CLAUDE.template.md harnesses/codex/AGENTS.template.md harnesses/cursor/AGENTS.template.md harnesses/claude/SKILLS.template.md"

for tpl in $MARKER_TEMPLATES; do
  path="$REPO_ROOT/$tpl"
  if [ ! -f "$path" ]; then
    _fail "entrypoint template exists: $tpl" "file not found: $path"
    continue
  fi
  n="$(count_token "$path" "$MARKER_TOKEN")"
  assert_eq "$tpl carries exactly one $MARKER_TOKEN (no prose-clobber copy)" "1" "$n"
done

# the operator-skills-overlay marker is the SECOND multi-line injection
# marker — install.{sh,ps1} splice the operator overlay file at it (the
# `content=${content//@@OPERATOR_SKILLS_OVERLAY@@/$overlay}` line). It lives in
# the claude SKILLS template ONLY (the codex/global entrypoints have no overlay).
# Same one-occurrence invariant: a stray prose copy of the marker would be
# clobbered by the spliced overlay block. The literal is built from halves so this
# test SOURCE carries no second copy that a naive scan of tests/ could trip on.
OVERLAY_MARKER="@@OPERATOR_SKILLS""_OVERLAY@@"
overlay_n="$(count_token "$REPO_ROOT/harnesses/claude/SKILLS.template.md" "$OVERLAY_MARKER")"
assert_eq "SKILLS.template.md carries exactly one operator-overlay marker (no prose-clobber copy)" \
  "1" "$overlay_n"

# --- no brittle line-number citation of a script ------------------
# The root entrypoints (CLAUDE.md / AGENTS.md) once cited "line 71 of
# `scripts/install.sh`" for the local.env-existence guard. A hardcoded line
# number drifts silently the moment install.sh gains or loses a line above the
# cited point — the prose then points at the wrong line with no error. Pin the
# anti-pattern: a live entrypoint must DESCRIBE what the referenced code does,
# never cite it by line number. (Archived plans/specs under docs/ are exempt —
# they are point-in-time records, not live operating instructions.)
#
# Two phrasings are forbidden, case-insensitive on the word `line`:
# "line <N> of `…install.sh`" and "`…install.sh` line <N>"
# A left word-boundary `(^|[^[:alnum:]_])` precedes the first form's `line` so
# words ending in "line" (baseline, deadline, underline) followed by a number
# do NOT false-match (Codex review fix). The `:N` and ", line N" forms are
# intentionally NOT matched — broadening to them risks tripping on legitimate
# prose (timestamps, URLs); the two phrasings above are the historical
# anti-pattern this guard pins. Verified against /usr/bin/grep -E (POSIX ERE;
# BSD + GNU agree) and the.NET twin verified equivalent.
LINE_CITE_RE='(^|[^[:alnum:]_])[Ll]ine [0-9]+ of `?[a-zA-Z0-9/._-]*\.sh|`[a-zA-Z0-9/._-]*\.sh` [Ll]ine [0-9]+'
for ep in CLAUDE.md AGENTS.md; do
  ep_path="$REPO_ROOT/$ep"
  if [ ! -f "$ep_path" ]; then
    _fail "root entrypoint exists: $ep" "file not found: $ep_path"
    continue
  fi
  cite_hits="$($GREP -nE "$LINE_CITE_RE" "$ep_path" 2>/dev/null || true)"
  if [ -z "$cite_hits" ]; then
    _pass "$ep has no brittle 'line N of <script>.sh' citation"
  else
    _fail "$ep must DESCRIBE referenced script code, not cite it by line number" "$cite_hits"
  fi
done

# Positive controls: the forbidden pattern MUST match each known-brittle
# phrasing, so an over-narrow regex can't make the guard above vacuously pass.
# Both forbidden forms get a fixture (Codex review: cover the second form too).
cite_pos() {
  local label="$1" line="$2" f
  f="$(mktemp)"
  printf '%s\n' "$line" > "$f"
  if $GREP -qE "$LINE_CITE_RE" "$f"; then
    _pass "$label"
  else
    _fail "$label" "regex failed to match: $line"
  fi
  rm -f "$f"
}
cite_pos "line-citation regex matches form A: line N of script.sh (self-trip guard)" \
  'requires local.env — it exits early if not (line 71 of `scripts/install.sh`).'
cite_pos "line-citation regex matches form B: script.sh line N (self-trip guard)" \
  'see `scripts/install.sh` line 71 for the existence guard.'
# Negative control: a word ending in "line" + number must NOT match (boundary).
NEG_FIXTURE="$(mktemp)"
printf 'the baseline 71 of `scripts/install.sh` reference must not trip this.\n' > "$NEG_FIXTURE"
if $GREP -qE "$LINE_CITE_RE" "$NEG_FIXTURE"; then
  _fail "line-citation regex does NOT match a baseline-N false-positive (boundary guard)" \
        "regex wrongly matched a word ending in 'line'"
else
  _pass "line-citation regex does NOT match a baseline-N false-positive (boundary guard)"
fi
rm -f "$NEG_FIXTURE"

# --- Detector self-trip guard (negative test) ------------------------------
# Prove count_token actually catches a stray second occurrence — otherwise a
# bug that always echoed "1" would make every assertion above vacuously pass.
# Build the trip fixture so this test SOURCE does not itself carry two literal
# marker tokens (which would skew any naive scan of the tests/ tree).
TRIP_FIXTURE="$(mktemp)"
{
  printf '# fixture entrypoint\n\n'
  printf 'A real marker line:\n%s\n\n' "$MARKER_TOKEN"
  printf 'A stray prose copy naming the %s token mid-sentence.\n' "$MARKER_TOKEN"
} > "$TRIP_FIXTURE"
trip_n="$(count_token "$TRIP_FIXTURE" "$MARKER_TOKEN")"
assert_eq "detector counts both occurrences in a two-marker fixture (self-trip guard)" "2" "$trip_n"
# And confirm the one-occurrence assertion would FAIL on that fixture: the
# count is not 1.
[ "$trip_n" != "1" ] \
  && _pass "two-marker fixture is rejected by the one-occurrence rule" \
  || _fail "two-marker fixture is rejected by the one-occurrence rule" "count was $trip_n"
rm -f "$TRIP_FIXTURE"
