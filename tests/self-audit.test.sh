#!/usr/bin/env bash
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
  "$SA_CONTENT" "harnesses: [claude, codex, hermes]"
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

# --- D1: memory-dir selection is DETERMINISTIC — it picks the operator's PRIMARY
# surface (the projects/*/memory dir holding a MEMORY.md, ranked by project_*.md
# count), not the alphabetically-first stray dir. The old `ls | head -1` scored
# a near-empty stray dir on a multi-project setup.
_test_d1_deterministic_primary_memory_dir() {
  command -v jq >/dev/null 2>&1 || { _skip "D1 primary-memory-dir test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  # Two project dirs. Alphabetically-first ("aaa-stray") is a near-empty dir with
  # NO MEMORY.md; the real one ("zzz-primary") carries the index + a project file.
  # The OLD selector picked aaa-stray (→ MEMORY.md missing → pillar 2 = 0); the
  # new selector must pick zzz-primary (→ clean index → pillar 2 = 20).
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
---
real project body
EOF
  # Non-isolated so the CONFIG_DIR→MEMORY_DIR auto-resolution runs (the D1 code
  # path); --config-dir pins the config so the result does not depend on ambient
  # env / local.env. Vault unset → skipped. Assert on pillar 2 (memory-hygiene),
  # which is independent of lineark.
  local out p2
  out="$(env -u OBSIDIAN_VAULT_PATH -u CLAUDE_PRIMARY_MEMORY_DIR \
          bash "$REPO_ROOT/scripts/self-audit.sh" \
          --repo-root "$fixture" --config-dir "$cfg" --json 2>/dev/null)"
  p2="$(_sa_pillar_score "$out" "memory-hygiene")"
  rm -rf "$fixture"
  assert_eq "D1: selector picks the primary memory dir (with MEMORY.md), not the alphabetical-first stray" \
    "20" "$p2"
}
_test_d1_deterministic_primary_memory_dir

# --- D1b: an explicit $CLAUDE_PRIMARY_MEMORY_DIR overrides the heuristic.
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

# --- D1d (Codex review): tie-break determinism — two MEMORY.md dirs with equal
# project_*.md count resolve to the alphabetically-first candidate, every run.
_test_d1d_tiebreak_deterministic() {
  command -v jq >/dev/null 2>&1 || { _skip "D1d tie-break test" "jq not installed"; return 0; }
  local fixture; fixture="$(mktemp -d)" || return 1
  _sa_mk_fixture_repo "$fixture"
  local cfg="$fixture/config"
  mkdir -p "$cfg/projects/aaa-tie/memory" "$cfg/projects/bbb-tie/memory"
  # Both have MEMORY.md + exactly ONE project_*.md (equal count → a tie).
  # aaa-tie is clean; bbb-tie also carries an orphan memory file that would drop
  # pillar 2. The selector must pick aaa-tie (alphabetical-first) → pillar 2 = 20.
  cat > "$cfg/projects/aaa-tie/memory/MEMORY.md" <<'EOF'
# Memory Index

- [A](project_a.md) — clean
EOF
  cat > "$cfg/projects/aaa-tie/memory/project_a.md" <<'EOF'
---
name: project_a
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
---
b
EOF
  printf 'orphan\n' > "$cfg/projects/bbb-tie/memory/feedback_orphan.md"
  local out p2
  out="$(env -u OBSIDIAN_VAULT_PATH -u CLAUDE_PRIMARY_MEMORY_DIR \
          bash "$REPO_ROOT/scripts/self-audit.sh" \
          --repo-root "$fixture" --config-dir "$cfg" --json 2>/dev/null)"
  p2="$(_sa_pillar_score "$out" "memory-hygiene")"
  rm -rf "$fixture"
  assert_eq "D1d: equal-count MEMORY.md dirs tie-break to the alphabetical-first deterministically" "20" "$p2"
}
_test_d1d_tiebreak_deterministic

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
