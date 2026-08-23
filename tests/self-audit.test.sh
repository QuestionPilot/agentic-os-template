#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/self-audit.test.sh — fixture-based scoring tests for scripts/self-audit.sh.
#
# Each pillar gets a positive (clean → 20/20) and negative (with-gap → <20) case.
# Fixtures are minimal mini-repos under a tmp dir; the script is invoked with
# --repo-root / --memory-dir / --vault-dir overrides so a fixture's state is
# the only thing scored. Per tests/run.sh sourcing semantics (lifecycle.test.sh
# pattern): no trap EXIT, no `exit`; cleanup is inline.

# Test 0 — smoke: the script runs against the real repo and prints a scorecard.
SMOKE_OUT="$(bash "$REPO_ROOT/scripts/self-audit.sh" --repo-root "$REPO_ROOT" 2>/dev/null)"
assert_contains "self-audit smoke: scorecard heading present" \
  "$SMOKE_OUT" "/self-audit scorecard"
assert_contains "self-audit smoke: total line present" \
  "$SMOKE_OUT" "Total:"
assert_contains "self-audit smoke: all five pillar labels present" \
  "$SMOKE_OUT" "Cross-layer handoffs"
assert_contains "self-audit smoke: pillar 5 label present" \
  "$SMOKE_OUT" "Closeout / spine discipline"
assert_contains "self-audit smoke: top gaps section present" \
  "$SMOKE_OUT" "Top gaps (leverage-weighted)"
assert_contains "self-audit smoke: skipped surfaces section present" \
  "$SMOKE_OUT" "Skipped surfaces"

# Test 1 — --json shape: structured object with all expected keys.
SMOKE_JSON="$(bash "$REPO_ROOT/scripts/self-audit.sh" --repo-root "$REPO_ROOT" --json 2>/dev/null)"
if command -v jq >/dev/null 2>&1; then
  assert_eq "self-audit --json: total key is integer" \
    "number" "$(printf '%s' "$SMOKE_JSON" | jq -r '.total | type')"
  assert_eq "self-audit --json: pillars object has 5 keys" \
    "5" "$(printf '%s' "$SMOKE_JSON" | jq -r '.pillars | length')"
  assert_eq "self-audit --json: cross-layer-handoffs pillar key present" \
    "true" "$(printf '%s' "$SMOKE_JSON" | jq -r '.pillars | has("cross-layer-handoffs")')"
  assert_eq "self-audit --json: closeout-spine-discipline pillar key present" \
    "true" "$(printf '%s' "$SMOKE_JSON" | jq -r '.pillars | has("closeout-spine-discipline")')"
  assert_eq "self-audit --json: gaps key is array" \
    "array" "$(printf '%s' "$SMOKE_JSON" | jq -r '.gaps | type')"
  assert_eq "self-audit --json: skipped key is array" \
    "array" "$(printf '%s' "$SMOKE_JSON" | jq -r '.skipped | type')"
else
  _skip "self-audit --json shape tests" "jq not installed"
fi

# Helper: build a minimal valid framework fixture under <root>.
# Caller is responsible for `rm -rf "$root"` after the test.
_sa_mk_fixture_repo() {
  local root="$1"
  mkdir -p "$root/capabilities" \
           "$root/verification" \
           "$root/harnesses/claude/capabilities" \
           "$root/harnesses/codex/capabilities"
  # One symmetric native capability + matching verification recipe.
  cat > "$root/capabilities/example.md" <<'EOF'
---
name: example
summary: example capability for fixture
triggers: [test]
verification: example
harnesses: [claude, codex]
kind: native
lifecycle: shipped
---

# Example
EOF
  cat > "$root/harnesses/claude/capabilities/example.md" <<'EOF'
---
lifecycle: shipped
---

## Claude realization — example
EOF
  cat > "$root/harnesses/codex/capabilities/example.md" <<'EOF'
---
lifecycle: shipped
---

## Codex realization — example
EOF
  cat > "$root/verification/example.md" <<'EOF'
# Example verification recipe
EOF
}

# Helper: pull a single pillar's score from --json output.
_sa_pillar_score() {
  printf '%s' "$1" | jq -r ".pillars[\"$2\"].score"
}

# --- semantic currentness (<TEAM>-522) ---------------------------------------
# The advisory semantic check is wired in via $SELF_AUDIT_CURRENTNESS_BIN so the
# assertions are hermetic: a stub stands in for check-state-currentness.sh and
# replays a chosen exit code + --list payload. What is under test is the WIRING
# contract, not the extractor (that lives in check-state-currentness.test.sh):
# its own section, its own JSON key, and — the load-bearing part — that a
# semantic finding NEVER moves total, a pillar score, or gaps. A checker that
# could depress the score would make operators disable it.
_sa_currentness_stub() { # _sa_currentness_stub <path> <exit> [stdout...]
  local p="$1" rc="$2"; shift 2
  {
    printf '#!/usr/bin/env bash\n'
    local l
    for l in "$@"; do printf 'printf %s\n' "'%s\\n' \"$l\""; done
    printf 'printf %s >&2\n' "'SKIP stub reason\\n'"
    printf 'exit %s\n' "$rc"
  } > "$p"
  chmod +x "$p"
}

_test_currentness_wiring() {
  command -v jq >/dev/null 2>&1 || { _skip "semantic currentness wiring" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  local stub="$fixture/stub.sh"

  # 1. findings — rendered, keyed, and score-neutral.
  local claim proj out base_total base_gaps
  claim="$(printf 'claim\tstale-claim\tABC-1\tIn Progress\tDone\t-\tnotes.md:7')"
  proj="$(printf 'project\tproject-closed-with-open-children\tShipped Thing\tCompleted\t2\t0')"
  _sa_currentness_stub "$stub" 1 "$claim" "$proj"

  # Baseline WITHOUT the checker, so score-neutrality is proved by comparison
  # rather than asserted against a hard-coded number.
  base_total="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" --json 2>/dev/null | jq -r '.total')"
  base_gaps="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" --json 2>/dev/null | jq -r '.gaps | length')"

  out="$(SELF_AUDIT_CURRENTNESS_BIN="$stub" bash "$REPO_ROOT/scripts/self-audit.sh" \
        --isolated --repo-root "$fixture" --json 2>/dev/null)"
  assert_eq "semantic currentness: status is findings" \
    "findings" "$(printf '%s' "$out" | jq -r '.semantic_currentness.status')"
  assert_eq "semantic currentness: claim record lands in the claims array" \
    "ABC-1" "$(printf '%s' "$out" | jq -r '.semantic_currentness.claims[0].identifier')"
  assert_eq "semantic currentness: claim carries its live-vs-stored pair" \
    "In Progress|Done" "$(printf '%s' "$out" | jq -r '.semantic_currentness.claims[0] | "\(.stored)|\(.live)"')"
  assert_eq "semantic currentness: project record lands in the projects array" \
    "project-closed-with-open-children" "$(printf '%s' "$out" | jq -r '.semantic_currentness.projects[0].class')"
  assert_eq "semantic currentness: open_children is numeric, not a string" \
    "number" "$(printf '%s' "$out" | jq -r '.semantic_currentness.projects[0].open_children | type')"
  # The whole point: advisory means advisory.
  assert_eq "semantic currentness: findings do NOT change the total score" \
    "$base_total" "$(printf '%s' "$out" | jq -r '.total')"
  assert_eq "semantic currentness: findings do NOT enter the gap list" \
    "$base_gaps" "$(printf '%s' "$out" | jq -r '.gaps | length')"

  local md
  md="$(SELF_AUDIT_CURRENTNESS_BIN="$stub" bash "$REPO_ROOT/scripts/self-audit.sh" \
       --isolated --repo-root "$fixture" 2>/dev/null)"
  assert_contains "semantic currentness: markdown has its own section" "$md" "## Semantic currentness"
  assert_contains "semantic currentness: markdown renders the claim finding" \
    "$md" 'stale-claim ABC-1: note says "In Progress", tracker says "Done" (as-of -) — notes.md:7'
  assert_contains "semantic currentness: markdown renders the project finding" \
    "$md" 'project-closed-with-open-children "Shipped Thing": status "Completed" with 2 open child issue(s), 0 active'
  assert_contains "semantic currentness: markdown states the advisory boundary" \
    "$md" "never change the pillar scores"

  # 2. clean — exit 0, no findings.
  _sa_currentness_stub "$stub" 0
  out="$(SELF_AUDIT_CURRENTNESS_BIN="$stub" bash "$REPO_ROOT/scripts/self-audit.sh" \
        --isolated --repo-root "$fixture" --json 2>/dev/null)"
  assert_eq "semantic currentness: exit 0 reports clean" \
    "clean" "$(printf '%s' "$out" | jq -r '.semantic_currentness.status')"
  assert_eq "semantic currentness: clean run has an empty claims array" \
    "0" "$(printf '%s' "$out" | jq -r '.semantic_currentness.claims | length')"

  # 3. skip — exit 2 fails SOFT and the reason is NAMED, never anonymous.
  _sa_currentness_stub "$stub" 2
  out="$(SELF_AUDIT_CURRENTNESS_BIN="$stub" bash "$REPO_ROOT/scripts/self-audit.sh" \
        --isolated --repo-root "$fixture" --json 2>/dev/null)"
  assert_eq "semantic currentness: exit 2 reports skipped" \
    "skipped" "$(printf '%s' "$out" | jq -r '.semantic_currentness.status')"
  assert_eq "semantic currentness: skip reason is named, not anonymous" \
    "stub reason" "$(printf '%s' "$out" | jq -r '.semantic_currentness.reason')"
  assert_eq "semantic currentness: a skip preserves the filesystem score" \
    "$base_total" "$(printf '%s' "$out" | jq -r '.total')"

  # 4. exit 1 with no parseable record is a contract break, not a clean run.
  _sa_currentness_stub "$stub" 1
  out="$(SELF_AUDIT_CURRENTNESS_BIN="$stub" bash "$REPO_ROOT/scripts/self-audit.sh" \
        --isolated --repo-root "$fixture" --json 2>/dev/null)"
  assert_eq "semantic currentness: exit 1 with no records degrades to skipped" \
    "skipped" "$(printf '%s' "$out" | jq -r '.semantic_currentness.status')"

  # 5. plain --isolated (no stub): the section still exists and names the skip.
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" --json 2>/dev/null)"
  assert_eq "semantic currentness: isolated run without a checker is a named skip" \
    "isolated run — semantic currentness not evaluated" \
    "$(printf '%s' "$out" | jq -r '.semantic_currentness.reason')"

  rm -rf "$fixture"
}
_test_currentness_wiring

# --- Pillar 5 (closeout / spine discipline) — negative case: missing realization
# Fixture: a native capability without the Codex realization should ding pillar 5.
_test_pillar5_missing_codex_realization() {
  command -v jq >/dev/null 2>&1 || { _skip "pillar 5 missing-codex test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  rm -f "$fixture/harnesses/codex/capabilities/example.md"

  local out score
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" --json 2>/dev/null)"
  score="$(_sa_pillar_score "$out" "closeout-spine-discipline")"

  rm -rf "$fixture"

  if [ -n "$score" ] && [ "$score" -lt 20 ]; then
    _pass "pillar 5 deducts when a native capability is missing its Codex realization"
  else
    _fail "pillar 5 deducts when a native capability is missing its Codex realization" \
          "expected score < 20, got [$score]"
  fi
}
_test_pillar5_missing_codex_realization

# --- Pillar 5 — positive case: symmetric spine scores 20/20.
_test_pillar5_symmetric_clean() {
  command -v jq >/dev/null 2>&1 || { _skip "pillar 5 symmetric-clean test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"

  local out score
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" --json 2>/dev/null)"
  score="$(_sa_pillar_score "$out" "closeout-spine-discipline")"
  rm -rf "$fixture"

  assert_eq "pillar 5 is 20/20 on symmetric-spine fixture" "20" "$score"
}
_test_pillar5_symmetric_clean

# --- Pillar 5 — hermes is first-class: a native capability that DECLARES hermes
# in its `harnesses:` frontmatter but lacks the hermes realization must deduct
# (the harness set is derived from each capability's frontmatter, not a hardcoded
# claude+codex pair, so a thinned-out hermes realization can no longer pass).
_test_pillar5_missing_hermes_realization() {
  command -v jq >/dev/null 2>&1 || { _skip "pillar 5 missing-hermes test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  # Promote the fixture capability to a 3-harness spine + add the hermes
  # realization, so the ONLY asymmetry is the one induced below.
  cat > "$fixture/capabilities/example.md" <<'EOF'
---
name: example
summary: example capability for fixture
triggers: [test]
verification: example
harnesses: [claude, codex, hermes]
kind: native
lifecycle: shipped
---

# Example
EOF
  mkdir -p "$fixture/harnesses/hermes/capabilities"
  cat > "$fixture/harnesses/hermes/capabilities/example.md" <<'EOF'
---
lifecycle: shipped
---

## Hermes realization — example
EOF

  local out score
  # Sanity: a symmetric 3-harness spine scores 20/20.
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" --json 2>/dev/null)"
  score="$(_sa_pillar_score "$out" "closeout-spine-discipline")"
  assert_eq "pillar 5 is 20/20 on a symmetric 3-harness (incl. hermes) fixture" "20" "$score"

  # Drop ONLY the hermes realization → pillar 5 must deduct.
  rm -f "$fixture/harnesses/hermes/capabilities/example.md"
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" --json 2>/dev/null)"
  score="$(_sa_pillar_score "$out" "closeout-spine-discipline")"
  rm -rf "$fixture"

  if [ -n "$score" ] && [ "$score" -lt 20 ]; then
    _pass "pillar 5 deducts when a native capability is missing its Hermes realization (hermes first-class)"
  else
    _fail "pillar 5 deducts when a native capability is missing its Hermes realization (hermes first-class)" \
          "expected score < 20, got [$score]"
  fi
}
_test_pillar5_missing_hermes_realization

# --- Pillar 4 (verification coverage) — negative case: orphan recipe.
# Fixture: a verification/orphan.md with no capability declaring `verification: orphan`.
_test_pillar4_orphan_recipe() {
  command -v jq >/dev/null 2>&1 || { _skip "pillar 4 orphan-recipe test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  cat > "$fixture/verification/orphan.md" <<'EOF'
# Orphan recipe — no capability points here
EOF

  local out score
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" --json 2>/dev/null)"
  score="$(_sa_pillar_score "$out" "verification-coverage")"
  rm -rf "$fixture"

  if [ -n "$score" ] && [ "$score" -lt 20 ]; then
    _pass "pillar 4 deducts when a verification recipe has no capability consumer"
  else
    _fail "pillar 4 deducts when a verification recipe has no capability consumer" \
          "expected score < 20, got [$score]"
  fi
}
_test_pillar4_orphan_recipe

# --- Pillar 4 — positive case: every recipe has a consumer.
_test_pillar4_clean() {
  command -v jq >/dev/null 2>&1 || { _skip "pillar 4 clean test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"

  local out score
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" --json 2>/dev/null)"
  score="$(_sa_pillar_score "$out" "verification-coverage")"
  rm -rf "$fixture"

  assert_eq "pillar 4 is 20/20 on clean recipe<->capability fixture" "20" "$score"
}
_test_pillar4_clean

# --- Pillar 3 (folder hygiene) — negative case: anti-pattern directory.
_test_pillar3_antipattern_dir() {
  command -v jq >/dev/null 2>&1 || { _skip "pillar 3 antipattern-dir test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  mkdir -p "$fixture/misc"
  # Drop a sentinel file so the dir isn't ALSO empty (testing antipattern naming
  # specifically, not the empty-dir penalty).
  printf 'sentinel\n' > "$fixture/misc/sentinel.md"

  local out score
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" --json 2>/dev/null)"
  score="$(_sa_pillar_score "$out" "folder-hygiene")"
  rm -rf "$fixture"

  if [ -n "$score" ] && [ "$score" -lt 20 ]; then
    _pass "pillar 3 deducts on anti-pattern directory name (misc/)"
  else
    _fail "pillar 3 deducts on anti-pattern directory name (misc/)" \
          "expected score < 20, got [$score]"
  fi
}
_test_pillar3_antipattern_dir

# --- Pillar 3 — negative case: a live .git inside the configured vault (the
# Drive-sync corruption footgun <TEAM>-298 #2 guards against).
_test_pillar3_drive_git() {
  command -v jq >/dev/null 2>&1 || { _skip "pillar 3 drive-git test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  local vault; vault="$(mktemp -d)" || { rm -rf "$fixture"; return 1; }
  mkdir -p "$vault/.git"          # plant a live .git inside the vault

  local out score
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated \
          --repo-root "$fixture" --vault-dir "$vault" --json 2>/dev/null)"
  score="$(_sa_pillar_score "$out" "folder-hygiene")"

  if [ -n "$score" ] && [ "$score" -lt 20 ]; then
    _pass "pillar 3 deducts on a live .git inside the vault"
  else
    _fail "pillar 3 deducts on a live .git inside the vault" \
          "expected score < 20, got [$score]"
  fi
  assert_contains "pillar 3 names the .git-in-vault gap" \
    "$out" "Live .git inside the sync-hosted vault"

  # A `.git` gitlink FILE (worktree/submodule pointer), not a dir, is the same
  # footgun — the guard uses -e / Test-Path, which catches both (cross-model note).
  rm -rf "$vault/.git"
  printf 'gitdir: /elsewhere/.git/worktrees/x\n' > "$vault/.git"
  local out_gl
  out_gl="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" --vault-dir "$vault" --json 2>/dev/null)"
  assert_contains "Drive-git guard also fires on a .git gitlink FILE" \
    "$out_gl" "Live .git inside the sync-hosted vault"
  rm -f "$vault/.git"

  # Positive: a clean vault (no .git) must NOT trip the check — proves the guard
  # is additive (no false positive on the common, correct setup).
  rm -rf "$vault/.git"
  local out2 score2
  out2="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated \
           --repo-root "$fixture" --vault-dir "$vault" --json 2>/dev/null)"
  score2="$(_sa_pillar_score "$out2" "folder-hygiene")"
  rm -rf "$fixture" "$vault"
  assert_eq "pillar 3 stays 20/20 with a vault that has no .git" "20" "$score2"
}
_test_pillar3_drive_git

# --- Pillar 3 — positive case: clean folder structure.
_test_pillar3_clean() {
  command -v jq >/dev/null 2>&1 || { _skip "pillar 3 clean test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"

  local out score
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" --json 2>/dev/null)"
  score="$(_sa_pillar_score "$out" "folder-hygiene")"
  rm -rf "$fixture"

  assert_eq "pillar 3 is 20/20 on clean folder fixture" "20" "$score"
}
_test_pillar3_clean

# --- Pillar 2 (memory hygiene) — negative case: orphan memory file (no MEMORY.md entry).
_test_pillar2_orphan_memory() {
  command -v jq >/dev/null 2>&1 || { _skip "pillar 2 orphan-memory test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"

  local mem; mem="$(mktemp -d)" || { rm -rf "$fixture"; return 1; }
  cat > "$mem/MEMORY.md" <<'EOF'
# Memory Index

(intentionally empty body — no entries)
EOF
  cat > "$mem/feedback_orphan.md" <<'EOF'
---
name: feedback_orphan
metadata: { type: feedback }
---
orphan content
EOF

  local out score
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated \
          --repo-root "$fixture" \
          --memory-dir "$mem" --json 2>/dev/null)"
  score="$(_sa_pillar_score "$out" "memory-hygiene")"
  rm -rf "$fixture" "$mem"

  if [ -n "$score" ] && [ "$score" -lt 20 ]; then
    _pass "pillar 2 deducts when a memory file has no MEMORY.md index entry"
  else
    _fail "pillar 2 deducts when a memory file has no MEMORY.md index entry" \
          "expected score < 20, got [$score]"
  fi
}
_test_pillar2_orphan_memory

# --- Pillar 2 — negative case: MEMORY.md over recall cap.
_test_pillar2_memory_over_cap() {
  command -v jq >/dev/null 2>&1 || { _skip "pillar 2 over-cap test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"

  local mem; mem="$(mktemp -d)" || { rm -rf "$fixture"; return 1; }
  # Build a MEMORY.md just over the 24400-byte threshold.
  {
    printf '# Memory Index\n\n'
    # ~25KB of pointer lines pointing at a single existing memory file so
    # there are no orphans / broken-link interactions corrupting the score.
    local i
    for i in $(seq 1 400); do
      printf -- '- [pad-entry-%s](pad.md) %s\n' "$i" \
        "lorem ipsum dolor sit amet consectetur adipiscing elit padding padding padding padding"
    done
  } > "$mem/MEMORY.md"
  cat > "$mem/pad.md" <<'EOF'
---
name: pad
---
pad content
EOF

  local out score
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated \
          --repo-root "$fixture" \
          --memory-dir "$mem" --json 2>/dev/null)"
  score="$(_sa_pillar_score "$out" "memory-hygiene")"
  local cap_gap_present
  cap_gap_present="$(printf '%s' "$out" | jq -r '.gaps[] | select(.title | contains("over recall cap")) | .title' | head -1)"
  rm -rf "$fixture" "$mem"

  if [ -n "$score" ] && [ "$score" -lt 20 ] && [ -n "$cap_gap_present" ]; then
    _pass "pillar 2 deducts when MEMORY.md exceeds the recall cap"
  else
    _fail "pillar 2 deducts when MEMORY.md exceeds the recall cap" \
          "expected score < 20 + over-cap gap, got score=[$score] cap_gap=[$cap_gap_present]"
  fi
}
_test_pillar2_memory_over_cap

# --- Pillar 2 — negative case: MEMORY.md index entry over the per-line cap.
# an index entry line longer than ~300 chars is a recall-quality
# failure (entries should be one-line headlines; detail belongs in topic files).
# A long entry must deduct memory-hygiene + surface an over-line-length gap.
_test_pillar2_index_entry_over_line_cap() {
  command -v jq >/dev/null 2>&1 || { _skip "pillar 2 over-line-cap test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"

  local mem; mem="$(mktemp -d)" || { rm -rf "$fixture"; return 1; }
  # MEMORY.md well under the size cap but with ONE entry line > 300 chars.
  {
    printf '# Memory Index\n\n'
    printf -- '- [Short](pad.md) — fine\n'
    # One pathologically long index entry (600 chars, > 300 cap).
    printf -- '- [Long](pad.md) — '
    local i
    for i in $(seq 1 30); do printf 'overlongwordpadding '; done
    printf '\n'
  } > "$mem/MEMORY.md"
  cat > "$mem/pad.md" <<'EOF'
---
name: pad
---
pad content
EOF

  local out score line_gap_present other_pillars_clean
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated \
          --repo-root "$fixture" \
          --memory-dir "$mem" --json 2>/dev/null)"
  score="$(_sa_pillar_score "$out" "memory-hygiene")"
  line_gap_present="$(printf '%s' "$out" | jq -r '.gaps[] | select(.title | contains("over line-length cap")) | .title' | head -1)"
  # Codex review missing-test: the line-cap deduction must be LOCALIZED to the
  # memory-hygiene pillar — the other four pillars must stay at 20/20.
  other_pillars_clean="$(printf '%s' "$out" | jq -r \
    '[.pillars | to_entries[] | select(.key != "memory-hygiene") | .value.score] | all(. == 20)')"
  rm -rf "$fixture" "$mem"

  if [ -n "$score" ] && [ "$score" -lt 20 ] && [ -n "$line_gap_present" ] && [ "$other_pillars_clean" = "true" ]; then
    _pass "pillar 2 deducts when a MEMORY.md index entry exceeds the per-line cap"
  else
    _fail "pillar 2 deducts when a MEMORY.md index entry exceeds the per-line cap" \
          "expected score < 20 + over-line-length gap + other pillars 20/20, got score=[$score] line_gap=[$line_gap_present] others_clean=[$other_pillars_clean]"
  fi
}
_test_pillar2_index_entry_over_line_cap

# --- Pillar 2 — positive case: clean memory + index.
_test_pillar2_clean() {
  command -v jq >/dev/null 2>&1 || { _skip "pillar 2 clean test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"

  local mem; mem="$(mktemp -d)" || { rm -rf "$fixture"; return 1; }
  cat > "$mem/MEMORY.md" <<'EOF'
# Memory Index

- [Example](feedback_example.md) — small clean entry
EOF
  cat > "$mem/feedback_example.md" <<'EOF'
---
name: feedback_example
metadata: { type: feedback }
---
example
EOF

  local out score
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated \
          --repo-root "$fixture" \
          --memory-dir "$mem" --json 2>/dev/null)"
  score="$(_sa_pillar_score "$out" "memory-hygiene")"
  rm -rf "$fixture" "$mem"

  assert_eq "pillar 2 is 20/20 on clean memory fixture" "20" "$score"
}
_test_pillar2_clean

# --- Pillar 1 (cross-layer handoffs) — negative case: broken MEMORY.md link.
_test_pillar1_broken_memory_link() {
  command -v jq >/dev/null 2>&1 || { _skip "pillar 1 broken-link test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"

  local mem; mem="$(mktemp -d)" || { rm -rf "$fixture"; return 1; }
  cat > "$mem/MEMORY.md" <<'EOF'
# Memory Index

- [Missing](does_not_exist.md) — link target does not exist
EOF
  # No corresponding does_not_exist.md file.

  local out score
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated \
          --repo-root "$fixture" \
          --memory-dir "$mem" --json 2>/dev/null)"
  score="$(_sa_pillar_score "$out" "cross-layer-handoffs")"
  rm -rf "$fixture" "$mem"

  if [ -n "$score" ] && [ "$score" -lt 20 ]; then
    _pass "pillar 1 deducts when MEMORY.md has a broken file link"
  else
    _fail "pillar 1 deducts when MEMORY.md has a broken file link" \
          "expected score < 20, got [$score]"
  fi
}
_test_pillar1_broken_memory_link

# --- Cross-pillar: --save writes the same content to disk.
_test_save_flag_writes_file() {
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  local out_path="$fixture/audits/audit-2026-05-25.md"

  bash "$REPO_ROOT/scripts/self-audit.sh" --isolated \
       --repo-root "$fixture" \
       --save "audits/audit-2026-05-25.md" >/dev/null 2>&1

  local saved=0
  [ -f "$out_path" ] && saved=1
  rm -rf "$fixture"

  if [ "$saved" -eq 1 ]; then
    _pass "self-audit --save writes the scorecard to the given path"
  else
    _fail "self-audit --save writes the scorecard to the given path" \
          "expected file at $out_path"
  fi
}
_test_save_flag_writes_file

# --- Cross-pillar: script exits 0 on a fixture with multiple gaps (read-only diagnostic).
_test_exit_zero_with_gaps() {
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  rm -f "$fixture/harnesses/codex/capabilities/example.md"
  cat > "$fixture/verification/orphan.md" <<'EOF'
# Orphan recipe
EOF
  mkdir -p "$fixture/misc"
  printf 'x\n' > "$fixture/misc/x.md"

  local rc
  bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" >/dev/null 2>&1
  rc=$?
  rm -rf "$fixture"
  assert_eq "self-audit exits 0 even with multiple gaps surfaced" "0" "$rc"
}
_test_exit_zero_with_gaps

# --- Capability shape: capabilities/self-audit.md ships with the required spine
# frontmatter so the install.sh capability discovery loop picks it up as
# kind: native and the catalog renders the row.
SA_PATH="$REPO_ROOT/capabilities/self-audit.md"
assert_file "capabilities/self-audit.md exists" "$SA_PATH"
SA_CONTENT="$(cat "$SA_PATH" 2>/dev/null || true)"
assert_contains "self-audit capability declares name: self-audit" \
  "$SA_CONTENT" "name: self-audit"
assert_contains "self-audit capability declares kind: native" \
  "$SA_CONTENT" "kind: native"
assert_contains "self-audit capability ships to every spine harness" \
  "$SA_CONTENT" "harnesses: [claude, codex, hermes, cursor]"
assert_contains "self-audit capability declares verification: self-audit" \
  "$SA_CONTENT" "verification: self-audit"

# Both harness realizations exist (mirrors the spine-symmetry check inside the script).
assert_file "harnesses/claude/capabilities/self-audit.md exists" \
  "$REPO_ROOT/harnesses/claude/capabilities/self-audit.md"
assert_file "harnesses/codex/capabilities/self-audit.md exists" \
  "$REPO_ROOT/harnesses/codex/capabilities/self-audit.md"
assert_file "verification/self-audit.md recipe exists" \
  "$REPO_ROOT/verification/self-audit.md"

# core/operating-system.md names the 3-capability spine post-fix.
OS_CONTENT="$(cat "$REPO_ROOT/core/operating-system.md")"
assert_contains "core/operating-system.md names self-audit in the spine" \
  "$OS_CONTENT" "self-audit"

# --- Codex B-3 regression guard: --isolated nullifies operator-env leakage.
# Set fake CLAUDE_CONFIG_DIR + OBSIDIAN_VAULT_PATH that would surface real
# operator memory + vault state if leaked through, then prove --isolated
# scores the same as a hermetic invocation. If the script ever stops honoring
# --isolated for one of these env vars, this assertion catches it.
_test_isolated_blocks_env_leakage() {
  command -v jq >/dev/null 2>&1 || { _skip "isolation env-leak test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"

  local out_iso out_env score_iso score_env
  # Hermetic: fake env vars point at our worktree's real claude-config dir
  # (which has real project_*.md files lacking ## State Deltas potentially).
  # --isolated should ignore the env vars entirely; absent --isolated, the
  # env vars would resolve and pillar 5's sub-check 5.2 could deduct.
  out_iso="$(CLAUDE_CONFIG_DIR="$REPO_ROOT" OBSIDIAN_VAULT_PATH="$REPO_ROOT" \
              bash "$REPO_ROOT/scripts/self-audit.sh" --isolated \
              --repo-root "$fixture" --json 2>/dev/null)"
  score_iso="$(_sa_pillar_score "$out_iso" "closeout-spine-discipline")"
  rm -rf "$fixture"

  assert_eq "--isolated nullifies CLAUDE_CONFIG_DIR + OBSIDIAN_VAULT_PATH (Codex B-3 regression guard)" \
    "20" "$score_iso"
}
_test_isolated_blocks_env_leakage

# --- CRLF-emitting jq: Pillar 1 name-matching survives a Windows-built jq.
# winget jq emits \r\n line endings, and the here-string @tsv read loop keeps
# each row's trailing \r on the LAST field: grep -lF matched "Widget Arc\r"
# against note bodies (never hits — live Windows run scored Pillar 1 at 0/20
# while the PS twin scored 12/20 on identical state), and the open-count
# filter compared "0\r" != "0" (closed projects kept deducting). Hermetic: a
# `linear` CLI stub + the CRLF jq wrapper on PATH; env -u keeps the operator's
# config/vault out of the non-isolated run (the linear-CLI detection only runs
# non-isolated).
_test_crlf_jq_pillar1() {
  command -v jq >/dev/null 2>&1 || { _skip "CRLF jq Pillar 1 test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  local bin="$fixture/bin" mem="$fixture/mem" mem_miss="$fixture/mem-miss"
  mkdir -p "$bin" "$mem" "$mem_miss"
  mk_crlf_jq "$bin"
  cat > "$bin/linear" <<'STUB'
#!/usr/bin/env bash
proj=""; prev=""
for a in "$@"; do [ "$prev" = "--project" ] && proj="$a"; prev="$a"; done
if [ "${1:-}" = "project" ] && [ "${2:-}" = "list" ]; then
  printf '{"nodes":[{"id":"p1","name":"Widget Arc"},{"id":"p2","name":"Closed Arc"}]}\n'; exit 0
fi
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "query" ]; then
  if [ "$proj" = "p1" ]; then printf '{"nodes":[{"identifier":"ABC-1","state":{"name":"Backlog"}}]}\n'; exit 0; fi
  printf '{"nodes":[]}\n'; exit 0
fi
exit 1
STUB
  chmod +x "$bin/linear"
  cat > "$mem/project-widget.md" <<'EOF'
---
name: project-widget
description: Widget Arc active work
metadata:
  type: project
---

Widget Arc is live; ABC-1 in flight.
EOF
  cat > "$mem_miss/project-other.md" <<'EOF'
---
name: project-other
description: unrelated note
metadata:
  type: project
---

Something else entirely.
EOF

  local out
  # Matching note: the active project's name must be FOUND despite CRLF jq.
  out="$(env -u CLAUDE_CONFIG_DIR -u OBSIDIAN_VAULT_PATH -u CODEX_HOME \
          PATH="$bin:$PATH" bash "$REPO_ROOT/scripts/self-audit.sh" \
          --repo-root "$fixture" --memory-dir "$mem" --json 2>/dev/null)"
  assert_not_contains "self-audit: CRLF jq — active project with a matching note raises no handshake gap" \
    "$out" "No memory note for active Linear project"

  # Detection control (vacuous-ALLOW guard): with no matching note the gap MUST
  # still fire and name the CLEAN project string — proving the Linear lane ran.
  # The zero-open project stays filtered even under CRLF ("0" compare survives).
  out="$(env -u CLAUDE_CONFIG_DIR -u OBSIDIAN_VAULT_PATH -u CODEX_HOME \
          PATH="$bin:$PATH" bash "$REPO_ROOT/scripts/self-audit.sh" \
          --repo-root "$fixture" --memory-dir "$mem_miss" --json 2>/dev/null)"
  assert_contains "self-audit: CRLF jq — the handshake gap still fires without a matching note" \
    "$out" "No memory note for active Linear project"
  assert_contains "self-audit: CRLF jq — the gap names the project with no embedded carriage return" \
    "$out" 'Active project \"Widget Arc\" has no project-type memory note'
  assert_not_contains "self-audit: CRLF jq — a zero-open-issue project is still filtered out" \
    "$out" "Closed Arc"
  rm -rf "$fixture"
}
_test_crlf_jq_pillar1

# --- Codex missing-test: a kind: vendored capability does not require harness
# realizations. The spine-symmetry check (pillar 5 sub-check 5.1) walks ONLY
# `kind: native` capabilities. A vendored entry without realizations must
# score clean — vendored shapes ship from snapshots, not author bodies.
_test_pillar5_vendored_does_not_require_realizations() {
  command -v jq >/dev/null 2>&1 || { _skip "pillar 5 vendored test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  # Add a vendored capability with NO harness realizations.
  cat > "$fixture/capabilities/vendor-thing.md" <<'EOF'
---
name: vendor-thing
summary: hypothetical vendored capability
triggers: [test]
verification: example
harnesses: [claude]
kind: vendored
source: github.com/somewhere/somerepo
version: pinned
install: see source
lifecycle: shipped
---

# Vendored body
EOF
  # NO harnesses/claude/capabilities/vendor-thing.md — vendored shapes don't
  # require an author body.

  local out score
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" --json 2>/dev/null)"
  score="$(_sa_pillar_score "$out" "closeout-spine-discipline")"
  rm -rf "$fixture"

  assert_eq "pillar 5 ignores kind: vendored capabilities for spine-symmetry (Codex missing-test)" \
    "20" "$score"
}
_test_pillar5_vendored_does_not_require_realizations

# --- Codex S-3 regression guard: folder hygiene respects.gitignore.
# An empty dir + an anti-pattern dir name inside a.gitignore'd subtree must
# not deduct pillar 3 — those are operator-managed surfaces.
_test_pillar3_gitignored_dirs_not_flagged() {
  command -v jq >/dev/null 2>&1 || { _skip "pillar 3 gitignore test" "jq not installed"; return 0; }
  command -v git >/dev/null 2>&1 || { _skip "pillar 3 gitignore test" "git not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  # Make it a git repo with a.gitignore that excludes scratch/.
  ( cd "$fixture" && git init -q && printf 'scratch/\n' > .gitignore )
  # Plant an empty dir AND an anti-pattern-named dir inside the.gitignored
  # subtree. Both would deduct pillar 3 without the.gitignore-respecting fix.
  mkdir -p "$fixture/scratch/empty-leaf"
  mkdir -p "$fixture/scratch/tmp"
  printf 'x\n' > "$fixture/scratch/tmp/x.md"

  local out score
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" --json 2>/dev/null)"
  score="$(_sa_pillar_score "$out" "folder-hygiene")"
  rm -rf "$fixture"

  assert_eq "pillar 3 respects .gitignore — empty + anti-pattern dirs under ignored subtree do not deduct (Codex S-3)" \
    "20" "$score"
}
_test_pillar3_gitignored_dirs_not_flagged

# --- Codex N-1 regression guard: fm_get trims trailing whitespace.
# A capability written as `kind: native ` (with a trailing space) must still
# match downstream equality checks. Spine symmetry would silently miscount
# native capabilities otherwise (a trailing space → `kind != native` → skipped).
_test_fm_get_trims_trailing_whitespace() {
  command -v jq >/dev/null 2>&1 || { _skip "fm_get trim test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  # Rewrite the example capability with a trailing space after `native`.
  # Use printf to land the literal trailing whitespace deterministically.
  printf -- '---\nname: example\nsummary: example with trailing space in kind\ntriggers: [test]\nverification: example\nharnesses: [claude, codex]\nkind: native \nlifecycle: shipped\n---\n\n# Body\n' \
    > "$fixture/capabilities/example.md"
  # Both realizations exist (from _sa_mk_fixture_repo), so a properly-trimmed
  # fm_get + symmetric spine should score clean.

  local out score
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" --json 2>/dev/null)"
  score="$(_sa_pillar_score "$out" "closeout-spine-discipline")"
  rm -rf "$fixture"

  assert_eq "fm_get tolerates trailing whitespace in YAML value (Codex N-1)" \
    "20" "$score"
}
_test_fm_get_trims_trailing_whitespace

# --- Codex N-2 regression guard: MEMORY.md link regex accepts #anchor suffix.
# A link [Title](file.md#section) must be parsed as targeting file.md (not
# silently ignored). Both clean (target exists) and broken (target missing)
# anchored variants must behave identically to their plain counterparts.
_test_pillar1_md_anchor_link_handled() {
  command -v jq >/dev/null 2>&1 || { _skip "anchor-link test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  local mem; mem="$(mktemp -d)" || { rm -rf "$fixture"; return 1; }
  cat > "$mem/MEMORY.md" <<'EOF'
# Memory Index

- [Anchor link to missing](does_not_exist.md#section) — broken anchor target
EOF
  # No corresponding does_not_exist.md file. With the original regex this
  # would silently pass; the fixed regex now catches it.

  local out score
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated \
          --repo-root "$fixture" \
          --memory-dir "$mem" --json 2>/dev/null)"
  score="$(_sa_pillar_score "$out" "cross-layer-handoffs")"
  rm -rf "$fixture" "$mem"

  if [ -n "$score" ] && [ "$score" -lt 20 ]; then
    _pass "pillar 1 catches broken MEMORY.md link with #anchor suffix (Codex N-2)"
  else
    _fail "pillar 1 catches broken MEMORY.md link with #anchor suffix (Codex N-2)" \
          "expected score < 20, got [$score]"
  fi
}
_test_pillar1_md_anchor_link_handled

# --- Read-only contract regression guard: capability + verification language
# must stay consistent with the script's actual --save behavior. If a future
# edit removes the "opt-in" framing without removing --save itself, this catches
# the contract drift.
SA_CAP_CONTENT="$(cat "$REPO_ROOT/capabilities/self-audit.md")"
SA_VER_CONTENT="$(cat "$REPO_ROOT/verification/self-audit.md")"
assert_contains "capability spec documents --save as the only write path (Codex B-1)" \
  "$SA_CAP_CONTENT" "--save"
assert_contains "verification recipe documents --save as the only write path (Codex B-1)" \
  "$SA_VER_CONTENT" "--save"

# =============================================================================
# three defects that made the scorecard untrustworthy.
# =============================================================================

# --- D1 (<TEAM>-366): memory scoring AGGREGATES all projects/*/memory stores. The
# old picker selected ONE "primary" store and scored only it, so a broken
# secondary store was invisible (the candidates[0] blind-spot class of <TEAM>-360).
# Both stores must be scanned: the stray store's missing MEMORY.md is a REAL gap
# now — its notes run blind at every orient — and the gap must be ATTRIBUTED to
# the store it fired in, not to the clean one.
_test_d1_all_memory_stores_scanned() {
  command -v jq >/dev/null 2>&1 || { _skip "D1 all-stores-scanned test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  # Two project dirs. "aaa-stray" is a near-empty store with a note but NO
  # MEMORY.md; "zzz-primary" carries a clean index + a project file. The old
  # selector scored only zzz-primary (→ pillar 2 = 20, stray invisible); the
  # aggregate scan must surface the stray store's missing index.
  local cfg="$fixture/config"
  mkdir -p "$cfg/projects/aaa-stray/memory" "$cfg/projects/zzz-primary/memory"
  printf 'stray\n' > "$cfg/projects/aaa-stray/memory/note.md"
  cat > "$cfg/projects/zzz-primary/memory/MEMORY.md" <<'EOF'
# Memory Index

- [Proj](project_real.md) — the operator's active project
EOF
  cat > "$cfg/projects/zzz-primary/memory/project_real.md" <<'EOF'
---
name: project_real
metadata:
  type: project
---
real project body
EOF
  # Non-isolated so the CONFIG_DIR→memory auto-resolution runs (the D1 code
  # path); --config-dir pins the config so the result does not depend on ambient
  # env / local.env. Vault unset → skipped. Assert on pillar 2 (memory-hygiene),
  # which is independent of the linear CLI.
  local out p2 missing_detail
  out="$(env -u OBSIDIAN_VAULT_PATH -u CLAUDE_PRIMARY_MEMORY_DIR \
          bash "$REPO_ROOT/scripts/self-audit.sh" \
          --repo-root "$fixture" --config-dir "$cfg" --json 2>/dev/null)"
  p2="$(_sa_pillar_score "$out" "memory-hygiene")"
  missing_detail="$(printf '%s' "$out" | jq -r \
    '.gaps[] | select(.title | contains("MEMORY.md index missing")) | .detail' | head -1)"
  rm -rf "$fixture"
  if [ -n "$p2" ] && [ "$p2" -lt 20 ] && [ -n "$missing_detail" ] \
     && [ -z "${missing_detail##*aaa-stray*}" ]; then
    _pass "D1: all memory stores are scanned; the stray store's missing index flags, attributed to its store"
  else
    _fail "D1: all memory stores are scanned; the stray store's missing index flags, attributed to its store" \
          "expected pillar 2 < 20 + missing-index gap naming aaa-stray, got score=[$p2] detail=[$missing_detail]"
  fi
}
_test_d1_all_memory_stores_scanned

# --- D1b: an explicit $CLAUDE_PRIMARY_MEMORY_DIR pins the scan to that ONE
# store (<TEAM>-366: the pin has always meant single-store scoring — with the pin
# set, the config's other stores are intentionally out of scope).
_test_d1_explicit_primary_override() {
  command -v jq >/dev/null 2>&1 || { _skip "D1 explicit-override test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  local cfg="$fixture/config" pinned="$fixture/pinned-memory"
  mkdir -p "$cfg/projects/only/memory" "$pinned"
  # The config's sole memory dir is BROKEN (no MEMORY.md). The pinned dir is clean.
  printf 'x\n' > "$cfg/projects/only/memory/note.md"
  cat > "$pinned/MEMORY.md" <<'EOF'
# Memory Index

- [Proj](project_pinned.md) — pinned active project
EOF
  cat > "$pinned/project_pinned.md" <<'EOF'
---
name: project_pinned
metadata:
  type: project
---
pinned project body
EOF
  local out p2
  out="$(env -u OBSIDIAN_VAULT_PATH CLAUDE_PRIMARY_MEMORY_DIR="$pinned" \
          bash "$REPO_ROOT/scripts/self-audit.sh" \
          --repo-root "$fixture" --config-dir "$cfg" --json 2>/dev/null)"
  p2="$(_sa_pillar_score "$out" "memory-hygiene")"
  rm -rf "$fixture"
  assert_eq "D1b: CLAUDE_PRIMARY_MEMORY_DIR pins the memory surface over the heuristic" \
    "20" "$p2"
}
_test_d1_explicit_primary_override

# --- D1h: an EMPTY auto-created store (zero *.md files — e.g. a
# projects/<tmp-cwd-slug>/memory dir a harness auto-creates for a session run
# out of a temp dir) must NOT floor Pillar 2: it is named informationally in
# skipped[] and excluded from scoring, while the healthy sibling store keeps
# its clean 20/20. Teeth kept: a store WITH notes but no MEMORY.md still
# deducts (D1 above pins that case).
_test_d1h_empty_store_not_scored() {
  command -v jq >/dev/null 2>&1 || { _skip "D1h empty-store test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  local cfg="$fixture/config"
  mkdir -p "$cfg/projects/-private-tmp/memory" "$cfg/projects/zzz-primary/memory"
  cat > "$cfg/projects/zzz-primary/memory/MEMORY.md" <<'EOF'
# Memory Index

- [Proj](project_real.md) — the operator's active project
EOF
  cat > "$cfg/projects/zzz-primary/memory/project_real.md" <<'EOF'
---
name: project_real
metadata:
  type: project
---
real project body
EOF
  local out p2 empty_note
  out="$(env -u OBSIDIAN_VAULT_PATH -u CLAUDE_PRIMARY_MEMORY_DIR -u CODEX_HOME \
          bash "$REPO_ROOT/scripts/self-audit.sh" \
          --repo-root "$fixture" --config-dir "$cfg" --json 2>/dev/null)"
  p2="$(_sa_pillar_score "$out" "memory-hygiene")"
  empty_note="$(printf '%s' "$out" | jq -r \
    '.skipped[] | select(contains("empty memory store"))' | head -1)"
  rm -rf "$fixture"
  if [ "$p2" = "20" ] && [ -n "$empty_note" ] \
     && [ -z "${empty_note##*-private-tmp*}" ]; then
    _pass "D1h: an empty memory store is named informationally and does not floor pillar 2"
  else
    _fail "D1h: an empty memory store is named informationally and does not floor pillar 2" \
          "expected pillar 2 == 20 + an empty-store skipped line naming -private-tmp, got score=[$p2] note=[$empty_note]"
  fi
}
_test_d1h_empty_store_not_scored

# --- D1i: when EVERY resolved store is empty, the pillar must report
# UNSCORED (a cannot-run check fails loudly), never a clean 20/20 and never
# a spurious missing-index 0/20.
_test_d1i_all_empty_stores_unscored() {
  command -v jq >/dev/null 2>&1 || { _skip "D1i all-empty-stores test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  local cfg="$fixture/config"
  mkdir -p "$cfg/projects/aaa-empty/memory" "$cfg/projects/bbb-empty/memory"
  local out unscored note
  out="$(env -u OBSIDIAN_VAULT_PATH -u CLAUDE_PRIMARY_MEMORY_DIR -u CODEX_HOME \
          bash "$REPO_ROOT/scripts/self-audit.sh" \
          --repo-root "$fixture" --config-dir "$cfg" --json 2>/dev/null)"
  unscored="$(printf '%s' "$out" | jq -r '.pillars["memory-hygiene"].unscored')"
  note="$(printf '%s' "$out" | jq -r '.pillars["memory-hygiene"].notes')"
  rm -rf "$fixture"
  if [ "$unscored" = "true" ] && [ -z "${note##*all resolved memory stores are empty*}" ]; then
    _pass "D1i: all-empty stores report pillar 2 UNSCORED with the named reason"
  else
    _fail "D1i: all-empty stores report pillar 2 UNSCORED with the named reason" \
          "expected unscored=true + all-empty note, got unscored=[$unscored] note=[$note]"
  fi
}
_test_d1i_all_empty_stores_unscored

# --- D2: local.env is sourced so the no-flag run reads operator config from
# local.env (reproducible across shells), not the ambient environment only. The
# old script read $OBSIDIAN_VAULT_PATH from env ONLY, so a shell that had not
# exported it silently SKIPPED the vault layer (the 60-vs-80 score divergence).
# Proof: with local.env supplying the vault, the vault surface must NOT be in the
# skipped list — and must resolve identically whether or not a DIFFERENT ambient
# OBSIDIAN_VAULT_PATH is exported (local.env wins → reproducible).
_test_d2_localenv_sourced_reproducible() {
  command -v jq >/dev/null 2>&1 || { _skip "D2 local.env-sourced test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  mkdir -p "$fixture/vault/01-Projects"
  # Quote the value to match the canonical local.env format (the PS twin's
  # Get-SaLocalEnvValue mangles an unquoted Windows backslash path via its
  # bash-%q collapse; quoting is the cross-platform-safe shape).
  printf 'OBSIDIAN_VAULT_PATH="%s/vault"\n' "$fixture" > "$fixture/local.env"

  # Run A — NO ambient OBSIDIAN_VAULT_PATH. Vault must resolve from local.env.
  local out_a vault_skipped_a
  out_a="$(env -u OBSIDIAN_VAULT_PATH -u CLAUDE_CONFIG_DIR \
            bash "$REPO_ROOT/scripts/self-audit.sh" --repo-root "$fixture" --json 2>/dev/null)"
  vault_skipped_a="$(printf '%s' "$out_a" | jq -r '.skipped[] | select(contains("vault dir not configured"))' | head -1)"

  # Run B — a DIFFERENT (bogus) ambient OBSIDIAN_VAULT_PATH. local.env must still
  # win → vault resolved from local.env → not skipped → reproducible vs run A.
  local out_b vault_skipped_b
  out_b="$(env -u CLAUDE_CONFIG_DIR OBSIDIAN_VAULT_PATH="/nonexistent/ambient/vault" \
            bash "$REPO_ROOT/scripts/self-audit.sh" --repo-root "$fixture" --json 2>/dev/null)"
  vault_skipped_b="$(printf '%s' "$out_b" | jq -r '.skipped[] | select(contains("vault dir not configured"))' | head -1)"
  rm -rf "$fixture"

  if [ -z "$vault_skipped_a" ] && [ -z "$vault_skipped_b" ]; then
    _pass "D2: local.env is read (vault resolved) + wins over ambient env → reproducible"
  else
    _fail "D2: local.env is read (vault resolved) + wins over ambient env → reproducible" \
          "expected vault NOT skipped in either run; got skipped_a=[$vault_skipped_a] skipped_b=[$vault_skipped_b]"
  fi
}
_test_d2_localenv_sourced_reproducible

# --- D3: the orphan-recipe check recognizes recipes routed BY NAME (session-agent
# R3 / playbooks / core), not only via `verification:` frontmatter. A recipe named
# in a routing doc (the shape of audit-systems / docs-framework / tool-freshness)
# must NOT be flagged orphan — the old frontmatter-only grep false-flagged them.
_test_d3_recipe_routed_by_name_not_orphan() {
  command -v jq >/dev/null 2>&1 || { _skip "D3 by-name reference test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  cat > "$fixture/verification/by-name-gate.md" <<'EOF'
# By-name-routed verification recipe
EOF
  mkdir -p "$fixture/core"
  cat > "$fixture/core/routing.md" <<'EOF'
# Routing
Choose the matching gate from verification/ — e.g. `by-name-gate`, `example`.
EOF
  local out score orphan_gap
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" --json 2>/dev/null)"
  score="$(_sa_pillar_score "$out" "verification-coverage")"
  orphan_gap="$(printf '%s' "$out" | jq -r '.gaps[] | select(.title|contains("Orphan verification")) | .title' | head -1)"
  rm -rf "$fixture"
  if [ "$score" = "20" ] && [ -z "$orphan_gap" ]; then
    _pass "D3: a recipe routed by NAME (not via verification: frontmatter) is not flagged orphan"
  else
    _fail "D3: a recipe routed by NAME (not via verification: frontmatter) is not flagged orphan" \
          "expected 20/20 + no orphan gap, got score=[$score] orphan_gap=[$orphan_gap]"
  fi
}
_test_d3_recipe_routed_by_name_not_orphan

# --- D3b: the check keeps its teeth — a recipe named NOWHERE outside verification/
# is still flagged orphan (guards against the widening becoming vacuous).
_test_d3_truly_dangling_recipe_still_flagged() {
  command -v jq >/dev/null 2>&1 || { _skip "D3 teeth test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  cat > "$fixture/verification/dangling-nowhere.md" <<'EOF'
# A recipe referenced by no capability, playbook, or routing doc.
EOF
  local out score orphan_gap
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" --json 2>/dev/null)"
  score="$(_sa_pillar_score "$out" "verification-coverage")"
  orphan_gap="$(printf '%s' "$out" | jq -r '.gaps[] | select(.title|contains("Orphan verification")) | .title' | head -1)"
  rm -rf "$fixture"
  if [ -n "$score" ] && [ "$score" -lt 20 ] && [ -n "$orphan_gap" ]; then
    _pass "D3b: a genuinely-dangling recipe (named nowhere) is still flagged orphan — check keeps its teeth"
  else
    _fail "D3b: a genuinely-dangling recipe (named nowhere) is still flagged orphan — check keeps its teeth" \
          "expected score < 20 + orphan gap, got score=[$score] orphan_gap=[$orphan_gap]"
  fi
}
_test_d3_truly_dangling_recipe_still_flagged

# --- D1c (Codex review): a CLAUDE_PRIMARY_MEMORY_DIR pin in local.env wins over
# an ambient CLAUDE_PRIMARY_MEMORY_DIR (local.env > ambient precedence).
_test_d1c_localenv_primary_wins_over_ambient() {
  command -v jq >/dev/null 2>&1 || { _skip "D1c local.env-primary-wins test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  local cfg="$fixture/config" good="$fixture/good-memory" bad="$fixture/bad-memory"
  mkdir -p "$cfg/projects/only/memory" "$good" "$bad"
  printf 'x\n' > "$cfg/projects/only/memory/note.md"
  # good (pinned via local.env): clean index → pillar 2 = 20.
  cat > "$good/MEMORY.md" <<'EOF'
# Memory Index

- [Proj](project_g.md) — active
EOF
  cat > "$good/project_g.md" <<'EOF'
---
name: project_g
metadata:
  type: project
---
body
EOF
  # bad (ambient pin target): no MEMORY.md → pillar 2 would be 0 if selected.
  printf 'stray\n' > "$bad/stray.md"
  # Quote the value (see D2) — canonical, cross-platform-safe local.env shape.
  printf 'CLAUDE_PRIMARY_MEMORY_DIR="%s"\n' "$good" > "$fixture/local.env"
  local out p2
  out="$(env -u OBSIDIAN_VAULT_PATH CLAUDE_PRIMARY_MEMORY_DIR="$bad" \
          bash "$REPO_ROOT/scripts/self-audit.sh" \
          --repo-root "$fixture" --config-dir "$cfg" --json 2>/dev/null)"
  p2="$(_sa_pillar_score "$out" "memory-hygiene")"
  rm -rf "$fixture"
  assert_eq "D1c: local.env CLAUDE_PRIMARY_MEMORY_DIR wins over ambient" "20" "$p2"
}
_test_d1c_localenv_primary_wins_over_ambient

# --- D1d (<TEAM>-366): a hygiene signal in the NON-largest store is scored. Two
# indexed stores; the orphan note lives in bbb-tie — the store the old tie-break
# never scanned (this exact fixture used to assert the orphan stayed INVISIBLE).
# The aggregate scan must surface it, attributed to its store, while the clean
# store contributes no orphan gap.
_test_d1d_signal_in_secondary_store_scored() {
  command -v jq >/dev/null 2>&1 || { _skip "D1d secondary-store-signal test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  local cfg="$fixture/config"
  mkdir -p "$cfg/projects/aaa-tie/memory" "$cfg/projects/bbb-tie/memory"
  # Both have MEMORY.md + exactly ONE project note. aaa-tie is clean; bbb-tie
  # also carries an orphan memory file. Aggregation must deduct for the orphan.
  cat > "$cfg/projects/aaa-tie/memory/MEMORY.md" <<'EOF'
# Memory Index

- [A](project_a.md) — clean
EOF
  cat > "$cfg/projects/aaa-tie/memory/project_a.md" <<'EOF'
---
name: project_a
metadata:
  type: project
---
a
EOF
  cat > "$cfg/projects/bbb-tie/memory/MEMORY.md" <<'EOF'
# Memory Index

- [B](project_b.md) — has an orphan sibling
EOF
  cat > "$cfg/projects/bbb-tie/memory/project_b.md" <<'EOF'
---
name: project_b
metadata:
  type: project
---
b
EOF
  printf 'orphan\n' > "$cfg/projects/bbb-tie/memory/feedback_orphan.md"
  local out p2 orphan_detail
  out="$(env -u OBSIDIAN_VAULT_PATH -u CLAUDE_PRIMARY_MEMORY_DIR \
          bash "$REPO_ROOT/scripts/self-audit.sh" \
          --repo-root "$fixture" --config-dir "$cfg" --json 2>/dev/null)"
  p2="$(_sa_pillar_score "$out" "memory-hygiene")"
  orphan_detail="$(printf '%s' "$out" | jq -r \
    '.gaps[] | select(.title | contains("Orphan memory file")) | .detail' | head -1)"
  rm -rf "$fixture"
  if [ -n "$p2" ] && [ "$p2" -lt 20 ] && [ -n "$orphan_detail" ] \
     && [ -z "${orphan_detail##*bbb-tie*}" ]; then
    _pass "D1d: an orphan in the secondary (non-largest) store is scored + attributed to that store"
  else
    _fail "D1d: an orphan in the secondary (non-largest) store is scored + attributed to that store" \
          "expected pillar 2 < 20 + orphan gap naming bbb-tie, got score=[$p2] detail=[$orphan_detail]"
  fi
}
_test_d1d_signal_in_secondary_store_scored

# --- D1e (<TEAM>-366): aggregation spans pillars — each store's own MEMORY.md is
# link-walked (pillar 1) while the other store's hygiene is scored (pillar 2),
# in the same run. Store A has a broken index link; store B has an orphan note.
_test_d1e_cross_pillar_aggregation() {
  command -v jq >/dev/null 2>&1 || { _skip "D1e cross-pillar aggregation test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  local cfg="$fixture/config"
  mkdir -p "$cfg/projects/aaa-links/memory" "$cfg/projects/bbb-orphan/memory"
  cat > "$cfg/projects/aaa-links/memory/MEMORY.md" <<'EOF'
# Memory Index

- [Missing](does_not_exist.md) — broken link in store A
EOF
  cat > "$cfg/projects/bbb-orphan/memory/MEMORY.md" <<'EOF'
# Memory Index

(no entries)
EOF
  printf 'orphan\n' > "$cfg/projects/bbb-orphan/memory/feedback_orphan.md"
  local out p1 p2 link_detail
  out="$(env -u OBSIDIAN_VAULT_PATH -u CLAUDE_PRIMARY_MEMORY_DIR \
          bash "$REPO_ROOT/scripts/self-audit.sh" \
          --repo-root "$fixture" --config-dir "$cfg" --json 2>/dev/null)"
  p1="$(_sa_pillar_score "$out" "cross-layer-handoffs")"
  p2="$(_sa_pillar_score "$out" "memory-hygiene")"
  link_detail="$(printf '%s' "$out" | jq -r \
    '.gaps[] | select(.title | contains("Broken MEMORY.md link")) | .detail' | head -1)"
  rm -rf "$fixture"
  if [ -n "$p1" ] && [ "$p1" -lt 20 ] && [ -n "$p2" ] && [ "$p2" -lt 20 ] \
     && [ -n "$link_detail" ] && [ -z "${link_detail##*aaa-links*}" ]; then
    _pass "D1e: one run scores store A's broken index link AND store B's orphan, each attributed"
  else
    _fail "D1e: one run scores store A's broken index link AND store B's orphan, each attributed" \
          "expected p1 < 20 + p2 < 20 + link gap naming aaa-links, got p1=[$p1] p2=[$p2] detail=[$link_detail]"
  fi
}
_test_d1e_cross_pillar_aggregation

# --- D1f (<TEAM>-366, panel: Codex + Gemini): an explicit --memory-dir means
# exactly ONE store even when the config dir holds other discoverable stores
# with gaps AND a CLAUDE_PRIMARY_MEMORY_DIR pin points at the broken store —
# the full precedence is flag > pin > discovery.
_test_d1f_flag_excludes_discovered_stores() {
  command -v jq >/dev/null 2>&1 || { _skip "D1f flag-excludes-discovery test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  local cfg="$fixture/config" flagged="$fixture/flagged-memory"
  mkdir -p "$cfg/projects/broken/memory" "$flagged"
  # The discoverable store is BROKEN (a note, no MEMORY.md); the flagged store is clean.
  printf 'x\n' > "$cfg/projects/broken/memory/note.md"
  cat > "$flagged/MEMORY.md" <<'EOF'
# Memory Index

- [Proj](project_f.md) — flagged active project
EOF
  cat > "$flagged/project_f.md" <<'EOF'
---
name: project_f
metadata:
  type: project
---
flagged project body
EOF
  local out p2
  # Pin the AMBIENT env at the broken store: the explicit flag must still win.
  out="$(env -u OBSIDIAN_VAULT_PATH CLAUDE_PRIMARY_MEMORY_DIR="$cfg/projects/broken/memory" \
          bash "$REPO_ROOT/scripts/self-audit.sh" \
          --repo-root "$fixture" --config-dir "$cfg" --memory-dir "$flagged" --json 2>/dev/null)"
  p2="$(_sa_pillar_score "$out" "memory-hygiene")"
  rm -rf "$fixture"
  assert_eq "D1f: an explicit --memory-dir scans exactly one store — flag wins over the pin and over discovery" \
    "20" "$p2"
}
_test_d1f_flag_excludes_discovered_stores

# --- D3c (Codex review): the token boundary is precise — a recipe name that is
# only a SUBSTRING of other words ("database", "data-driven") is still orphan.
_test_d3c_boundary_no_substring_match() {
  command -v jq >/dev/null 2>&1 || { _skip "D3c boundary test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  cat > "$fixture/verification/data.md" <<'EOF'
# A recipe named "data"
EOF
  mkdir -p "$fixture/core"
  # Mentions "database" and "data-driven" but never the bare token "data".
  cat > "$fixture/core/routing.md" <<'EOF'
# Routing
Use the database layer and a data-driven approach.
EOF
  local out score orphan_gap
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" --json 2>/dev/null)"
  score="$(_sa_pillar_score "$out" "verification-coverage")"
  orphan_gap="$(printf '%s' "$out" | jq -r '.gaps[] | select(.title|contains("Orphan verification")) | .title' | head -1)"
  rm -rf "$fixture"
  if [ -n "$score" ] && [ "$score" -lt 20 ] && [ -n "$orphan_gap" ]; then
    _pass "D3c: recipe 'data' is NOT matched by 'database'/'data-driven' substrings — still orphan"
  else
    _fail "D3c: recipe 'data' is NOT matched by 'database'/'data-driven' substrings — still orphan" \
          "expected score < 20 + orphan gap, got score=[$score] orphan_gap=[$orphan_gap]"
  fi
}
_test_d3c_boundary_no_substring_match

# --- D2b (Codex review): a local.env vault path WITH A SPACE (the operator's
# real "Claude - Local" shape), double-quoted, resolves — not skipped.
_test_d2b_localenv_space_path() {
  command -v jq >/dev/null 2>&1 || { _skip "D2b space-path test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  mkdir -p "$fixture/my vault/01-Projects"
  printf 'OBSIDIAN_VAULT_PATH="%s/my vault"\n' "$fixture" > "$fixture/local.env"
  local out vault_skipped
  out="$(env -u OBSIDIAN_VAULT_PATH -u CLAUDE_CONFIG_DIR \
          bash "$REPO_ROOT/scripts/self-audit.sh" --repo-root "$fixture" --json 2>/dev/null)"
  vault_skipped="$(printf '%s' "$out" | jq -r '.skipped[] | select(contains("vault dir not configured"))' | head -1)"
  rm -rf "$fixture"
  if [ -z "$vault_skipped" ]; then
    _pass "D2b: a quoted local.env vault path with a space resolves (operator 'Claude - Local' shape)"
  else
    _fail "D2b: a quoted local.env vault path with a space resolves (operator 'Claude - Local' shape)" \
          "expected vault NOT skipped, got [$vault_skipped]"
  fi
}
_test_d2b_localenv_space_path

# --- F1 (Codex pre-merge review): bash must NOT source local.env — it parses the
# 3 config keys as DATA. A hostile local.env (a command substitution + a PATH=
# poisoning line) run non-isolated must have NO side effect — no arbitrary code,
# no PATH poisoning — while the legitimate OBSIDIAN_VAULT_PATH key is still read.
# The old `set -a;. local.env` would have executed the $(touch...) line; the
# parse-as-data fix does not. Guards the bash<->PS security-posture parity.
_test_f1_localenv_not_sourced() {
  command -v jq >/dev/null 2>&1 || { _skip "F1 local.env-not-sourced test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  mkdir -p "$fixture/vault/01-Projects"
  local pwned="$fixture/PWNED"
  # Written with single-quoted printf formats so the TEST shell does not expand
  # them: the file gets a literal `$(touch...)` line + a literal PATH= line. If
  # self-audit SOURCED this, $pwned would be created and PATH poisoned.
  {
    printf 'OBSIDIAN_VAULT_PATH="%s/vault"\n' "$fixture"
    printf '$(touch "%s")\n' "$pwned"
    printf 'PATH="/nonexistent/evil:$PATH"\n'
  } > "$fixture/local.env"
  local out vault_skipped executed="no"
  out="$(env -u OBSIDIAN_VAULT_PATH -u CLAUDE_CONFIG_DIR \
          bash "$REPO_ROOT/scripts/self-audit.sh" --repo-root "$fixture" --json 2>/dev/null)"
  vault_skipped="$(printf '%s' "$out" | jq -r '.skipped[] | select(contains("vault dir not configured"))' | head -1)"
  [ -e "$pwned" ] && executed="yes"
  rm -rf "$fixture"
  if [ "$executed" = "no" ] && [ -z "$vault_skipped" ]; then
    _pass "F1: bash reads local.env as DATA — no arbitrary-code side effect, vault still resolved"
  else
    _fail "F1: bash reads local.env as DATA — no arbitrary-code side effect, vault still resolved" \
          "expected executed=no + vault NOT skipped, got executed=[$executed] vault_skipped=[$vault_skipped]"
  fi
}
_test_f1_localenv_not_sourced

# --- UNSCORED pillars: a clean clone with NO operator surfaces (no Linear, no
# memory dir, no vault) must NOT manufacture a false ~100/100. A pillar that can
# run zero real checks is floored to 0 and flagged UNSCORED (core/verification.md:
# a check that cannot run must fail, never pass), so the total lands well below the
# ~95-100 "in good shape" band the seed-20 bug produced.
_test_unscored_pillars_no_false_100() {
  command -v jq >/dev/null 2>&1 || { _skip "unscored-pillars false-100 test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  # No --memory-dir, no --vault-dir, --isolated (no linear CLI) → the cross-layer and
  # memory pillars can measure nothing.
  local out p1 p2 p1u p2u uc total
  out="$(env -u OBSIDIAN_VAULT_PATH -u CLAUDE_PRIMARY_MEMORY_DIR -u CLAUDE_CONFIG_DIR \
          bash "$REPO_ROOT/scripts/self-audit.sh" \
          --repo-root "$fixture" --isolated --json 2>/dev/null)"
  p1="$(_sa_pillar_score "$out" "cross-layer-handoffs")"
  p2="$(_sa_pillar_score "$out" "memory-hygiene")"
  p1u="$(printf '%s' "$out" | jq -r '.pillars["cross-layer-handoffs"].unscored')"
  p2u="$(printf '%s' "$out" | jq -r '.pillars["memory-hygiene"].unscored')"
  uc="$(printf '%s' "$out" | jq -r '.unscored_count')"
  total="$(printf '%s' "$out" | jq -r '.total')"
  rm -rf "$fixture"
  assert_eq "unscored: cross-layer pillar floored to 0 when no surface reachable" "0" "$p1"
  assert_eq "unscored: memory pillar floored to 0 when no surface reachable" "0" "$p2"
  assert_eq "unscored: cross-layer pillar flagged unscored=true" "true" "$p1u"
  assert_eq "unscored: memory pillar flagged unscored=true" "true" "$p2u"
  assert_eq "unscored: unscored_count counts both unmeasured pillars" "2" "$uc"
  # Two UNSCORED pillars cap the achievable total at 60 → cannot reach the
  # ~95-100 "in good shape" band that the false-100 bug reported.
  if [ "$total" -lt 95 ]; then
    _pass "unscored: no-surface clone total ($total) is below the 'in good shape' band"
  else
    _fail "unscored: no-surface clone total below 'in good shape' band" \
          "got total=$total (expected <95)"
  fi
}
_test_unscored_pillars_no_false_100

# --- <TEAM>-370 twin-parity guard: EQUAL-leverage gaps keep insertion order
# after the leverage-descending sort. Pre-fix the twins disagreed on the same
# fixture: bash `sort -nr`'s reversed whole-line last-resort comparison emitted
# equal-leverage gaps in DESCENDING pillar/text order, while the PS twin's
# stable Sort-Object preserved insertion order. Both twins now sort on explicit
# (leverage desc, insertion index asc) keys. Fixture: two leverage-4 gaps —
# pillar 1 (broken MEMORY.md link) is recorded before pillar 5 (missing
# ## State Deltas), so the pillar-1 gap must emit first. The PS twin asserts
# the SAME expected order on the SAME fixture; that shared expectation is the
# parity contract (each CI lane runs one twin).
_test_equal_leverage_gap_order_insertion() {
  command -v jq >/dev/null 2>&1 || { _skip "equal-leverage gap-order test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"

  local mem; mem="$(mktemp -d)" || { rm -rf "$fixture"; return 1; }
  # MEMORY.md indexes the project note (no pillar-2 orphan) and links one
  # missing file → pillar 1 "Broken MEMORY.md link(s)" at leverage 4.
  cat > "$mem/MEMORY.md" <<'EOF'
# Memory Index

- [Proj](project_recent.md) — active project note
- [Missing](does_not_exist.md) — broken link target
EOF
  # A fresh (mtime now → inside the 7-day window) project-type note without
  # '## State Deltas' → pillar 5 "Recent project memory lacks ## State Deltas"
  # at leverage 4. No other sub-check fires at leverage 4 on this fixture.
  cat > "$mem/project_recent.md" <<'EOF'
---
name: project_recent
metadata:
  type: project
---
recent project body, deliberately without a state-deltas section
EOF

  local out lev4_titles
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated \
          --repo-root "$fixture" \
          --memory-dir "$mem" --json 2>/dev/null)"
  lev4_titles="$(printf '%s' "$out" | jq -r '[.gaps[] | select(.leverage == 4) | .title] | join("|")')"
  rm -rf "$fixture" "$mem"

  assert_eq "equal-leverage gaps emit in insertion order (pillar 1 before pillar 5) — twin-parity tie-break" \
    "Broken MEMORY.md link(s)|Recent project memory lacks ## State Deltas" \
    "$lev4_titles"
}
_test_equal_leverage_gap_order_insertion

# --- <TEAM>-371 twin-parity guard: multi-hit gap RECORDING order is
# traversal-independent. Pre-fix, pillar 3.2's per-dir gaps recorded in raw
# find / Get-ChildItem enumeration order (filesystem-dependent), so two dirs
# matching the same anti-pattern name could emit in different orders across
# twins or machines even after the <TEAM>-370 emit-side tie-break (equal
# leverage preserves INSERTION order — which was itself nondeterministic).
# Both twins now sort the enumeration (LC_ALL=C / ordinal — the same byte
# order for ASCII names). Fixture: zeta/tmp is created BEFORE alpha/tmp; the
# alpha/tmp gap must record (and so emit) first regardless of creation or
# enumeration order. The PS twin asserts the SAME expected order on the SAME
# fixture; that shared expectation is the parity contract.
_test_antipattern_gap_order_sorted() {
  command -v jq >/dev/null 2>&1 || { _skip "anti-pattern gap-order test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  # Creation order deliberately reversed vs byte order; both dirs kept
  # non-empty so sub-check 3.1 (empty dirs) stays out of the picture.
  mkdir -p "$fixture/zeta/tmp" "$fixture/alpha/tmp"
  printf 'keep\n' > "$fixture/zeta/tmp/keep.txt"
  printf 'keep\n' > "$fixture/alpha/tmp/keep.txt"

  local out details fx
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" --json 2>/dev/null)"
  details="$(printf '%s' "$out" | jq -r '[.gaps[] | select(.title == "Anti-pattern directory name") | .detail] | join("|")')"
  # Gap details carry the host-native forward-slash spelling on Windows; build
  # the expectation in the same spelling (tests/lib.sh native_path_fwd) so the
  # assert is path-shape-agnostic. Resolve before the fixture is removed.
  fx="$(native_path_fwd "$fixture")"
  rm -rf "$fixture"

  assert_eq "anti-pattern multi-hit gaps record in C-sorted path order (alpha before zeta) — twin-parity traversal determinism" \
    "$fx/alpha/tmp uses a name (\"tmp\") that signals undisciplined accretion|$fx/zeta/tmp uses a name (\"tmp\") that signals undisciplined accretion" \
    "$details"
}
_test_antipattern_gap_order_sorted

# --- <TEAM>-371 twin-parity guard: spine-asymmetry gap order derives from the
# SORTED capability enumeration. bb-caps.md is created before aa-caps.md and
# is the only declarer of the second harness; pre-fix an unsorted enumeration
# (PS Get-ChildItem; locale-collated bash glob) could surface Foxtrot's gap
# before Echo's or scramble a gap's missing_for list. Post-fix both twins
# enumerate aa-caps, bb-caps (byte order): harness-union first-seen order is
# echo then foxtrot, and echo's missing_for is "aa-caps bb-caps".
_test_spine_asymmetry_gap_order_sorted() {
  command -v jq >/dev/null 2>&1 || { _skip "spine-asymmetry gap-order test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  cat > "$fixture/capabilities/bb-caps.md" <<'EOF'
---
name: bb-caps
summary: fixture capability
triggers: [test]
verification: example
harnesses: [echo, foxtrot]
kind: native
lifecycle: shipped
---

# bb-caps
EOF
  cat > "$fixture/capabilities/aa-caps.md" <<'EOF'
---
name: aa-caps
summary: fixture capability
triggers: [test]
verification: example
harnesses: [echo]
kind: native
lifecycle: shipped
---

# aa-caps
EOF

  local out titles echo_detail
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" --json 2>/dev/null)"
  titles="$(printf '%s' "$out" | jq -r '[.gaps[] | select(.title | startswith("Spine asymmetry")) | .title] | join("|")')"
  echo_detail="$(printf '%s' "$out" | jq -r '[.gaps[] | select(.title == "Spine asymmetry: missing Echo realization(s)") | .detail] | first')"
  rm -rf "$fixture"

  assert_eq "spine-asymmetry gaps record per sorted cap enumeration (Echo before Foxtrot) — twin-parity traversal determinism" \
    "Spine asymmetry: missing Echo realization(s)|Spine asymmetry: missing Foxtrot realization(s)" \
    "$titles"
  assert_eq "spine-asymmetry missing_for names follow sorted cap enumeration (aa-caps before bb-caps)" \
    "Native capability(s) without harnesses/echo/capabilities/<name>.md: aa-caps bb-caps" \
    "$echo_detail"
}
_test_spine_asymmetry_gap_order_sorted

# --- <TEAM>-371 panel ask: a fixture with NO capabilities/ dir must not trip
# the new find-based enumeration — the suppressed find yields zero rows, the
# script completes, and no spine-asymmetry gap records. Pins the missing-dir
# edge the glob→find swap could have changed.
_test_spine_no_capabilities_dir() {
  command -v jq >/dev/null 2>&1 || { _skip "no-capabilities-dir test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  rm -rf "$fixture/capabilities"

  local out total_type spine_count
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" --json 2>/dev/null)"
  total_type="$(printf '%s' "$out" | jq -r '.total | type')"
  spine_count="$(printf '%s' "$out" | jq -r '[.gaps[] | select(.title | startswith("Spine asymmetry"))] | length')"
  rm -rf "$fixture"

  assert_eq "no capabilities/ dir: script still emits valid JSON (find-based enumeration yields zero rows)" \
    "number" "$total_type"
  assert_eq "no capabilities/ dir: no spine-asymmetry gap records" \
    "0" "$spine_count"
}
_test_spine_no_capabilities_dir

# Helper (<TEAM>-364): injection-surface fixture layered on _sa_mk_fixture_repo —
# a fake config dir with a rendered CLAUDE.md, one memory store whose MEMORY.md
# is the only file (no orphan / broken-link interactions), and a vault whose
# START.md names an identity note via the FIRST wikilink (aliased, to exercise
# the |alias strip) BEFORE the `## Read Order` heading — the mechanical
# resolution rule sub-check 2.4 implements. Components total well over 1 KB so
# `--injection-warn-kb 1` trips the warn and a huge threshold does not.
_sa_mk_injection_fixture() {
  local root="$1" i
  _sa_mk_fixture_repo "$root"
  mkdir -p "$root/config" "$root/mem" "$root/vault"
  { printf '# Rendered CLAUDE.md\n'
    for i in $(seq 1 20); do printf 'entrypoint padding line for the injection surface fixture\n'; done
  } > "$root/config/CLAUDE.md"
  { printf '# Memory Index\n\n'
    for i in $(seq 1 12); do printf -- '- headline entry %s — short, under the per-line cap\n' "$i"; done
  } > "$root/mem/MEMORY.md"
  cat > "$root/vault/START.md" <<'EOF'
# START

## Who You're Working For

Work for [[Operator Profile|the operator]] first.

## Read Order

1. [[Memory Core]]
EOF
  printf '# Operator Profile\n\nidentity note body for the injection fixture\n' > "$root/vault/Operator Profile.md"
}

# --- <TEAM>-364 (a): over the soft threshold → warned=true, a pillar-2 gap, and
# the 2-pt deduction (18/20 — the fixture is otherwise clean). The identity
# component must resolve THROUGH the |alias to the note named before
# ## Read Order, not to the [[Memory Core]] link inside the read order.
_test_injection_surface_warns_over_threshold() {
  command -v jq >/dev/null 2>&1 || { _skip "injection-surface warn test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_injection_fixture "$fixture"

  local out warned gap p2 comp_count id_path
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated \
          --repo-root "$fixture" --memory-dir "$fixture/mem" \
          --config-dir "$fixture/config" --vault-dir "$fixture/vault" \
          --injection-warn-kb 1 --json 2>/dev/null)"
  warned="$(printf '%s' "$out" | jq -r '.injection_surface.warned')"
  gap="$(printf '%s' "$out" | jq -r '.gaps[] | select(.title == "Injection surface over soft threshold") | .title' | head -1)"
  p2="$(_sa_pillar_score "$out" "memory-hygiene")"
  comp_count="$(printf '%s' "$out" | jq -r '.injection_surface.components | length')"
  id_path="$(printf '%s' "$out" | jq -r '.injection_surface.components[] | select(.name == "identity note") | .path')"
  rm -rf "$fixture"

  assert_eq "injection surface: warned=true when total exceeds --injection-warn-kb 1" "true" "$warned"
  assert_eq "injection surface: pillar-2 gap titled 'Injection surface over soft threshold' recorded" \
    "Injection surface over soft threshold" "$gap"
  assert_eq "injection surface: pillar 2 reflects the 2-pt soft deduction" "18" "$p2"
  assert_eq "injection surface: all four components resolve on the full fixture" "4" "$comp_count"
  if [ -n "$id_path" ] && [ -z "${id_path##*Operator Profile.md}" ]; then
    _pass "injection surface: identity note resolves via first pre-Read-Order wikilink (alias stripped)"
  else
    _fail "injection surface: identity note resolves via first pre-Read-Order wikilink (alias stripped)" \
          "expected path ending 'Operator Profile.md', got [$id_path]"
  fi
}
_test_injection_surface_warns_over_threshold

# --- <TEAM>-364 (b): a huge threshold → no warn, no gap, no deduction. The
# measurement itself still reports (soft warn ≠ measurement gate).
_test_injection_surface_clean_under_threshold() {
  command -v jq >/dev/null 2>&1 || { _skip "injection-surface clean test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_injection_fixture "$fixture"

  local out warned gap p2
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated \
          --repo-root "$fixture" --memory-dir "$fixture/mem" \
          --config-dir "$fixture/config" --vault-dir "$fixture/vault" \
          --injection-warn-kb 4096 --json 2>/dev/null)"
  warned="$(printf '%s' "$out" | jq -r '.injection_surface.warned')"
  gap="$(printf '%s' "$out" | jq -r '[.gaps[] | select(.title == "Injection surface over soft threshold")] | length')"
  p2="$(_sa_pillar_score "$out" "memory-hygiene")"
  rm -rf "$fixture"

  assert_eq "injection surface: warned=false under a huge threshold" "false" "$warned"
  assert_eq "injection surface: no over-threshold gap under a huge threshold" "0" "$gap"
  assert_eq "injection surface: pillar 2 stays 20/20 under a huge threshold" "20" "$p2"
}
_test_injection_surface_clean_under_threshold

# --- <TEAM>-364 (c): markdown output carries the ## Injection surface section
# (between the pillar table and Top gaps) with per-component lines and the
# Total line naming the threshold + OK/OVER verdict.
_test_injection_surface_markdown_section() {
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_injection_fixture "$fixture"

  local out_over out_ok
  out_over="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated \
               --repo-root "$fixture" --memory-dir "$fixture/mem" \
               --config-dir "$fixture/config" --vault-dir "$fixture/vault" \
               --injection-warn-kb 1 2>/dev/null)"
  out_ok="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated \
             --repo-root "$fixture" --memory-dir "$fixture/mem" \
             --config-dir "$fixture/config" --vault-dir "$fixture/vault" \
             --injection-warn-kb 4096 2>/dev/null)"
  rm -rf "$fixture"

  assert_contains "injection surface markdown: section heading present" \
    "$out_over" "## Injection surface"
  assert_contains "injection surface markdown: per-component line present" \
    "$out_over" "MEMORY.md (largest store):"
  assert_contains "injection surface markdown: Total line says OVER past the threshold" \
    "$out_over" "soft threshold 1 KB (OVER)"
  assert_contains "injection surface markdown: Total line says OK under the threshold" \
    "$out_ok" "soft threshold 4096 KB (OK)"
}
_test_injection_surface_markdown_section

# --- <TEAM>-364 (d): a component that cannot resolve is SKIPPED by name, never
# an error — no vault dir → START.md + identity note both land in .skipped and
# the remaining two components still measure.
_test_injection_surface_skips_unresolved_components() {
  command -v jq >/dev/null 2>&1 || { _skip "injection-surface skip test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_injection_fixture "$fixture"

  local out skipped_list comp_count
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated \
          --repo-root "$fixture" --memory-dir "$fixture/mem" \
          --config-dir "$fixture/config" \
          --injection-warn-kb 4096 --json 2>/dev/null)"
  skipped_list="$(printf '%s' "$out" | jq -r '.injection_surface.skipped | join("|")')"
  comp_count="$(printf '%s' "$out" | jq -r '.injection_surface.components | length')"
  rm -rf "$fixture"

  assert_eq "injection surface: vault-side components listed in skipped when no vault dir" \
    "START.md (vault)|identity note" "$skipped_list"
  assert_eq "injection surface: the two resolvable components still measure" "2" "$comp_count"
}
_test_injection_surface_skips_unresolved_components

# --- <TEAM>-364 (e): when NO component resolves (no memory store, no config,
# no vault), the measurement is not-measured — JSON injection_surface is null
# (a distinct state from a 0-byte surface) and the markdown says so.
_test_injection_surface_null_when_nothing_resolves() {
  command -v jq >/dev/null 2>&1 || { _skip "injection-surface null test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"

  local out null_type md_out
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" --json 2>/dev/null)"
  null_type="$(printf '%s' "$out" | jq -r '.injection_surface | type')"
  md_out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" 2>/dev/null)"
  rm -rf "$fixture"

  assert_eq "injection surface: JSON injection_surface is null when nothing resolves" \
    "null" "$null_type"
  assert_contains "injection surface: markdown reports not-measured when nothing resolves" \
    "$md_out" "_(not measured — no injection-surface component resolved)_"
}
_test_injection_surface_null_when_nothing_resolves

# --- <TEAM>-394: codex-native memory registry — audit-covered, not canonical ---
# The registry gets its own pillar-2 surface (sub-check 2.5): index PRESENCE
# only. Its sidecars (memory_summary.md, raw_memories.md) are NOT index-addressed
# notes, so they must never trip the 2.1 orphan check.
# <TEAM>-468: the 2.2/2.3 recall caps are claude-side recall semantics and do NOT
# apply to the codex registry (no size cap or read-side truncation exists in
# openai/codex at rust-v0.144.1). Size is reported informationally instead —
# no deduction, no gap — and the registry is excluded from the sub-check-2.4
# injection-surface largest-store scan.
_sa_mk_codex_case() {  # <root> — clean claude store + codex registry skeleton
  mkdir -p "$1/mem" "$1/codex-mem/rollout_summaries"
  printf -- '- [note](note.md) — fixture note\n' > "$1/mem/MEMORY.md"
  printf 'body\n' > "$1/mem/note.md"
  printf -- '- codex fact one\n' > "$1/codex-mem/MEMORY.md"
  printf 'summary sidecar\n' > "$1/codex-mem/memory_summary.md"
  printf 'raw sidecar\n' > "$1/codex-mem/raw_memories.md"
}

_test_codex_registry_clean() {
  command -v jq >/dev/null 2>&1 || { _skip "codex-registry clean test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"; _sa_mk_codex_case "$fixture"
  local out score reg_bytes md_out
  reg_bytes="$(wc -c < "$fixture/codex-mem/MEMORY.md" | tr -d ' ')"
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" \
          --memory-dir "$fixture/mem" --codex-memory-dir "$fixture/codex-mem" --json 2>/dev/null)"
  md_out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" \
          --memory-dir "$fixture/mem" --codex-memory-dir "$fixture/codex-mem" 2>/dev/null)"
  score="$(_sa_pillar_score "$out" "memory-hygiene")"
  # <TEAM>-468: size is reported as an additive optional JSON field, and every
  # pre-existing top-level field keeps its name and position.
  local cx_bytes fields
  cx_bytes="$(printf '%s' "$out" | jq -r '.codex_registry_bytes')"
  fields="$(printf '%s' "$out" | jq -r 'keys_unsorted | join(",")')"
  rm -rf "$fixture"
  assert_eq "codex registry: clean registry + sidecars score 20/20 (no orphan false-trip)" "20" "$score"
  assert_not_contains "codex registry: sidecars never trip the orphan check" "$out" "Orphan memory file(s)"
  assert_eq "codex registry: JSON reports the registry byte size informationally" \
    "$reg_bytes" "$cx_bytes"
  # Panel finding (<TEAM>-468): the new field is appended LAST so every
  # pre-existing field keeps its POSITION as well as its name and shape.
  assert_eq "codex registry: JSON stays backward-compatible (existing fields keep position, new field appended last)" \
    "date,total,unscored_count,pillars,injection_surface,gaps,skipped,codex_registry_bytes,semantic_currentness,orientation_surface,recall_failures,operator_subgates" "$fields"
  assert_contains "codex registry: markdown carries the non-scoring informational size line" \
    "$md_out" "- codex memory registry (informational, not scored): $reg_bytes bytes"
}
_test_codex_registry_clean

# <TEAM>-468: the line-cap and size-cap deductions are GONE for the codex
# registry — the consolidator owns the registry format and no codex-side cap
# exists. Over-cap content must score a clean 20/20 with zero codex gaps, while
# the size still surfaces informationally.
_test_codex_registry_over_cap_content_is_informational_only() {
  command -v jq >/dev/null 2>&1 || { _skip "codex-registry over-cap test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"; _sa_mk_codex_case "$fixture"
  # A >300-char index line AND a total well over the 24400-byte claude-side cap,
  # in the CODEX registry only.
  printf -- '- %s\n' "$(printf 'x%.0s' $(seq 1 320))" >> "$fixture/codex-mem/MEMORY.md"
  local pad; pad="$(printf 'y%.0s' $(seq 1 200))"
  local i
  for i in $(seq 1 200); do printf -- '- %s\n' "$pad" >> "$fixture/codex-mem/MEMORY.md"; done
  local reg_bytes; reg_bytes="$(wc -c < "$fixture/codex-mem/MEMORY.md" | tr -d ' ')"
  local out score cx_bytes gap_titles
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" \
          --memory-dir "$fixture/mem" --codex-memory-dir "$fixture/codex-mem" --json 2>/dev/null)"
  score="$(_sa_pillar_score "$out" "memory-hygiene")"
  cx_bytes="$(printf '%s' "$out" | jq -r '.codex_registry_bytes')"
  # Expected-empty jq select: `|| true` keeps an empty result from tripping
  # pipefail-style failures in the harness.
  gap_titles="$(printf '%s' "$out" | jq -r '[.gaps[].title | select(contains("Codex registry"))] | join("|")' || true)"
  rm -rf "$fixture"
  assert_eq "codex registry: over-cap size + long lines deduct nothing (pillar 2 stays 20)" "20" "$score"
  assert_eq "codex registry: over-cap content records no codex cap gap" "" "$gap_titles"
  assert_not_contains "codex registry: no line-cap gap title remains" \
    "$out" "Codex registry MEMORY.md entries over line-length cap"
  assert_not_contains "codex registry: no size-cap gap title remains" \
    "$out" "Codex registry MEMORY.md over recall cap"
  assert_eq "codex registry: informational byte size reported for the over-cap registry" \
    "$reg_bytes" "$cx_bytes"
}
_test_codex_registry_over_cap_content_is_informational_only

# <TEAM>-468: a codex registry LARGER than every claude store must not win the
# injection-surface largest-store pick — the registry is excluded from that scan.
_test_codex_registry_excluded_from_injection_largest_store() {
  command -v jq >/dev/null 2>&1 || { _skip "codex-registry injection-surface test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"; _sa_mk_codex_case "$fixture"
  # Make the codex registry far larger than the claude store's MEMORY.md.
  local pad; pad="$(printf 'z%.0s' $(seq 1 200))"
  local i
  for i in $(seq 1 300); do printf -- '- %s\n' "$pad" >> "$fixture/codex-mem/MEMORY.md"; done
  local out largest_path fx
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" \
          --memory-dir "$fixture/mem" --codex-memory-dir "$fixture/codex-mem" --json 2>/dev/null)"
  largest_path="$(printf '%s' "$out" \
    | jq -r '.injection_surface.components[] | select(.name == "MEMORY.md (largest store)") | .path')"
  # Component paths carry the host-native forward-slash spelling on Windows;
  # compare in that spelling (tests/lib.sh native_path_fwd), resolved before
  # the fixture is removed.
  fx="$(native_path_fwd "$fixture")"
  rm -rf "$fixture"
  assert_eq "codex registry: oversized registry never wins the injection-surface largest-store pick" \
    "$fx/mem/MEMORY.md" "$largest_path"
}
_test_codex_registry_excluded_from_injection_largest_store

_test_codex_registry_missing_index() {
  command -v jq >/dev/null 2>&1 || { _skip "codex-registry missing-index test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"; _sa_mk_codex_case "$fixture"
  rm -f "$fixture/codex-mem/MEMORY.md"
  local out score
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" \
          --memory-dir "$fixture/mem" --codex-memory-dir "$fixture/codex-mem" --json 2>/dev/null)"
  score="$(_sa_pillar_score "$out" "memory-hygiene")"
  rm -rf "$fixture"
  assert_contains "codex registry: missing MEMORY.md records the blind-kickoff gap" \
    "$out" "Codex memory registry has no MEMORY.md index"
  assert_eq "codex registry: missing-index deduction lands on pillar 2" "14" "$score"
}
_test_codex_registry_missing_index

_test_codex_registry_bogus_path_skips() {
  command -v jq >/dev/null 2>&1 || { _skip "codex-registry bogus-path test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"; _sa_mk_codex_case "$fixture"
  local out score
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" \
          --memory-dir "$fixture/mem" --codex-memory-dir "$fixture/does-not-exist" --json 2>/dev/null)"
  score="$(_sa_pillar_score "$out" "memory-hygiene")"
  local cx_bytes; cx_bytes="$(printf '%s' "$out" | jq -r '.codex_registry_bytes')"
  rm -rf "$fixture"
  assert_eq "codex registry: non-existent path skips the surface (pillar 2 unaffected)" "20" "$score"
  assert_not_contains "codex registry: non-existent path records no codex gap" \
    "$out" "Codex memory registry"
  assert_eq "codex registry: non-existent path reports codex_registry_bytes as null" "null" "$cx_bytes"
}
_test_codex_registry_bogus_path_skips

# Panel finding (<TEAM>-468): a codex-ONLY install (zero claude stores → pillar
# 2 UNSCOREDs at its early return) must STILL report the registry size — the
# measurement runs before the early return, so null keeps exactly its two
# documented meanings (no registry resolved / registry holds no MEMORY.md).
_test_codex_only_install_still_reports_registry() {
  command -v jq >/dev/null 2>&1 || { _skip "codex-only registry-report test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"; _sa_mk_codex_case "$fixture"
  local reg_bytes; reg_bytes="$(wc -c < "$fixture/codex-mem/MEMORY.md" | tr -d ' ')"
  local out md_out unscored cx_bytes
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" \
          --memory-dir "$fixture/no-claude-store" --codex-memory-dir "$fixture/codex-mem" --json 2>/dev/null)"
  md_out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" \
          --memory-dir "$fixture/no-claude-store" --codex-memory-dir "$fixture/codex-mem" 2>/dev/null)"
  unscored="$(printf '%s' "$out" | jq -r '.pillars["memory-hygiene"].unscored')"
  cx_bytes="$(printf '%s' "$out" | jq -r '.codex_registry_bytes')"
  rm -rf "$fixture"
  assert_eq "codex-only: pillar 2 is UNSCORED with zero claude stores" "true" "$unscored"
  assert_eq "codex-only: registry byte size is still reported in JSON" "$reg_bytes" "$cx_bytes"
  assert_contains "codex-only: markdown still carries the informational size line" \
    "$md_out" "- codex memory registry (informational, not scored): $reg_bytes bytes"
}
_test_codex_only_install_still_reports_registry

# --- orientation surface (<TEAM>-524) ----------------------------------------
# The effective Mode 1 kickoff surface = static entrypoint + the compiled spine
# capability bodies (session-agent + closeout) the kickoff mandates + the vault
# lesson index read at every orient. Reported in its OWN section and its OWN
# JSON key; informational only — it must never move `total`, a pillar score, or
# `gaps`.

# _sa_mk_orient_home <dir> <entrypoint-name> — a rendered harness home fixture:
# an entrypoint file plus the two compiled spine skill bodies.
_sa_mk_orient_home() {
  local home="$1" entry="$2"
  mkdir -p "$home/skills/session-agent" "$home/skills/closeout"
  printf 'entrypoint body\nsecond line\n' > "$home/$entry"
  printf 'session-agent compiled body\n' > "$home/skills/session-agent/SKILL.md"
  printf 'closeout compiled body\nline two\nline three\n' > "$home/skills/closeout/SKILL.md"
}

_test_orientation_surface_measures_spine_and_lesson_index() {
  command -v jq >/dev/null 2>&1 || { _skip "orientation-surface measurement test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  local cfg="$fixture/config" vault="$fixture/vault"
  _sa_mk_orient_home "$cfg" "CLAUDE.md"
  mkdir -p "$vault/04-Lessons"
  printf '| Trigger | Lesson |\n| --- | --- |\n| before a fetch | use the CLI |\n' > "$vault/04-Lessons/_index.md"

  local ep_b sp_b li_b want_total
  ep_b="$(LC_ALL=C wc -c < "$cfg/CLAUDE.md" | tr -d ' ')"
  sp_b=$(( $(LC_ALL=C wc -c < "$cfg/skills/session-agent/SKILL.md" | tr -d ' ') \
         + $(LC_ALL=C wc -c < "$cfg/skills/closeout/SKILL.md" | tr -d ' ') ))
  li_b="$(LC_ALL=C wc -c < "$vault/04-Lessons/_index.md" | tr -d ' ')"
  want_total=$(( ep_b + sp_b + li_b ))

  local out md
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" \
          --config-dir "$cfg" --vault-dir "$vault" --json 2>/dev/null)"
  md="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" \
          --config-dir "$cfg" --vault-dir "$vault" 2>/dev/null)"
  rm -rf "$fixture"

  assert_eq "orientation surface: measured against a rendered harness home" \
    "true" "$(printf '%s' "$out" | jq -r '.orientation_surface.measured')"
  assert_eq "orientation surface: the claude render gets a per-harness row" \
    "claude" "$(printf '%s' "$out" | jq -r '.orientation_surface.harnesses[0].harness')"
  assert_eq "orientation surface: row names the compiled entrypoint" \
    "CLAUDE.md" "$(printf '%s' "$out" | jq -r '.orientation_surface.harnesses[0].entrypoint')"
  assert_eq "orientation surface: entrypoint_bytes matches the compiled entrypoint" \
    "$ep_b" "$(printf '%s' "$out" | jq -r '.orientation_surface.harnesses[0].entrypoint_bytes')"
  # The whole point of <TEAM>-524: the mandatory capability bodies are counted,
  # not just the static entrypoint file.
  assert_eq "orientation surface: spine_bytes covers session-agent + closeout, not the entrypoint alone" \
    "$sp_b" "$(printf '%s' "$out" | jq -r '.orientation_surface.harnesses[0].spine_bytes')"
  assert_eq "orientation surface: the vault lesson index is measured, not silently dropped" \
    "$li_b" "$(printf '%s' "$out" | jq -r '.orientation_surface.harnesses[0].lesson_index_bytes')"
  assert_eq "orientation surface: effective_total_bytes = entrypoint + spine + lesson index" \
    "$want_total" "$(printf '%s' "$out" | jq -r '.orientation_surface.harnesses[0].effective_total_bytes')"
  assert_eq "orientation surface: effective_total_bytes is numeric, not a string" \
    "number" "$(printf '%s' "$out" | jq -r '.orientation_surface.harnesses[0].effective_total_bytes | type')"
  assert_eq "orientation surface: lesson index status is measured" \
    "measured" "$(printf '%s' "$out" | jq -r '.orientation_surface.lesson_index.status')"
  assert_eq "orientation surface: aggregate total_bytes sums the harness rows" \
    "$want_total" "$(printf '%s' "$out" | jq -r '.orientation_surface.total_bytes')"
  # Unresolved harness homes are NAMED, never silently absent.
  assert_contains "orientation surface: an unresolved harness home is a named skip" \
    "$(printf '%s' "$out" | jq -r '.orientation_surface.skipped | join("|")')" "hermes (HERMES_HOME) not set"
  assert_contains "orientation surface: markdown has its own section" "$md" "## Orientation surface"
  assert_contains "orientation surface: markdown states the informational boundary" \
    "$md" "Informational only; never scored."
}
_test_orientation_surface_measures_spine_and_lesson_index

# The measurement must never move the score. Same fixture, same config dir, same
# vault — the ONLY difference is the size of the compiled spine bodies (no pillar
# reads $CONFIG_DIR/skills/), so a total or gap-count delta could only come from
# the new section.
_test_orientation_surface_never_scores() {
  command -v jq >/dev/null 2>&1 || { _skip "orientation-surface non-scoring test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  local cfg="$fixture/config" vault="$fixture/vault"
  _sa_mk_orient_home "$cfg" "CLAUDE.md"
  mkdir -p "$vault/04-Lessons"
  printf 'index\n' > "$vault/04-Lessons/_index.md"

  local fat thin fat_total thin_total fat_gaps thin_gaps fat_bytes thin_bytes gap_hits
  # Run A — a FAT spine.
  local pad; pad="$(printf 'y%.0s' $(seq 1 400))"
  local i
  for i in $(seq 1 50); do printf '%s\n' "$pad" >> "$cfg/skills/session-agent/SKILL.md"; done
  fat="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" \
          --config-dir "$cfg" --vault-dir "$vault" --json 2>/dev/null)"
  # Run B — the spine bodies removed entirely.
  rm -rf "$cfg/skills"
  thin="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" \
          --config-dir "$cfg" --vault-dir "$vault" --json 2>/dev/null)"
  rm -rf "$fixture"

  fat_total="$(printf '%s' "$fat" | jq -r '.total')"
  thin_total="$(printf '%s' "$thin" | jq -r '.total')"
  fat_gaps="$(printf '%s' "$fat" | jq -r '.gaps | length')"
  thin_gaps="$(printf '%s' "$thin" | jq -r '.gaps | length')"
  fat_bytes="$(printf '%s' "$fat" | jq -r '.orientation_surface.total_bytes')"
  thin_bytes="$(printf '%s' "$thin" | jq -r '.orientation_surface.total_bytes')"
  gap_hits="$(printf '%s' "$fat" | jq -r '[.gaps[] | select((.title + .detail + .fix) | ascii_downcase | contains("orientation"))] | length')"

  assert_eq "orientation surface: a fat vs absent spine does NOT change the total score" \
    "$thin_total" "$fat_total"
  assert_eq "orientation surface: a fat vs absent spine does NOT change the gap count" \
    "$thin_gaps" "$fat_gaps"
  assert_eq "orientation surface: never enters the gap list" "0" "$gap_hits"
  # Positive control: the two runs really did measure different surfaces, so the
  # equality above is a non-scoring proof and not a dead measurement.
  if [ -n "$fat_bytes" ] && [ -n "$thin_bytes" ] && [ "$fat_bytes" -gt "$thin_bytes" ]; then
    _pass "orientation surface: positive control — the fat run measured a larger surface than the thin run"
  else
    _fail "orientation surface: positive control — the fat run measured a larger surface than the thin run" \
          "expected fat > thin, got fat=[$fat_bytes] thin=[$thin_bytes]"
  fi
  # An absent compiled spine body is NAMED, so a broken render is visible.
  assert_contains "orientation surface: an absent spine body is named, not silently zero" \
    "$(printf '%s' "$thin" | jq -r '.orientation_surface.harnesses[0].missing | join("|")')" \
    "skills/session-agent/SKILL.md"
}
_test_orientation_surface_never_scores

_test_orientation_surface_lesson_index_unmeasured() {
  command -v jq >/dev/null 2>&1 || { _skip "orientation-surface lesson-index test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  local cfg="$fixture/config" vault="$fixture/vault"
  _sa_mk_orient_home "$cfg" "CLAUDE.md"
  mkdir -p "$vault/04-Lessons"   # vault exists, index does NOT

  local no_vault with_vault
  no_vault="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" \
          --config-dir "$cfg" --json 2>/dev/null)"
  with_vault="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" \
          --config-dir "$cfg" --vault-dir "$vault" --json 2>/dev/null)"
  rm -rf "$fixture"

  assert_eq "orientation surface: no vault → lesson_index_bytes is null (unmeasured, not 0)" \
    "null" "$(printf '%s' "$no_vault" | jq -r '.orientation_surface.harnesses[0].lesson_index_bytes')"
  assert_contains "orientation surface: no vault is a NAMED unmeasured state" \
    "$(printf '%s' "$no_vault" | jq -r '.orientation_surface.lesson_index.status')" \
    "unmeasured — no vault configured"
  assert_contains "orientation surface: a vault without the index names the missing path" \
    "$(printf '%s' "$with_vault" | jq -r '.orientation_surface.lesson_index.status')" \
    "unmeasured — not found at"
  assert_eq "orientation surface: a vault without the index still reports null bytes" \
    "null" "$(printf '%s' "$with_vault" | jq -r '.orientation_surface.lesson_index.bytes')"
}
_test_orientation_surface_lesson_index_unmeasured

_test_orientation_surface_no_home_resolves() {
  command -v jq >/dev/null 2>&1 || { _skip "orientation-surface no-home test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  local out md
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" --json 2>/dev/null)"
  md="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" 2>/dev/null)"
  rm -rf "$fixture"

  assert_eq "orientation surface: no resolvable home → measured false" \
    "false" "$(printf '%s' "$out" | jq -r '.orientation_surface.measured')"
  assert_eq "orientation surface: no resolvable home → total_bytes null (distinct from 0)" \
    "null" "$(printf '%s' "$out" | jq -r '.orientation_surface.total_bytes')"
  assert_eq "orientation surface: every unresolved home is named in skipped" \
    "5" "$(printf '%s' "$out" | jq -r '.orientation_surface.skipped | length')"
  assert_contains "orientation surface: markdown still carries the section when unmeasured" \
    "$md" "## Orientation surface"
  assert_contains "orientation surface: markdown names the unmeasured state" \
    "$md" "_(not measured — no rendered harness home resolved)_"
}
_test_orientation_surface_no_home_resolves

# Multi-harness: resolution mirrors check-drift.sh --auto's five harness:env-var
# pairs, so a codex/hermes/cursor/agents render each gets its own row with its own
# entrypoint (and the .agents co-render, which has no entrypoint of its own,
# reports null rather than pretending to one).
_test_orientation_surface_multi_harness() {
  command -v jq >/dev/null 2>&1 || { _skip "orientation-surface multi-harness test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  local cfg="$fixture/claude" cdx="$fixture/codex" hms="$fixture/hermes"
  local cur="$fixture/cursor" agt="$fixture/agents"
  _sa_mk_orient_home "$cfg" "CLAUDE.md"
  _sa_mk_orient_home "$cdx" "AGENTS.md"
  _sa_mk_orient_home "$hms" "SOUL.md"
  _sa_mk_orient_home "$cur" "AGENTS.md"
  _sa_mk_orient_home "$agt" "unused.md"

  # Non-isolated (so the env fallbacks run) with an empty fixture repo root, and
  # every operator env var pinned per-invocation — no ambient leak.
  local out
  out="$(env -u OBSIDIAN_VAULT_PATH -u CLAUDE_PRIMARY_MEMORY_DIR \
          CODEX_HOME="$cdx" HERMES_HOME="$hms" CURSOR_CONFIG_DIR="$cur" AGENTS_DIR="$agt" \
          bash "$REPO_ROOT/scripts/self-audit.sh" --repo-root "$fixture" \
          --config-dir "$cfg" --json 2>/dev/null)"
  rm -rf "$fixture"

  assert_eq "orientation surface: all five render homes get a row" \
    "claude|codex|hermes|cursor|agents" \
    "$(printf '%s' "$out" | jq -r '[.orientation_surface.harnesses[].harness] | join("|")')"
  assert_eq "orientation surface: the codex row names AGENTS.md" \
    "AGENTS.md" "$(printf '%s' "$out" | jq -r '.orientation_surface.harnesses[1].entrypoint')"
  assert_eq "orientation surface: the hermes row names SOUL.md" \
    "SOUL.md" "$(printf '%s' "$out" | jq -r '.orientation_surface.harnesses[2].entrypoint')"
  assert_eq "orientation surface: the cursor row names AGENTS.md" \
    "AGENTS.md" "$(printf '%s' "$out" | jq -r '.orientation_surface.harnesses[3].entrypoint')"
  assert_eq "orientation surface: the .agents co-render reports no entrypoint of its own" \
    "null" "$(printf '%s' "$out" | jq -r '.orientation_surface.harnesses[4].entrypoint')"
  assert_eq "orientation surface: the .agents co-render still measures its spine bodies" \
    "true" "$(printf '%s' "$out" | jq -r '.orientation_surface.harnesses[4].spine_bytes > 0')"
  assert_eq "orientation surface: nothing is skipped when all five resolve" \
    "0" "$(printf '%s' "$out" | jq -r '.orientation_surface.skipped | length')"
}
_test_orientation_surface_multi_harness

# An orientation component that EXISTS but cannot be READ (mode 000, an I/O
# error, a revoked ACL) is the one measurement path the `[ -f ]` guard does not
# cover: wc/awk fail, the helper printed NOTHING, and the empty string landed in
# `$(( sp_b + $(_ori_bytes …) ))`. An arithmetic-expansion syntax error is FATAL
# to a non-interactive bash — the whole audit died with no report at all, which
# is the loudest possible violation of "the orientation surface is informational
# and never affects the audit". An unreadable component must measure 0 and the
# audit must finish byte-identically otherwise.
#
# _skip where the failure cannot be provoked: as root (permissions bypassed) or
# on a filesystem that ignores mode 000 — the in-shell probe is the control.
_test_orientation_surface_unreadable_component() {
  command -v jq >/dev/null 2>&1 || { _skip "orientation-surface unreadable-component test" "jq not installed"; return 0; }
  if [ "$(id -u)" = "0" ]; then
    _skip "orientation-surface unreadable-component test" "running as root — mode 000 does not deny reads"
    return 0
  fi
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  local cfg="$fixture/config" vault="$fixture/vault"
  _sa_mk_orient_home "$cfg" "CLAUDE.md"
  mkdir -p "$vault/04-Lessons"
  printf 'index\n' > "$vault/04-Lessons/_index.md"

  # Control run FIRST, everything readable — the baseline the locked run must
  # match on every scored field.
  local ctrl ctrl_rc locked locked_rc
  ctrl="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" \
           --config-dir "$cfg" --vault-dir "$vault" --json 2>/dev/null)"; ctrl_rc=$?

  chmod 000 "$cfg/CLAUDE.md" "$cfg/skills/session-agent/SKILL.md"
  # Probe in THIS shell (same user as the self-audit child): does mode 000 really
  # block the read here? If not, the gap cannot be exercised → skip rather than
  # bank a green that proves nothing.
  # Subshell: the redirection itself is what fails, and a bare `wc … 2>&1` would
  # let the shell's own "Permission denied" reach the transcript.
  if ( LC_ALL=C wc -c < "$cfg/CLAUDE.md" ) >/dev/null 2>&1; then
    chmod 644 "$cfg/CLAUDE.md" "$cfg/skills/session-agent/SKILL.md"
    rm -rf "$fixture"
    _skip "orientation-surface unreadable-component test" \
      "mode 000 does not block reads on this filesystem"
    return 0
  fi

  locked="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" \
             --config-dir "$cfg" --vault-dir "$vault" --json 2>/dev/null)"; locked_rc=$?
  chmod 644 "$cfg/CLAUDE.md" "$cfg/skills/session-agent/SKILL.md"
  rm -rf "$fixture"

  # The audit RAN — an empty document here is the fatal-arithmetic regression.
  assert_eq "orientation surface: an unreadable component does not kill the audit (exit unchanged)" \
    "$ctrl_rc" "$locked_rc"
  assert_eq "orientation surface: an unreadable component still yields a parseable report" \
    "orientation_surface" "$(printf '%s' "$locked" | jq -r 'if has("orientation_surface") then "orientation_surface" else "MISSING" end' 2>/dev/null || printf 'UNPARSEABLE')"
  # Informational boundary: the score and gap list are untouched.
  assert_eq "orientation surface: an unreadable component does not move the total score" \
    "$(printf '%s' "$ctrl" | jq -r '.total')" "$(printf '%s' "$locked" | jq -r '.total')"
  assert_eq "orientation surface: an unreadable component does not move the gap count" \
    "$(printf '%s' "$ctrl" | jq -r '.gaps | length')" "$(printf '%s' "$locked" | jq -r '.gaps | length')"
  # Measurement semantics: unreadable measures 0. `missing` stays reserved for
  # components that are genuinely ABSENT — the file is there, it just cannot be
  # read, and conflating the two would misreport a broken render.
  assert_eq "orientation surface: an unreadable entrypoint measures 0, not empty" \
    "0" "$(printf '%s' "$locked" | jq -r '.orientation_surface.harnesses[0].entrypoint_bytes')"
  assert_eq "orientation surface: an unreadable entrypoint byte count is still numeric" \
    "number" "$(printf '%s' "$locked" | jq -r '.orientation_surface.harnesses[0].entrypoint_bytes | type')"
  assert_eq "orientation surface: an unreadable component is not reported as absent" \
    "0" "$(printf '%s' "$locked" | jq -r '.orientation_surface.harnesses[0].missing | length')"
  # The READABLE spine body is still counted — one unreadable file must not zero
  # the whole row.
  local ctrl_sp locked_sp
  ctrl_sp="$(printf '%s' "$ctrl" | jq -r '.orientation_surface.harnesses[0].spine_bytes')"
  locked_sp="$(printf '%s' "$locked" | jq -r '.orientation_surface.harnesses[0].spine_bytes')"
  if [ -n "$locked_sp" ] && [ "$locked_sp" != "null" ] && [ "$locked_sp" -gt 0 ] && [ "$locked_sp" -lt "$ctrl_sp" ]; then
    _pass "orientation surface: the readable spine body still counts when its sibling is unreadable"
  else
    _fail "orientation surface: the readable spine body still counts when its sibling is unreadable" \
      "expected 0 < locked < control, got locked=[$locked_sp] control=[$ctrl_sp]"
  fi
}
_test_orientation_surface_unreadable_component

# =============================================================================
# Operator sub-gates + project-note body budget
# =============================================================================

# --- operator sub-gates -------------------------------------------------------
# Operators accumulate their own semantic checkers that no audit aggregates, so
# the scorecard can read 100/100 while every one of them fails or silently
# lapses. The registry names them. What is under test is the WIRING contract —
# its own section, its own JSON key, and the load-bearing part: an operator gate
# NEVER moves total, a pillar score, or gaps. A gate that could depress the
# score would make operators stop registering gates.
#
# Hermetic: the fixture repo's OWN local.env carries AUDIT_SUBGATES_FILE, and
# every registered command is a stub written into the fixture — the operator's
# real registry is never read (a fixture repo-root has no operator local.env).
_test_operator_subgates() {
  command -v jq >/dev/null 2>&1 || { _skip "operator sub-gates wiring" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  local reg="$fixture/subgates.txt"
  printf 'AUDIT_SUBGATES_FILE=%s\n' "$reg" > "$fixture/local.env"

  # Happy path: a passing gate, a failing gate, a comment, a blank line, and a
  # line that names no command.
  {
    printf '# operator sub-gates\n'
    printf '\n'
    printf "map check = printf 'map is current\\\\n'\n"
    printf "drift check = printf 'two entries drifted\\\\n' >&2; exit 4\n"
    printf 'no command here\n'
  } > "$reg"

  local out base
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --repo-root "$fixture" --json 2>/dev/null)"
  assert_eq "operator sub-gates: a passing gate reports pass with exit 0" \
    "map check|pass|0" \
    "$(printf '%s' "$out" | jq -r '.operator_subgates.gates[0] | "\(.name)|\(.status)|\(.exit_code)"')"
  assert_eq "operator sub-gates: a passing gate carries its first output line as detail" \
    "map is current" "$(printf '%s' "$out" | jq -r '.operator_subgates.gates[0].detail')"
  assert_eq "operator sub-gates: a failing gate reports fail WITH its exit code" \
    "drift check|fail|4" \
    "$(printf '%s' "$out" | jq -r '.operator_subgates.gates[1] | "\(.name)|\(.status)|\(.exit_code)"')"
  assert_eq "operator sub-gates: a failing gate's stderr first line is the detail" \
    "two entries drifted" "$(printf '%s' "$out" | jq -r '.operator_subgates.gates[1].detail')"
  # A typo that makes a gate disappear is exactly the failure this closes, so a
  # malformed line is REPORTED, never silently dropped.
  assert_eq "operator sub-gates: a malformed registry line is named, not dropped" \
    "no command here|error" \
    "$(printf '%s' "$out" | jq -r '.operator_subgates.gates[2] | "\(.name)|\(.status)"')"
  assert_eq "operator sub-gates: comments and blank lines register no gate" \
    "3" "$(printf '%s' "$out" | jq -r '.operator_subgates.gates | length')"
  assert_eq "operator sub-gates: the JSON key carries a literal scored:false" \
    "false" "$(printf '%s' "$out" | jq -r '.operator_subgates.scored')"

  # THE load-bearing property: informational means informational. Compared
  # against the SAME fixture with the registry disabled, so score-neutrality is
  # proved rather than asserted against a hard-coded number.
  base="$(bash "$REPO_ROOT/scripts/self-audit.sh" --repo-root "$fixture" --no-subgates --json 2>/dev/null)"
  assert_eq "operator sub-gates: a FAILING gate does not change the total score" \
    "$(printf '%s' "$base" | jq -r '.total')" "$(printf '%s' "$out" | jq -r '.total')"
  assert_eq "operator sub-gates: a FAILING gate does not enter the gap list" \
    "$(printf '%s' "$base" | jq -r '.gaps | length')" "$(printf '%s' "$out" | jq -r '.gaps | length')"
  assert_eq "operator sub-gates: a FAILING gate does not move the memory pillar" \
    "$(_sa_pillar_score "$base" memory-hygiene)" "$(_sa_pillar_score "$out" memory-hygiene)"

  # Markdown surface.
  local md
  md="$(bash "$REPO_ROOT/scripts/self-audit.sh" --repo-root "$fixture" 2>/dev/null)"
  assert_contains "operator sub-gates: markdown has its own section" "$md" "## Operator sub-gates"
  assert_contains "operator sub-gates: markdown renders the passing gate" \
    "$md" "- map check: pass — map is current"
  assert_contains "operator sub-gates: markdown renders the failing gate with its exit code" \
    "$md" "- drift check: fail (exit 4) — two entries drifted"
  assert_contains "operator sub-gates: markdown states the informational boundary" \
    "$md" "never scored"

  # A hanging gate is bounded and reported as that gate's OWN error — the audit
  # still exits 0. The timeout is injected so this costs a second, not a minute.
  printf "hang = sleep 30\n" > "$reg"
  local slow_rc slow
  slow="$(SELF_AUDIT_SUBGATE_TIMEOUT=1 bash "$REPO_ROOT/scripts/self-audit.sh" \
          --repo-root "$fixture" --json 2>/dev/null)"; slow_rc=$?
  assert_eq "operator sub-gates: a hanging gate does not fail the audit" 0 "$slow_rc"
  assert_eq "operator sub-gates: a hanging gate is bounded and reported as error" \
    "hang|error|timed out after 1s" \
    "$(printf '%s' "$slow" | jq -r '.operator_subgates.gates[0] | "\(.name)|\(.status)|\(.detail)"')"

  # --no-subgates: execution off, section still rendered as a NAMED skip.
  printf "map check = printf 'ran\\\\n'\n" > "$reg"
  local nosub nosub_md
  nosub="$(bash "$REPO_ROOT/scripts/self-audit.sh" --repo-root "$fixture" --no-subgates --json 2>/dev/null)"
  nosub_md="$(bash "$REPO_ROOT/scripts/self-audit.sh" --repo-root "$fixture" --no-subgates 2>/dev/null)"
  assert_eq "operator sub-gates: --no-subgates nulls the JSON key" \
    "null" "$(printf '%s' "$nosub" | jq -r '.operator_subgates | type')"
  assert_contains "operator sub-gates: --no-subgates still renders a NAMED skip" \
    "$nosub_md" "_(skipped — --no-subgates given)_"

  # Registry configured but MISSING: a named skip, never a silent clean pass.
  printf 'AUDIT_SUBGATES_FILE=%s\n' "$fixture/absent-registry.txt" > "$fixture/local.env"
  local gone gone_md
  gone="$(bash "$REPO_ROOT/scripts/self-audit.sh" --repo-root "$fixture" --json 2>/dev/null)"
  gone_md="$(bash "$REPO_ROOT/scripts/self-audit.sh" --repo-root "$fixture" 2>/dev/null)"
  assert_eq "operator sub-gates: a missing registry nulls the JSON key" \
    "null" "$(printf '%s' "$gone" | jq -r '.operator_subgates | type')"
  assert_contains "operator sub-gates: a missing registry is a NAMED skip" \
    "$gone_md" "registry file not found:"

  # Drive-letter registry path — the contract is PLATFORM-CONDITIONAL, and
  # both arms are pinned. Under a Windows bash (MSYS/MinGW/Cygwin) `C:\...` is
  # a contract-valid absolute path, and the old bare-`/*` guard rejected it as
  # "not absolute" — silently turning the entire configured sub-gate surface
  # into a named skip on that platform; the guard must pass it through to the
  # existence check. On macOS/Linux the SAME spelling is a relative path, and
  # accepting it would re-open the cwd-dependent resolution the guard exists
  # to refuse — so there it must stay rejected.
  printf 'AUDIT_SUBGATES_FILE="C:\\fixture\\subgates.txt"\n' > "$fixture/local.env"
  local winreg_md
  winreg_md="$(bash "$REPO_ROOT/scripts/self-audit.sh" --repo-root "$fixture" 2>/dev/null)"
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
      assert_not_contains "operator sub-gates: a C:\\ registry path is not rejected as relative (Windows bash)" \
        "$winreg_md" "registry path is not absolute"
      assert_contains "operator sub-gates: a C:\\ registry path reaches the existence check (Windows bash)" \
        "$winreg_md" "registry file not found:"
      ;;
    *)
      assert_contains "operator sub-gates: a C:\\ registry path stays refused on POSIX (it is relative there)" \
        "$winreg_md" "registry path is not absolute"
      ;;
  esac
  # A genuinely relative path must still be refused — the Windows allowance
  # must not have widened the guard into accepting cwd-dependent spellings.
  printf 'AUDIT_SUBGATES_FILE=relative/subgates.txt\n' > "$fixture/local.env"
  local relreg_md
  relreg_md="$(bash "$REPO_ROOT/scripts/self-audit.sh" --repo-root "$fixture" 2>/dev/null)"
  assert_contains "operator sub-gates: a relative registry path is still refused" \
    "$relreg_md" "registry path is not absolute"

  # Key UNSET: same named-skip contract, different named reason.
  printf 'OBSIDIAN_VAULT_PATH=\n' > "$fixture/local.env"
  local unset_md unset_json
  unset_json="$(bash "$REPO_ROOT/scripts/self-audit.sh" --repo-root "$fixture" --json 2>/dev/null)"
  unset_md="$(bash "$REPO_ROOT/scripts/self-audit.sh" --repo-root "$fixture" 2>/dev/null)"
  assert_eq "operator sub-gates: an unset registry key nulls the JSON key" \
    "null" "$(printf '%s' "$unset_json" | jq -r '.operator_subgates | type')"
  assert_contains "operator sub-gates: an unset registry key is a NAMED skip" \
    "$unset_md" "no AUDIT_SUBGATES_FILE configured"
  # The section can never vanish: an invisible sub-gate surface is the exact
  # failure mode this whole lane exists to close.
  assert_contains "operator sub-gates: the section renders even when nothing ran" \
    "$unset_md" "## Operator sub-gates"

  # JSON key ORDER: the new key is appended LAST so every pre-existing field
  # keeps its position for a positional consumer.
  assert_eq "operator sub-gates: operator_subgates is the LAST JSON key" \
    "operator_subgates" "$(printf '%s' "$unset_json" | jq -r 'keys_unsorted | last')"
  assert_eq "operator sub-gates: no pre-existing JSON key moved" \
    "date,total,unscored_count,pillars,injection_surface,gaps,skipped,codex_registry_bytes,semantic_currentness,orientation_surface,recall_failures,operator_subgates" \
    "$(printf '%s' "$unset_json" | jq -r 'keys_unsorted | join(",")')"

  rm -rf "$fixture"
}
_test_operator_subgates

# --- Pillar 2 sub-check 2.6: project-note body budget -------------------------
# The recall caps bound the INDEX; nothing bounded the note BODIES the index
# points at — exactly what a kickoff orient dereferences. Advisory: one
# aggregate warn, never a hard cap.
_test_project_note_body_budget() {
  command -v jq >/dev/null 2>&1 || { _skip "project-note body budget" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  local mem="$fixture/memory"; mkdir -p "$mem"
  # ~20 KB body, over the 16 KB default; a small sibling and a NON-project note
  # of the same size stay under / out of scope.
  { printf -- '---\nmetadata:\n  type: project\n---\n'
    LC_ALL=C awk 'BEGIN { while (i++ < 400) printf "%s\n", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }'
  } > "$mem/project-big.md"
  printf -- '---\nmetadata:\n  type: project\n---\nsmall\n' > "$mem/project-small.md"
  { printf -- '---\nmetadata:\n  type: reference\n---\n'
    LC_ALL=C awk 'BEGIN { while (i++ < 400) printf "%s\n", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }'
  } > "$mem/reference-big.md"
  printf 'project-big.md project-small.md reference-big.md\n' > "$mem/MEMORY.md"

  local run
  run() { bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" --memory-dir "$mem" "$@" --json 2>/dev/null; }

  local over under
  over="$(run)"
  assert_eq "body budget: an over-budget project note raises exactly one gap" \
    "1" "$(printf '%s' "$over" | jq -r '[ .gaps[] | select(.title == "Project-type note body over budget") ] | length')"
  assert_eq "body budget: the gap carries leverage 4 on pillar 2" \
    "2|4" "$(printf '%s' "$over" | jq -r '.gaps[] | select(.title == "Project-type note body over budget") | "\(.pillar)|\(.leverage)"')"
  assert_contains "body budget: the gap names the offending note and the threshold" \
    "$(printf '%s' "$over" | jq -r '.gaps[] | select(.title == "Project-type note body over budget") | .detail')" \
    "project-big.md"
  assert_contains "body budget: the gap names the soft 16 KB default" \
    "$(printf '%s' "$over" | jq -r '.gaps[] | select(.title == "Project-type note body over budget") | .detail')" \
    "soft 16 KB per-note budget"
  # A non-project note of the same size is NOT in scope — orient dereferences
  # project-type bodies, and warning on the rest is alarm fatigue.
  assert_not_contains "body budget: a non-project note of the same size does not trip the warn" \
    "$(printf '%s' "$over" | jq -r '.gaps[] | select(.title == "Project-type note body over budget") | .detail')" \
    "reference-big.md"
  assert_eq "body budget: the warn costs exactly 2 pillar-2 points" \
    "18" "$(_sa_pillar_score "$over" memory-hygiene)"

  # A raised threshold clears it — the knob is real, and the check is advisory.
  under="$(run --project-note-warn-kb 512)"
  assert_eq "body budget: a raised threshold clears the warn" \
    "0" "$(printf '%s' "$under" | jq -r '[ .gaps[] | select(.title == "Project-type note body over budget") ] | length')"
  assert_eq "body budget: a raised threshold clears the deduction too" \
    "20" "$(_sa_pillar_score "$under" memory-hygiene)"

  # A garbage knob falls back to the DEFAULT silently — an advisory measurement
  # must degrade to the default, never break the audit (or silently disable
  # itself, which a 0-KB or negative reading would do).
  local garbage
  for garbage in abc 0 -5; do
    assert_eq "body budget: a garbage threshold ($garbage) falls back to the 16 KB default" \
      "1" "$(run --project-note-warn-kb "$garbage" | jq -r '[ .gaps[] | select(.title == "Project-type note body over budget") ] | length')"
  done

  # The warn is an AGGREGATE: two oversize notes still cost 2 points once.
  cp "$mem/project-big.md" "$mem/project-big2.md"
  printf 'project-big.md project-big2.md project-small.md reference-big.md\n' > "$mem/MEMORY.md"
  local two
  two="$(run)"
  assert_eq "body budget: two oversize notes still deduct exactly once" \
    "18" "$(_sa_pillar_score "$two" memory-hygiene)"
  assert_eq "body budget: both oversize notes are named in the single gap" \
    "2" "$(printf '%s' "$two" | jq -r '.gaps[] | select(.title == "Project-type note body over budget") | .detail | capture("(?<n>[0-9]+) project-type") | .n')"

  rm -rf "$fixture"
  unset -f run
}
_test_project_note_body_budget

# --- operator sub-gates: bounding an ADVERSARIAL gate --------------------------
# The first bound here was an in-process `perl -e 'alarm N; exec …'`. It is not a
# bound at all against two ordinary shell behaviours, and both were measured:
#   (a) a gate that runs `trap '' ALRM` inherits the ignore across the exec and
#       runs to completion, ceiling or not;
#   (b) a gate that backgrounds a child left the driver's command substitution
#       waiting on that child's stdout EOF — 19s under a 1s ceiling, reported
#       `pass`.
# The bound is now a driver-side watchdog over a dedicated PROCESS GROUP:
# enforcement lives outside the process being bounded, and TERM/KILL reach the
# whole tree. These fixtures are the regression anchors for that.
_test_operator_subgates_bounding() {
  command -v jq >/dev/null 2>&1 || { _skip "operator sub-gates bounding" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  local reg="$fixture/subgates.txt"
  printf 'AUDIT_SUBGATES_FILE=%s\n' "$reg" > "$fixture/local.env"

  local run_json t0 elapsed out rc
  run_json() { SELF_AUDIT_SUBGATE_TIMEOUT="$1" bash "$REPO_ROOT/scripts/self-audit.sh" \
                 --repo-root "$fixture" --json 2>/dev/null; }

  # (a) SIGALRM-ignoring gate. The ceiling must still hold.
  printf "trapper = trap '' ALRM; sleep 20\n" > "$reg"
  t0="$(date +%s)"
  out="$(run_json 2)"
  elapsed=$(( $(date +%s) - t0 ))
  assert_eq "sub-gate bounding: a SIGALRM-ignoring gate is still bounded and reported as a timeout" \
    "trapper|error|timed out after 2s" \
    "$(printf '%s' "$out" | jq -r '.operator_subgates.gates[0] | "\(.name)|\(.status)|\(.detail)"')"
  # Generous ceiling — this asserts the bound EXISTS, not a performance number.
  if [ "$elapsed" -lt 15 ]; then
    _pass "sub-gate bounding: the SIGALRM-ignoring gate returns near its ceiling, not near its sleep (${elapsed}s)"
  else
    _fail "sub-gate bounding: the SIGALRM-ignoring gate returns near its ceiling, not near its sleep" \
      "elapsed=${elapsed}s — the ceiling did not hold"
  fi

  # (b) The measured regression: a gate that backgrounds a child and then
  # EXITS. The old command-substitution capture waited on the orphan's stdout
  # EOF — 19s under a 1s ceiling — and reported `pass`. The gate's own output
  # must still be captured on this fast path.
  # The sentinel is unique per run: a machine-global `pgrep` pattern would let
  # any unrelated process on the box decide this assertion.
  local sentinel="sa-subgate-probe-$$-$(date +%s)"
  printf "bg = printf 'started\\\\n'; sh -c 'exec -a %s sleep 47' &\n" "$sentinel" > "$reg"
  t0="$(date +%s)"
  out="$(run_json 2)"
  elapsed=$(( $(date +%s) - t0 ))
  if [ "$elapsed" -lt 15 ]; then
    _pass "sub-gate bounding: a backgrounded child does not hold the driver past the ceiling (${elapsed}s)"
  else
    _fail "sub-gate bounding: a backgrounded child does not hold the driver past the ceiling" \
      "elapsed=${elapsed}s — the driver waited on the orphan's stdout EOF"
  fi
  assert_eq "sub-gate bounding: a fast-exiting gate's own output is still captured" \
    "started" "$(printf '%s' "$out" | jq -r '.operator_subgates.gates[0].detail')"
  pkill -f "$sentinel" >/dev/null 2>&1

  # (b2) Process-group kill: a TIMED-OUT gate's descendants die with it.
  # Without the group kill the bound leaks a process per timed-out gate, run
  # after run.
  sentinel="sa-subgate-orphan-$$-$(date +%s)"
  printf "bg2 = sh -c 'exec -a %s sleep 47' & sleep 20\n" "$sentinel" > "$reg"
  out="$(run_json 2)"
  assert_eq "sub-gate bounding: a gate held open by a foreground sleep times out" \
    "error" "$(printf '%s' "$out" | jq -r '.operator_subgates.gates[0].status')"
  if pgrep -f "$sentinel" >/dev/null 2>&1; then
    _fail "sub-gate bounding: a timed-out gate's descendants are killed with its process group" \
      "the $sentinel descendant outlived the gate"
    pkill -f "$sentinel" >/dev/null 2>&1
  else
    _pass "sub-gate bounding: a timed-out gate's descendants are killed with its process group"
  fi

  # (c) A flooding gate: bounded in TIME by the watchdog and in MEMORY by the
  # file capture + 512-byte read. The audit still exits 0.
  printf "flood = yes AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n" > "$reg"
  out="$(run_json 2)"; rc=$?
  assert_eq "sub-gate bounding: a flooding gate does not fail the audit" 0 "$rc"
  assert_eq "sub-gate bounding: a flooding gate is bounded and reported as a timeout" \
    "error|timed out after 2s" \
    "$(printf '%s' "$out" | jq -r '.operator_subgates.gates[0] | "\(.status)|\(.detail)"')"

  # (d) A gate that exits 142 FAST is an ordinary failure, not a timeout: the
  # wall clock is the timeout signal, never an exit code (the runner's own
  # SIGALRM/SIGTERM codes are in that same range).
  printf "e142 = exit 142\n" > "$reg"
  out="$(run_json 30)"
  assert_eq "sub-gate bounding: a genuine fast exit 142 is a fail with its code, not a timeout" \
    "e142|fail|142" \
    "$(printf '%s' "$out" | jq -r '.operator_subgates.gates[0] | "\(.name)|\(.status)|\(.exit_code)"')"

  # (e) Registry-wide cap: 64 entries run, the rest are NAMED, never silent.
  : > "$reg"
  local i=1
  while [ "$i" -le 70 ]; do printf 'gate-%s = true\n' "$i" >> "$reg"; i=$((i+1)); done
  out="$(run_json 30)"
  assert_eq "sub-gate bounding: the registry cap runs exactly 64 gates" \
    "64" "$(printf '%s' "$out" | jq -r '.operator_subgates.gates | length')"
  assert_eq "sub-gate bounding: entries past the cap are COUNTED, never silently dropped" \
    "6" "$(printf '%s' "$out" | jq -r '.operator_subgates.dropped')"
  local md
  md="$(SELF_AUDIT_SUBGATE_TIMEOUT=30 bash "$REPO_ROOT/scripts/self-audit.sh" --repo-root "$fixture" 2>/dev/null)"
  assert_contains "sub-gate bounding: the cap is a NAMED skip line in the markdown" \
    "$md" "registry capped at 64 gate(s); 6 further entr(y/ies) not run"

  rm -rf "$fixture"
  unset -f run_json
}
_test_operator_subgates_bounding

# --- knob arithmetic: an over-large budget must not WRAP -----------------------
# `$(( KB * 1024 ))` is 64-bit signed: 18014398509481984 KB wraps the product to
# 0, so every note on disk lands "over budget". The knob an operator typed to
# make the check QUIETER would instead fire it on a 62-byte note and take 2
# points off Pillar 2 — a silent inversion of the operator's intent.
_test_project_note_budget_knob_overflow() {
  command -v jq >/dev/null 2>&1 || { _skip "body budget knob overflow" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  local mem="$fixture/memory"; mkdir -p "$mem"
  printf -- '---\nmetadata:\n  type: project\n---\ntiny\n' > "$mem/project-tiny.md"
  printf 'project-tiny.md\n' > "$mem/MEMORY.md"

  local base over_flag over_env
  base="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" \
          --memory-dir "$mem" --json 2>/dev/null)"
  over_flag="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" \
               --memory-dir "$mem" --project-note-warn-kb 18014398509481984 --json 2>/dev/null)"
  # Same value through the local.env DATA path, which has no flag parsing in
  # front of it — the knob must be validated where it is USED, not at the flag.
  printf 'PROJECT_NOTE_BODY_WARN_KB=18014398509481984\n' > "$fixture/local.env"
  over_env="$(bash "$REPO_ROOT/scripts/self-audit.sh" --repo-root "$fixture" \
              --memory-dir "$mem" --json 2>/dev/null)"

  assert_eq "body budget: an overflowing knob (flag) raises NO gap on a tiny note" \
    "0" "$(printf '%s' "$over_flag" | jq -r '[ .gaps[] | select(.title == "Project-type note body over budget") ] | length')"
  assert_eq "body budget: an overflowing knob (flag) leaves the memory pillar untouched" \
    "$(_sa_pillar_score "$base" memory-hygiene)" "$(_sa_pillar_score "$over_flag" memory-hygiene)"
  assert_eq "body budget: an overflowing knob via local.env raises NO gap either" \
    "0" "$(printf '%s' "$over_env" | jq -r '[ .gaps[] | select(.title == "Project-type note body over budget") ] | length')"

  rm -rf "$fixture"
}
_test_project_note_budget_knob_overflow

# --- twin parity: mixed-case scan order ---------------------------------------
# The gap detail lists offenders in SCAN order. bash walks `find | LC_ALL=C sort`
# (ordinal, case-sensitive) and the PS twin used `Sort-Object Name` (culture,
# case-INsensitive), so a store holding both `project-A…` and `project-b…`
# ordered them differently and the two twins stopped emitting identical details.
# This fixture pins the bash side of that contract; its PS twin pins the other.
_test_body_budget_mixed_case_order() {
  command -v jq >/dev/null 2>&1 || { _skip "body budget mixed-case order" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  local mem="$fixture/memory"; mkdir -p "$mem"
  local big; big="$(LC_ALL=C awk 'BEGIN { while (i++ < 400) printf "%s\n", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }')"
  # Two names that a CASE-SENSITIVE byte sort and a culture sort order
  # differently ('B' = 0x42 sorts before 'a' = 0x61; a culture sort puts alpha
  # first). Deliberately NOT a case-only pair — a case-insensitive filesystem
  # would collapse those into one file and the fixture would prove nothing.
  local n
  for n in project-Beta.md project-alpha.md; do
    { printf -- '---\nmetadata:\n  type: project\n---\n'; printf '%s\n' "$big"; } > "$mem/$n"
  done
  printf 'project-Beta.md project-alpha.md\n' > "$mem/MEMORY.md"

  local out detail
  out="$(bash "$REPO_ROOT/scripts/self-audit.sh" --isolated --repo-root "$fixture" \
        --memory-dir "$mem" --json 2>/dev/null)"
  detail="$(printf '%s' "$out" | jq -r '.gaps[] | select(.title == "Project-type note body over budget") | .detail')"
  # Byte order: uppercase sorts before lowercase, so Beta precedes alpha.
  assert_eq "body budget: offenders are listed in ORDINAL byte order, not culture order" \
    "project-Beta.md project-alpha.md" \
    "$(printf '%s' "$detail" | LC_ALL=C tr ',' '\n' | LC_ALL=C sed 's|.*/||; s|=.*||' | LC_ALL=C tr '\n' ' ' | LC_ALL=C sed 's/ *$//')"

  rm -rf "$fixture"
}
_test_body_budget_mixed_case_order
