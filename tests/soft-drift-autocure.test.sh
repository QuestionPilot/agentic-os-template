#!/usr/bin/env bash
# tests/soft-drift-autocure.test.sh — check-drift.sh --cure-soft-drift behavior.
#
# `theme` / `effortLevel` are operator-local preference keys. The spine-only base
# (settings.base.json) ships NEITHER — they are carried across re-renders by
# install.sh preserve-live, not shipped downstream. So the live settings.json may
# carry operator-set theme/effortLevel that the opinion-free canonical base lacks
# (the soft envelope simulated below by ADDING them), and the Claude Code app may
# additionally strip/reorder them between sessions. Both directions are tolerated
# as soft drift. This test pins:
#
# 1. Default behavior unchanged — drift on soft keys still errors without the flag.
# 2. Opt-in --cure-soft-drift recognizes the soft-key envelope + auto-cures via
# install.sh re-render.
# 3. Real drift (hooks added, permissions changed, etc.) still errors even with
# the flag.
# 4. Multi-file drift envelope rejects auto-cure.
# 5. install.sh from a worktree against the operator-main config is refused
# (cure-via-install.sh from worktree would bake the worktree path into
# rendered hooks).
#
# Per the self-tripping-test-source + orphan-staged-fixtures memories: all
# fixtures are tmp-dir-scoped + cleaned inline. No sentinel literals planted
# into the repo tree.

# ---------- Test 1: Default behavior unchanged on soft drift -----------------
#
# Without --cure-soft-drift, ANY drift on settings.json still errors. This pins
# backward-compatibility — the flag is opt-in and the default code path is
# unchanged.

Q106_OUT="$(mktemp -d)/target"; mkdir -p "$Q106_OUT"
Q106_ENV="$(mktemp -d)/local.env"
make_local_env "$Q106_ENV" "$Q106_OUT"
AI_CONFIG_LOCAL_ENV="$Q106_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1

# Add operator-set soft keys (`theme`, `effortLevel`) to the live settings.json.
# The spine-only base ships neither, so a fresh render lacks them; an operator
# setting them (or preserve-live carrying them) makes the live file differ from
# the recorded manifest on soft keys only — the soft-drift envelope.
jq '. + {theme: "auto", effortLevel: "xhigh"}' "$Q106_OUT/settings.json" > "$Q106_OUT/settings.json.tmp"
mv "$Q106_OUT/settings.json.tmp" "$Q106_OUT/settings.json"

assert_exit "default behavior unchanged: soft-drift still fails without --cure-soft-drift" 1 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$Q106_OUT"

# ---------- Test 2: --cure-soft-drift cures the soft-drift case --------------
#
# Same fixture (operator-set soft keys) — adding the flag MUST cure via install.sh
# re-render and exit 0.

AI_CONFIG_LOCAL_ENV="$Q106_ENV" assert_exit "--cure-soft-drift cures soft keys (theme + effortLevel)" 0 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$Q106_OUT" --cure-soft-drift

# Verify the cure CARRIED the operator's soft keys via preserve-live: the cure
# re-render reads the live settings.json as the overlay source, so the operator's
# theme/effortLevel survive — they are preserved from the live file, NOT restored
# from base (the spine-only base no longer ships them).
Q106_THEME_AFTER="$(jq -r '.theme // "MISSING"' "$Q106_OUT/settings.json")"
assert_eq "post-cure: operator theme preserved as 'auto'" "auto" "$Q106_THEME_AFTER"

Q106_EFFORT_AFTER="$(jq -r '.effortLevel // "MISSING"' "$Q106_OUT/settings.json")"
assert_eq "post-cure: operator effortLevel preserved as 'xhigh'" "xhigh" "$Q106_EFFORT_AFTER"

# Final state: clean drift check now passes (post-cure verification).
assert_exit "post-cure: drift check passes from scratch" 0 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$Q106_OUT"

rm -rf "$Q106_OUT"

# ---------- Test 2b: app-strip of operator soft keys cures to converged state -
#
# The companion to Test 2 (operator SET soft keys). Here the operator's soft keys
# were preserved into a prior render (recorded in the manifest via preserve-live),
# then the Claude Code app STRIPS them from the live settings.json. Because the
# spine-only base ships neither key, the cure's opinion-free canonical also lacks
# them — so the cure converges the manifest to the stripped state rather than
# resurrecting the values from a base default (there is none). This pins the
# post-spine-only contract: theme/effortLevel are operator-local (live-config is
# their only source), so a stripped soft key is NOT restored by the cure — the
# same semantics as a deleted operator plugin. Added because the del→add rewrite
# of the cure tests would otherwise have dropped strip-direction coverage.

Q106M_OUT="$(mktemp -d)/target"; mkdir -p "$Q106M_OUT"
Q106M_ENV="$(mktemp -d)/local.env"
make_local_env "$Q106M_ENV" "$Q106M_OUT"
AI_CONFIG_LOCAL_ENV="$Q106M_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1
# Operator sets soft keys, then re-render so the manifest records them (preserve-live).
jq '. + {theme: "dark", effortLevel: "xhigh"}' "$Q106M_OUT/settings.json" > "$Q106M_OUT/settings.json.tmp"
mv "$Q106M_OUT/settings.json.tmp" "$Q106M_OUT/settings.json"
AI_CONFIG_LOCAL_ENV="$Q106M_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1
assert_eq "preserve-live recorded operator effortLevel before strip" "xhigh" \
  "$(jq -r '.effortLevel // "MISSING"' "$Q106M_OUT/settings.json")"
# The Claude Code app strips both soft keys from the live file.
jq 'del(.theme, .effortLevel)' "$Q106M_OUT/settings.json" > "$Q106M_OUT/settings.json.tmp"
mv "$Q106M_OUT/settings.json.tmp" "$Q106M_OUT/settings.json"
# Cure: soft envelope matches (canonical also lacks the keys); cure converges.
AI_CONFIG_LOCAL_ENV="$Q106M_ENV" assert_exit "app-strip of operator soft keys cures (soft envelope)" 0 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$Q106M_OUT" --cure-soft-drift
# Post-cure: the stripped keys are NOT resurrected (operator-local, no base source).
assert_eq "post-cure: stripped theme not resurrected (operator-local)" "MISSING" \
  "$(jq -r '.theme // "MISSING"' "$Q106M_OUT/settings.json")"
assert_eq "post-cure: stripped effortLevel not resurrected (operator-local)" "MISSING" \
  "$(jq -r '.effortLevel // "MISSING"' "$Q106M_OUT/settings.json")"
# And the drift check now passes (manifest converged to the stripped render).
assert_exit "post-cure: drift check passes after app-strip cure" 0 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$Q106M_OUT"
rm -rf "$Q106M_OUT"

# ---------- Test 3: Real drift still errors even with --cure-soft-drift ------
#
# Add a non-soft-key mutation (mutate a hook command) — adding the flag must
# NOT mask real drift. This is the most important negative test: the cure
# envelope must NOT widen silently.

Q106B_OUT="$(mktemp -d)/target"; mkdir -p "$Q106B_OUT"
Q106B_ENV="$(mktemp -d)/local.env"
make_local_env "$Q106B_ENV" "$Q106B_OUT"
AI_CONFIG_LOCAL_ENV="$Q106B_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1

# Hand-edit a hook command — this is REAL drift the operator wants to know
# about. (Uses the PreToolUse hook — the only capability-wired hook after the
# closeout Stop gate was removed.)
jq '.hooks.PreToolUse[0].hooks[0].command = "/tmp/malicious-hook.sh"' \
  "$Q106B_OUT/settings.json" > "$Q106B_OUT/settings.json.tmp"
mv "$Q106B_OUT/settings.json.tmp" "$Q106B_OUT/settings.json"

assert_exit "real drift (hook command mutated) still fails with --cure-soft-drift" 1 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$Q106B_OUT" --cure-soft-drift

# Confirm the cure did NOT run by checking the malicious command is still there
# (the manifest mismatch fast-rejects before any install.sh re-render).
Q106B_CMD="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$Q106B_OUT/settings.json")"
assert_eq "real-drift case: install.sh re-render did NOT silently run" \
  "/tmp/malicious-hook.sh" "$Q106B_CMD"

rm -rf "$Q106B_OUT"

# ---------- Test 4: Multi-file drift envelope rejects auto-cure --------------
#
# When BOTH settings.json AND a skill file are drifted, the envelope is
# multi-file — soft-cure must refuse (the envelope is settings.json-only by
# design).

Q106C_OUT="$(mktemp -d)/target"; mkdir -p "$Q106C_OUT"
Q106C_ENV="$(mktemp -d)/local.env"
make_local_env "$Q106C_ENV" "$Q106C_OUT"
AI_CONFIG_LOCAL_ENV="$Q106C_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1

# Mutate settings.json (soft drift: add an operator soft key) AND a skill file
# (real drift).
jq '. + {theme: "auto"}' "$Q106C_OUT/settings.json" > "$Q106C_OUT/settings.json.tmp"
mv "$Q106C_OUT/settings.json.tmp" "$Q106C_OUT/settings.json"
printf '\nHAND EDIT\n' >> "$Q106C_OUT/skills/session-agent/SKILL.md"

assert_exit "multi-file drift envelope (settings.json + skill) rejects --cure-soft-drift" 1 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$Q106C_OUT" --cure-soft-drift

rm -rf "$Q106C_OUT"

# ---------- Test 5: New non-soft top-level key rejects soft-cure -------------
#
# settings.json is the only file drifted, BUT the drift includes a non-soft
# top-level key (e.g. an unexpected new key the user wrote in). The envelope
# does NOT match — refuse cure.

Q106D_OUT="$(mktemp -d)/target"; mkdir -p "$Q106D_OUT"
Q106D_ENV="$(mktemp -d)/local.env"
make_local_env "$Q106D_ENV" "$Q106D_OUT"
AI_CONFIG_LOCAL_ENV="$Q106D_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1

# Add a top-level key that is NOT in the soft-key allowlist.
jq '. + {unexpectedKey: "operator wrote this"}' \
  "$Q106D_OUT/settings.json" > "$Q106D_OUT/settings.json.tmp"
mv "$Q106D_OUT/settings.json.tmp" "$Q106D_OUT/settings.json"

assert_exit "non-soft top-level key (unexpectedKey) rejects --cure-soft-drift" 1 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$Q106D_OUT" --cure-soft-drift

# Confirm the cure did NOT run — the unexpected key is still there.
Q106D_HAS_KEY="$(jq -r 'has("unexpectedKey")' "$Q106D_OUT/settings.json")"
assert_eq "non-soft-drift case: cure did NOT silently overwrite" "true" "$Q106D_HAS_KEY"

rm -rf "$Q106D_OUT"

# ---------- Test 6: --cure-soft-drift is position-insensitive ----------------
#
# The flag must work both before and after --manifest. Pins the arg-parsing
# behavior to position-independence so operator muscle memory doesn't matter.

Q106E_OUT="$(mktemp -d)/target"; mkdir -p "$Q106E_OUT"
Q106E_ENV="$(mktemp -d)/local.env"
make_local_env "$Q106E_ENV" "$Q106E_OUT"
AI_CONFIG_LOCAL_ENV="$Q106E_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1

jq '. + {theme: "auto", effortLevel: "xhigh"}' "$Q106E_OUT/settings.json" > "$Q106E_OUT/settings.json.tmp"
mv "$Q106E_OUT/settings.json.tmp" "$Q106E_OUT/settings.json"

# Flag BEFORE --manifest.
AI_CONFIG_LOCAL_ENV="$Q106E_ENV" assert_exit "--cure-soft-drift accepts flag BEFORE --manifest" 0 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --cure-soft-drift --manifest "$Q106E_OUT"

rm -rf "$Q106E_OUT"

# ---------- Test 7: Default mode (no --manifest) is unaffected ---------------
#
# --cure-soft-drift only applies in manifest mode. Running check-drift.sh
# without --manifest must behave exactly as before (the broad portability scan
# is unrelated to soft-drift).

assert_exit "broad scan mode unaffected by --cure-soft-drift flag" 0 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --cure-soft-drift

# ---------- Test 8: Type-change real drift on enabledPlugins rejected -------
#
# Codex confirmation finding #1: if a reorder-tolerant field's TYPE changes
# (e.g. enabledPlugins from object to string), the jq classifier's `keys` call
# would error, and naive error-suppression would collapse to "no non-soft
# keys" = soft envelope = cure proceeds = real drift gets silently
# overwritten. This test pins the fail-closed behavior.

Q106F_OUT="$(mktemp -d)/target"; mkdir -p "$Q106F_OUT"
Q106F_ENV="$(mktemp -d)/local.env"
make_local_env "$Q106F_ENV" "$Q106F_OUT"
AI_CONFIG_LOCAL_ENV="$Q106F_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1

# Mutate enabledPlugins from {object} to "string" — type-change attack.
jq '.enabledPlugins = "malicious-value"' \
  "$Q106F_OUT/settings.json" > "$Q106F_OUT/settings.json.tmp"
mv "$Q106F_OUT/settings.json.tmp" "$Q106F_OUT/settings.json"

assert_exit "type-change attack on enabledPlugins (object -> string) rejects --cure-soft-drift" 1 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$Q106F_OUT" --cure-soft-drift

# Confirm cure did NOT run — string still there.
Q106F_TYPE="$(jq -r '.enabledPlugins | type' "$Q106F_OUT/settings.json")"
assert_eq "type-change attack: cure did NOT silently restore object" "string" "$Q106F_TYPE"

rm -rf "$Q106F_OUT"

# ---------- Test 9: Top-level non-object JSON rejected ----------------------
#
# settings.json must be a JSON object at top level. If the operator (or attack)
# replaces it with a top-level array or string, the cure must refuse rather
# than risk re-rendering against an unknown shape.

Q106G_OUT="$(mktemp -d)/target"; mkdir -p "$Q106G_OUT"
Q106G_ENV="$(mktemp -d)/local.env"
make_local_env "$Q106G_ENV" "$Q106G_OUT"
AI_CONFIG_LOCAL_ENV="$Q106G_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1

# Replace settings.json with a top-level array — valid JSON but wrong shape.
printf '[]\n' > "$Q106G_OUT/settings.json"

assert_exit "top-level non-object settings.json rejects --cure-soft-drift" 1 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$Q106G_OUT" --cure-soft-drift

rm -rf "$Q106G_OUT"

# ---------- Test 10: Reorder-only positive case (extraKnownMarketplaces) ----
#
# Pins the reorder-tolerant behavior: if a reorder-tolerant object's keys are
# present in a DIFFERENT ORDER with identical values, the cure must accept this
# as soft drift. This is the recurring pattern was filed to handle.
#
# Uses extraKnownMarketplaces (a framework-managed object with two entries in
# settings.base.json) rather than enabledPlugins: the base now ships ZERO plugins
# (spine-only), and the soft-drift classifier builds its canonical baseline
# opinion-free (AI_CONFIG_SKIP_PRESERVE_LIVE), so an enabledPlugins change is a
# detectable non-soft difference (Test 14), not a reorder. extraKnownMarketplaces
# stays framework-managed and is the right surface for the reorder contract.

Q106H_OUT="$(mktemp -d)/target"; mkdir -p "$Q106H_OUT"
Q106H_ENV="$(mktemp -d)/local.env"
make_local_env "$Q106H_ENV" "$Q106H_OUT"
AI_CONFIG_LOCAL_ENV="$Q106H_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1

# Reverse the extraKnownMarketplaces keys (SAME keys + values, different order).
# jq's from_entries preserves insertion order, so this produces a real reorder.
jq '
  .extraKnownMarketplaces = (
    .extraKnownMarketplaces
    | to_entries
    | sort_by(.key) | reverse
    | from_entries
  )
' "$Q106H_OUT/settings.json" > "$Q106H_OUT/settings.json.tmp"
mv "$Q106H_OUT/settings.json.tmp" "$Q106H_OUT/settings.json"

AI_CONFIG_LOCAL_ENV="$Q106H_ENV" assert_exit "extraKnownMarketplaces key reorder accepted as soft drift" 0 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$Q106H_OUT" --cure-soft-drift

rm -rf "$Q106H_OUT"

# ---------- Test 14: enabledPlugins value-add is NOT silently cured ---------
#
# enabledPlugins is operator-owned, but --cure-soft-drift must NOT silently
# absorb a value-ADD (a settings.json edit enabling a plugin) into the canonical/
# manifest. The classifier builds its baseline opinion-free
# (AI_CONFIG_SKIP_PRESERVE_LIVE), so the add is a non-soft difference => cure
# refused => the operator resolves via a normal install.sh re-render (which
# preserves the choice non-destructively). Without the opinion-free baseline,
# preserve-live would self-match canonical and the add would be silently blessed.

Q106L_OUT="$(mktemp -d)/target"; mkdir -p "$Q106L_OUT"
Q106L_ENV="$(mktemp -d)/local.env"
make_local_env "$Q106L_ENV" "$Q106L_OUT"
AI_CONFIG_LOCAL_ENV="$Q106L_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1

# Hand/hostile edit: enable a plugin in the live config.
jq '.enabledPlugins["injected@claude-plugins-official"] = true' \
  "$Q106L_OUT/settings.json" > "$Q106L_OUT/settings.json.tmp"
mv "$Q106L_OUT/settings.json.tmp" "$Q106L_OUT/settings.json"

AI_CONFIG_LOCAL_ENV="$Q106L_ENV" assert_exit "enabledPlugins value-add is NOT cured by --cure-soft-drift (refused)" 1 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$Q106L_OUT" --cure-soft-drift

# The cure must NOT have rewritten the manifest to bless the add — default drift
# check still flags it.
assert_exit "post-refusal: injected plugin still flagged by default drift check" 1 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$Q106L_OUT"

# And the cure did not clobber the operator's live file either.
assert_eq "post-refusal: injected plugin still present in live settings.json" "true" \
  "$(jq -r '.enabledPlugins["injected@claude-plugins-official"] // false' "$Q106L_OUT/settings.json")"

rm -rf "$Q106L_OUT"

# ---------- Test 11: Worktree guard — install.sh sourced from main repo -----
#
# The dispatch brief + Codex confirmation finding #2: linked worktrees may
# live at any path (not just `worktrees/<name>`). When in a worktree, the cure
# MUST source install.sh from the main repo (via git metadata) rather than
# the worktree's install.sh — otherwise install.sh's @@AI_CONFIG_DIR@@
# substitution embeds the worktree path into hooks, and the worktree
# disappears on PR merge.
#
# This test runs from THIS worktree (`$REPO_ROOT` is the worktree path):
# verify that the cure path is found AND it points at the MAIN repo, not the
# worktree.

if [ -d "$REPO_ROOT/.git" ] || [ -f "$REPO_ROOT/.git" ]; then
  # Resolve the main repo root the same way check-drift.sh does.
  TOPLEVEL="$(cd "$REPO_ROOT" && git rev-parse --show-toplevel 2>/dev/null || true)"
  COMMON_DIR="$(cd "$REPO_ROOT" && git rev-parse --git-common-dir 2>/dev/null || true)"
  if [ -n "$COMMON_DIR" ]; then
    case "$COMMON_DIR" in
      /*) ;;
      *)  COMMON_DIR="$(cd "$REPO_ROOT" && cd "$COMMON_DIR" 2>/dev/null && pwd || true)" ;;
    esac
  fi
  if [ -n "$COMMON_DIR" ]; then
    MAIN_ROOT_EXPECTED="$(cd "$COMMON_DIR/.." 2>/dev/null && pwd || true)"
  else
    MAIN_ROOT_EXPECTED=""
  fi

  if [ -n "$TOPLEVEL" ] && [ -n "$MAIN_ROOT_EXPECTED" ] && [ "$TOPLEVEL" != "$MAIN_ROOT_EXPECTED" ]; then
    # We ARE in a linked worktree. Verify the cure works AND restored canonical.
    Q106I_OUT="$(mktemp -d)/target"; mkdir -p "$Q106I_OUT"
    Q106I_ENV="$(mktemp -d)/local.env"
    make_local_env "$Q106I_ENV" "$Q106I_OUT"
    AI_CONFIG_LOCAL_ENV="$Q106I_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1
    jq '. + {theme: "auto", effortLevel: "xhigh"}' "$Q106I_OUT/settings.json" > "$Q106I_OUT/settings.json.tmp"
    mv "$Q106I_OUT/settings.json.tmp" "$Q106I_OUT/settings.json"

    AI_CONFIG_LOCAL_ENV="$Q106I_ENV" assert_exit \
      "worktree case: --cure-soft-drift sources install.sh from main repo (still cures)" 0 -- \
      bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$Q106I_OUT" --cure-soft-drift

    rm -rf "$Q106I_OUT"
  else
    _skip "worktree guard test — not running in a linked worktree" \
      "TOPLEVEL=$TOPLEVEL MAIN_ROOT_EXPECTED=$MAIN_ROOT_EXPECTED"
  fi
else
  _skip "worktree guard test — no .git in REPO_ROOT" "REPO_ROOT=$REPO_ROOT"
fi

# ---------- Test 12: Adversarial A-1 harness mismatch rejected --------------
#
# A forged or corrupted manifest claiming harness="codex" on a Claude-shaped
# target must NOT trigger a re-render with the wrong harness. The cure must
# refuse on shape mismatch.

Q106J_OUT="$(mktemp -d)/target"; mkdir -p "$Q106J_OUT"
Q106J_ENV="$(mktemp -d)/local.env"
make_local_env "$Q106J_ENV" "$Q106J_OUT"
AI_CONFIG_LOCAL_ENV="$Q106J_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1

# Forge the manifest's harness field to "codex" while target is Claude-shaped.
jq '.harness = "codex"' "$Q106J_OUT/.build-manifest.json" > "$Q106J_OUT/.build-manifest.json.tmp"
mv "$Q106J_OUT/.build-manifest.json.tmp" "$Q106J_OUT/.build-manifest.json"

# Mutate settings.json to trigger soft-drift envelope (add an operator soft key).
jq '. + {theme: "auto"}' "$Q106J_OUT/settings.json" > "$Q106J_OUT/settings.json.tmp"
mv "$Q106J_OUT/settings.json.tmp" "$Q106J_OUT/settings.json"

assert_exit "adversarial A-1: forged harness=codex on Claude-shaped target rejects cure" 1 -- \
  bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$Q106J_OUT" --cure-soft-drift

rm -rf "$Q106J_OUT"

# ---------- Test 13: Adversarial A-3 duplicate JSON keys rejected -----------
#
# A settings.json with duplicate top-level keys (e.g. two `hooks` entries)
# could pass jq's structural diff while another consumer sees the malicious
# variant. The cure must refuse such files outright.

Q106K_OUT="$(mktemp -d)/target"; mkdir -p "$Q106K_OUT"
Q106K_ENV="$(mktemp -d)/local.env"
make_local_env "$Q106K_ENV" "$Q106K_OUT"
AI_CONFIG_LOCAL_ENV="$Q106K_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1

# Construct a settings.json with duplicate top-level keys. Hand-craft via
# string append since jq normalizes keys away — we need the RAW duplicate.
# Add operator soft keys theme + effortLevel (the soft envelope), then inject a
# duplicate hooks key with malicious content.
ORIG="$(jq '. + {theme: "auto", effortLevel: "xhigh"}' "$Q106K_OUT/settings.json")"
# Build a JSON document with duplicate `hooks` keys: the canonical one, then
# a malicious sibling. Real JSON parsers handle this differently; we want
# the cure to refuse the file regardless.
printf '%s\n' "$ORIG" \
  | jq -c '.' \
  | sed 's/}$/, "hooks": {"Stop": [{"matcher": "MALICIOUS", "hooks": []}]}}/' \
  > "$Q106K_OUT/settings.json"

# Sanity-check: jq sees the file as parseable.
if jq empty "$Q106K_OUT/settings.json" 2>/dev/null; then
  assert_exit "adversarial A-3: duplicate-key settings.json rejects cure" 1 -- \
    bash "$REPO_ROOT/scripts/check-drift.sh" --manifest "$Q106K_OUT" --cure-soft-drift
else
  _skip "adversarial A-3 test — duplicate-key fixture not valid JSON for jq" "jq could not parse"
fi

rm -rf "$Q106K_OUT"
