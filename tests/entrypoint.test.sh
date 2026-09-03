#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/entrypoint.test.sh — CLAUDE.md + SKILLS.md generation and the
# vendored-snapshot manifest fix.

# --- shared fixture: a build with a complete local.env ---------------------
EP_DIR="$(mktemp -d)"
EP_OUT="$EP_DIR/out"; mkdir -p "$EP_OUT"
EP_VAULT="$EP_DIR/vault"
EP_ENV="$EP_DIR/local.env"
make_local_env "$EP_ENV" "$EP_OUT" "$EP_VAULT"

ep_build="$(AI_CONFIG_LOCAL_ENV="$EP_ENV" bash "$REPO_ROOT/scripts/install.sh" --build-only 2>/dev/null)"

# --- install.sh emits both harness entrypoint files ------------------------
assert_file "install.sh emits CLAUDE.md"  "$ep_build/CLAUDE.md"
assert_file "install.sh emits SKILLS.md"  "$ep_build/SKILLS.md"

if [ -f "$ep_build/CLAUDE.md" ]; then
  cmd="$(cat "$ep_build/CLAUDE.md")"
  # Behavioural equivalence: entrypoint layers + routing protocol survive.
  assert_contains "generated CLAUDE.md references README.md"        "$cmd" "README.md"
  assert_contains "generated CLAUDE.md references core/"            "$cmd" "core/"
  assert_contains "generated CLAUDE.md carries the session-agent spine rule" "$cmd" "session-agent\` is the spine"
  # The broad hand-curated quick-reference is preserved, not regressed. Anchor
  # on `security-review` (templates may not name retired `superpowers:*` skills
  # in routing tables §3; Live Inventory still describes them).
  # `cross-model-review` is intentionally absent from the framework templates
  # post-fix (moved to Shape C operator-local skill) — the regression guard
  # at the bottom of this file enforces that against the source templates.
  # Asserting against the *generated* CLAUDE.md is unsafe because
  # `@@AI_CONFIG_DIR@@` substitution can land a worktree path containing the
  # literal substring `cross-model-review`, producing a false positive.
  assert_contains "generated CLAUDE.md keeps the broad quick-reference" "$cmd" "security-review"
  # The pre-PR review row routes to the `code-review` built-in. `review` was
  # renamed upstream; a template still advertising `` `review` (built-in) ``
  # sends the operator to a skill the harness no longer ships.
  assert_contains "generated CLAUDE.md routes pre-PR review to code-review" "$cmd" "code-review"
  assert_not_contains "generated CLAUDE.md drops the retired \`review\` (built-in) row" \
    "$cmd" '`review` (built-in)'
  # Path placeholders are resolved against local.env.
  assert_not_contains "generated CLAUDE.md has no unresolved placeholders" "$cmd" "@@"
  assert_contains "generated CLAUDE.md substitutes the vault path"  "$cmd" "$EP_VAULT"
  assert_contains "generated CLAUDE.md substitutes the agentic-os-template path" "$cmd" "$REPO_ROOT"
  # The generated capability catalog has one row per capability spec — check
  # each real capability name appears as a catalog row.
  assert_contains "generated CLAUDE.md has the OS capability subsection" "$cmd" "OS capability skills"
  while IFS= read -r capf; do
    capn="$(basename "$capf" .md)"
    [ "$capn" = "README" ] && continue
    assert_contains "capability catalog has a row for $capn" "$cmd" "| \`$capn\` |"
  done < <(find "$REPO_ROOT/capabilities" -maxdepth 1 -name '*.md')
  # the deleted firecrawl, impeccable, printing-press, silver-platter
  # capabilities (vendored skills removed from the framework; preserved as
  # Shape C operator-local) must NOT appear in the Claude catalog. CLAUDE.md
  # would otherwise advertise capabilities the framework no longer ships.
  for deleted in firecrawl impeccable printing-press silver-platter; do
    assert_not_contains "claude CLAUDE.md catalog omits removed $deleted" "$cmd" "| \`$deleted\` |"
  done
fi

if [ -f "$ep_build/SKILLS.md" ]; then
  skm="$(cat "$ep_build/SKILLS.md")"
  assert_not_contains "generated SKILLS.md has no unresolved placeholders" "$skm" "@@"
  assert_contains "generated SKILLS.md keeps the live inventory"  "$skm" "Live Inventory"
  assert_contains "generated SKILLS.md substitutes the agentic-os-template path" "$skm" "$REPO_ROOT"
  # The Claude built-in was renamed `review` -> `code-review`; the table-cell form
  # is the needle so `security-review` / `cross-model-review` cannot satisfy it.
  assert_not_contains "generated SKILLS.md drops the retired \`review\` built-in" "$skm" '| `review` |'
  assert_contains "generated SKILLS.md routes pre-PR review to code-review" "$skm" '| `code-review` |'
fi

# --- the build manifest tracks the new generated + source files -----------
if [ -f "$ep_build/.build-manifest.json" ]; then
  mf="$ep_build/.build-manifest.json"
  assert_eq "manifest tracks CLAUDE.md as generated" "true" \
    "$(jq -r '.generated["CLAUDE.md"] != null' "$mf")"
  assert_eq "manifest tracks SKILLS.md as generated" "true" \
    "$(jq -r '.generated["SKILLS.md"] != null' "$mf")"
  assert_eq "manifest tracks CLAUDE.template.md as a source" "true" \
    "$(jq -r '.sources["harnesses/claude/CLAUDE.template.md"] != null' "$mf")"
  assert_eq "manifest tracks SKILLS.template.md as a source" "true" \
    "$(jq -r '.sources["harnesses/claude/SKILLS.template.md"] != null' "$mf")"
  # vendored-skill snapshots are first-class build inputs.
  # agentic-os-template no longer authors vendored skills (harnesses/claude/vendored/
  # was removed); the compile_vendored function survives for forward-compat per
  # closure. Make the contract conditional on vendored/ presence so
  # future Tier 3 re-introduction is still protected, while today's no-vendored
  # state correctly registers zero sources under that prefix.
  if [ -d "$REPO_ROOT/harnesses/claude/vendored" ]; then
    assert_eq "manifest tracks vendored snapshots as sources" "true" \
      "$(jq -r '[.sources | keys[] | select(startswith("harnesses/claude/vendored/"))] | length > 0' "$mf")"
  else
    assert_eq "manifest correctly has no vendored sources when vendored/ absent" "true" \
      "$(jq -r '[.sources | keys[] | select(startswith("harnesses/claude/vendored/"))] | length == 0' "$mf")"
  fi
fi

[ -n "$ep_build" ] && rm -rf "$ep_build"
rm -rf "$EP_DIR"

# --- install.ps1 PS-twin renders the OS capability catalog rows ----
# The bash twin's catalog generator emits `| `<name>` | <summary> | <kind> |`
# (asserted in the loop above). install.ps1's New-CapabilityCatalog port
# (introduced) historically emitted the literal placeholder
# `${base}` because the PS double-quoted-string `` `$ `` escape suppresses
# variable expansion. The fix at scripts/install.ps1:465 uses `` `` `` (the
# PS escape for a literal backtick) instead of a single backtick before `$`.
#
# This block re-runs the build via pwsh and re-asserts the per-capability
# rows render correctly. Skipped on hosts without pwsh. Per
# [[runtime_cross_model_review_artifacts]] / [[reference_ps_port_traps]],
# the PS port is a separately-authored file that does NOT inherit bash's
# template-substitution chain, so the PS render path needs its own regression
# guard or a future ${base}-class leak would ship silently on Windows.
if command -v pwsh >/dev/null 2>&1; then
  EPS_DIR="$(mktemp -d)"
  EPS_OUT="$EPS_DIR/out"; mkdir -p "$EPS_OUT"
  EPS_ENV="$EPS_DIR/local.env"
  make_local_env "$EPS_ENV" "$EPS_OUT" "$EPS_DIR/vault"
  eps_build="$(AI_CONFIG_LOCAL_ENV="$EPS_ENV" pwsh -NoProfile -File "$REPO_ROOT/scripts/install.ps1" --harness claude --build-only 2>/dev/null | tail -1)"
  if [ -n "$eps_build" ] && [ -f "$eps_build/CLAUDE.md" ]; then
    eps_cmd="$(cat "$eps_build/CLAUDE.md")"
    # The bug emitted `| ${base} |` literal rows. Pin against the literal.
    assert_not_contains "PS render: no literal \${base} placeholder in catalog" "$eps_cmd" '| ${base} |'
    # Per-capability row coverage — mirrors the bash assertion loop above.
    while IFS= read -r capf; do
      capn="$(basename "$capf" .md)"
      [ "$capn" = "README" ] && continue
      assert_contains "PS render: capability catalog has a row for $capn" "$eps_cmd" "| \`$capn\` |"
    done < <(find "$REPO_ROOT/capabilities" -maxdepth 1 -name '*.md')
  else
    _fail "PS render: install.ps1 --build-only produced no CLAUDE.md"
  fi
  [ -n "$eps_build" ] && rm -rf "$eps_build"
  rm -rf "$EPS_DIR"
else
  _skip "PS render: install.ps1 capability catalog rows" "pwsh not on PATH"
fi

# --- a full install swaps both entrypoint files into the target -----------
SWE_DIR="$(mktemp -d)"
SWE_OUT="$SWE_DIR/target"; mkdir -p "$SWE_OUT"
SWE_ENV="$SWE_DIR/local.env"
make_local_env "$SWE_ENV" "$SWE_OUT" "$SWE_DIR/vault"
AI_CONFIG_LOCAL_ENV="$SWE_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1
assert_file "full install swaps CLAUDE.md into the target" "$SWE_OUT/CLAUDE.md"
assert_file "full install swaps SKILLS.md into the target" "$SWE_OUT/SKILLS.md"
# check-drift.sh --manifest covers the two new generated files.
assert_exit "drift check passes on a clean build with entrypoints" 0 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$SWE_OUT"
printf '\nHAND EDIT\n' >> "$SWE_OUT/CLAUDE.md"
assert_exit "drift check fails after CLAUDE.md is hand-edited" 1 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$SWE_OUT"
rm -rf "$SWE_DIR"

# --- the optional vault: omitting OBSIDIAN_VAULT_PATH BUILDS (exit 0) and renders
# the unset sentinel, never a hard die. The vault is the framework's only OPTIONAL
# path placeholder; the "a required placeholder resolving empty must die loudly"
# guard stays in code at install.sh:442 and is exercised at PR time by
# install-render-stable.test's Assertion 0 (every active-template @@VAR@@ must carry
# a fixture value, so a new required placeholder cannot land valueless).
NV_DIR="$(mktemp -d)"
NV_OUT="$NV_DIR/out"; mkdir -p "$NV_OUT"
NV_ENV="$NV_DIR/local.env"
# CLAUDE_CONFIG_DIR only — OBSIDIAN_VAULT_PATH deliberately omitted (it is optional).
printf 'CLAUDE_CONFIG_DIR=%s\n' "$NV_OUT" > "$NV_ENV"
nv_status=0
nv_out="$(AI_CONFIG_LOCAL_ENV="$NV_ENV" bash "$REPO_ROOT/scripts/install.sh" --build-only 2>&1)" || nv_status=$?
assert_eq "build succeeds when the optional vault is omitted (renders sentinel)" "0" "$nv_status"
nv_build="$(printf '%s\n' "$nv_out" | grep -oE '/[^[:space:]]*\.install-build\.[A-Za-z0-9]+' | head -1)"
if [ -n "$nv_build" ] && [ -f "$nv_build/CLAUDE.md" ]; then
  if grep -q '@@OBSIDIAN_VAULT_PATH@@' "$nv_build/CLAUDE.md"; then
    _fail "omitted-vault entrypoint has no unresolved vault token" "found @@OBSIDIAN_VAULT_PATH@@ in the rendered entrypoint"
  else
    _pass "omitted-vault entrypoint has no unresolved vault token"
  fi
  assert_contains "omitted-vault entrypoint renders the unset sentinel" \
    "$(cat "$nv_build/CLAUDE.md")" "the durable-knowledge vault is optional"
  rm -rf "$nv_build"
else
  _fail "omitted-vault build produced an inspectable CLAUDE.md" "build path: [$nv_build]"
fi
rm -rf "$NV_DIR"

# Structural guard for the die-on-empty protection the case above no longer
# exercises behaviorally (the vault was the only emptyable required placeholder, so
# a behavioral trigger no longer exists). Assert the die guard is intact AND the
# sentinel exemption is NARROW — only OBSIDIAN_VAULT_PATH may dodge the die. Catches
# the two regressions a cross-model review flagged: the die being removed, or the
# exemption widening to a genuinely-required placeholder. Mirrors install.ps1 in the
# .ps1 twin.
ep_install_sh="$(cat "$REPO_ROOT/scripts/install.sh")"
assert_contains "install.sh keeps the die-on-empty guard for required placeholders" \
  "$ep_install_sh" 'placeholder $token resolves empty'
assert_contains "install.sh sentinel exemption is narrowly scoped to the vault only" \
  "$ep_install_sh" '[ "$var" = "OBSIDIAN_VAULT_PATH" ]'

# --- placeholder substitution survives '&' and spaces in a path -----------
SP_DIR="$(mktemp -d)"
SP_OUT="$SP_DIR/out"; mkdir -p "$SP_OUT"
SP_ENV="$SP_DIR/local.env"
SP_VAULT='/tmp/v&ault dir'
make_local_env "$SP_ENV" "$SP_OUT" "$SP_VAULT"
sp_build="$(AI_CONFIG_LOCAL_ENV="$SP_ENV" bash "$REPO_ROOT/scripts/install.sh" --build-only 2>/dev/null)"
if [ -n "$sp_build" ] && [ -f "$sp_build/CLAUDE.md" ]; then
  sp_cmd="$(cat "$sp_build/CLAUDE.md")"
  assert_contains "substitution: an '&'/space path resolves verbatim" "$sp_cmd" "$SP_VAULT"
  assert_not_contains "substitution: no placeholder survives an '&' path" "$sp_cmd" "@@"
else
  _fail "substitution: build with an '&' path produced no CLAUDE.md"
fi
[ -n "$sp_build" ] && rm -rf "$sp_build"
rm -rf "$SP_DIR"

# --- a '|' in a capability summary is escaped in the generated catalog ----
PREPO="$(mktemp -d)"
copy_repo_tracked "$PREPO"
awk '/^summary:/ && !done {print "summary: Alpha | Beta pipe test"; done=1; next} {print}' \
  "$REPO_ROOT/capabilities/session-agent.md" > "$PREPO/capabilities/session-agent.md"
POUT="$(mktemp -d)/out"; mkdir -p "$POUT"
PENV="$(mktemp -d)/local.env"
make_local_env "$PENV" "$POUT"
pbuild="$(AI_CONFIG_LOCAL_ENV="$PENV" bash "$PREPO/scripts/install.sh" --build-only 2>/dev/null)"
if [ -n "$pbuild" ] && [ -f "$pbuild/CLAUDE.md" ]; then
  assert_contains "catalog escapes a '|' inside a capability summary" \
    "$(cat "$pbuild/CLAUDE.md")" 'Alpha \| Beta'
else
  _fail "pipe-summary: build produced no CLAUDE.md"
fi
[ -n "$pbuild" ] && rm -rf "$pbuild"
rm -rf "$PREPO"

# --- drift check also covers a hand-edited SKILLS.md ----------------------
SK_DIR="$(mktemp -d)"
SK_OUT="$SK_DIR/target"; mkdir -p "$SK_OUT"
SK_ENV="$SK_DIR/local.env"
make_local_env "$SK_ENV" "$SK_OUT" "$SK_DIR/vault"
AI_CONFIG_LOCAL_ENV="$SK_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1
printf '\nHAND EDIT\n' >> "$SK_OUT/SKILLS.md"
assert_exit "drift check fails after SKILLS.md is hand-edited" 1 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$SK_OUT"
rm -rf "$SK_DIR"

# --- lock the retired-skill-name gate ---------------
# Cross-model review (F-3) noted the §3 acceptance grep was a manual check
# only. Encode it as a regression test so future template edits cannot
# silently re-introduce `three-brain` or routing-table `superpowers:*`.
# `superpowers:*` IS permitted in narrative — specifically the Live Inventory
# section header `### Superpowers (`superpowers:*`)` — so the filter strips
# that exact line shape and asserts the remainder is empty.
TB_HITS="$(grep -rnE 'three-brain' "$REPO_ROOT/harnesses/claude/" 2>/dev/null || true)"
assert_eq "no three-brain references in Claude templates" "" "$TB_HITS"

# (post-fix): cross-model-review fully removed from framework
# templates. The Shape C description moved to catalog.md under Specialty
# repos. Negative-grep no longer carves out exceptions — ANY hit fails.
# Closes the negative-grep blind spot (Codex F1 BLOCKING review).
CMR_HITS="$(grep -rnE 'cross-model-review' "$REPO_ROOT/harnesses/claude/" 2>/dev/null || true)"
assert_eq "no cross-model-review references in Claude templates" "" "$CMR_HITS"

# ### Superpowers subsection deleted in Task 9, AND every routing-row
# `superpowers:*` literal was rewritten to surface-agnostic prose pointing at
# catalog.md. No carve-out required (Codex F3 review: per-occurrence strip
# pattern is fragile — best to have ZERO superpowers: hits in the template).
SUP_HITS="$(grep -rnE 'superpowers:' "$REPO_ROOT/harnesses/claude/" 2>/dev/null || true)"
assert_eq "no superpowers: hits in Claude templates" "" "$SUP_HITS"
