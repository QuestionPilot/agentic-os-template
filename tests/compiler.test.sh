#!/usr/bin/env bash
# tests/compiler.test.sh — compiler-invariant tests.

# Smoke: the harness itself works.
assert_eq "lib: assert_eq matches equal strings" "x" "x"

# --- validate.sh: local.env must be gitignored ---
vtmp="$(mktemp -d)"
cp -R "$REPO_ROOT/." "$vtmp/"
rm -rf "$vtmp/.git"
# A local.env present but NOT gitignored must fail validate.sh.
printf 'CLAUDE_CONFIG_DIR=/tmp/x\n' > "$vtmp/local.env"
# Neutralise the.gitignore entry so the check has something to catch.
sed -i.bak '/^local\.env$/d' "$vtmp/.gitignore" 2>/dev/null || true
nogit_status=0
( cd "$vtmp" && bash scripts/validate.sh ) >/dev/null 2>&1 || nogit_status=$?
assert_eq "validate.sh fails when local.env is not gitignored" "1" "$nogit_status"
rm -rf "$vtmp"

# --- install.sh: arg parsing + local.env load (Task 3 scope) ---
# Shared fixture local.env reused by later install.sh test blocks.
FIX_DIR="$(mktemp -d)"
FIX_OUT="$FIX_DIR/out"; mkdir -p "$FIX_OUT"
FIX_ENV="$FIX_DIR/local.env"
make_local_env "$FIX_ENV" "$FIX_OUT"

# A missing local.env must exit 1.
missing_status=0
AI_CONFIG_LOCAL_ENV="$FIX_DIR/nope.env" bash "$REPO_ROOT/scripts/install.sh" --build-only >/dev/null 2>&1 || missing_status=$?
assert_eq "install.sh exits 1 on missing local.env" "1" "$missing_status"

# An unknown argument must exit 2.
badarg_status=0
AI_CONFIG_LOCAL_ENV="$FIX_ENV" bash "$REPO_ROOT/scripts/install.sh" --bogus >/dev/null 2>&1 || badarg_status=$?
assert_eq "install.sh exits 2 on unknown argument" "2" "$badarg_status"

# An unknown --harness must be rejected with a clear message.
unkh_status=0
unkh_out="$(AI_CONFIG_LOCAL_ENV="$FIX_ENV" bash "$REPO_ROOT/scripts/install.sh" --harness bogus --build-only 2>&1 >/dev/null)" || unkh_status=$?
assert_eq "install.sh exits 1 on an unknown harness" "1" "$unkh_status"
assert_contains "install.sh names the unknown harness" "$unkh_out" "unknown harness"

# --- --out resolves the target without the per-harness env var ---
# install.sh resolves the build target from --out; the per-harness target env
# var (CODEX_HOME / CLAUDE_CONFIG_DIR) must not be a hard requirement when
# --out is given. local.env still supplies OBSIDIAN_VAULT_PATH for the
# entrypoint. The env-var requirement check must run *after* --out is applied.
OO_DIR="$(mktemp -d)"
OO_ENV="$OO_DIR/local.env"
printf 'OBSIDIAN_VAULT_PATH=%q\n' "/tmp/test-vault" > "$OO_ENV"
oo_status=0
oo_build="$(AI_CONFIG_LOCAL_ENV="$OO_ENV" bash "$REPO_ROOT/scripts/install.sh" \
  --harness codex --out "$OO_DIR/tgt" --build-only 2>/dev/null)" || oo_status=$?
assert_eq "install.sh --out works with no CODEX_HOME set" "0" "$oo_status"
assert_file "install.sh --out without env var still builds AGENTS.md" "$oo_build/AGENTS.md"
rm -rf "$OO_DIR"

# --- install.sh neutralizes a hostile CDPATH ---
# `cd "$TARGET"` while CDPATH is set can resolve a bare relative target via a
# CDPATH entry — landing in the wrong directory and echoing the path (which
# corrupts the canonicalized TARGET). install.sh must neutralize CDPATH for
# that cd. The decoy below is a same-named dir reachable through CDPATH.
CDP_DIR="$(mktemp -d)"
mkdir -p "$CDP_DIR/decoy/cdtgt"
CDP_ENV="$CDP_DIR/local.env"
make_local_env "$CDP_ENV" "$CDP_DIR/unused"
cdp_status=0
( cd "$CDP_DIR" && CDPATH="$CDP_DIR/decoy" AI_CONFIG_LOCAL_ENV="$CDP_ENV" \
    bash "$REPO_ROOT/scripts/install.sh" --out cdtgt >/dev/null 2>&1 ) || cdp_status=$?
assert_eq "install.sh with a hostile CDPATH exits 0" "0" "$cdp_status"
assert_file "install.sh built into the PWD-relative target, not the CDPATH decoy" \
  "$CDP_DIR/cdtgt/settings.json"
[ -e "$CDP_DIR/decoy/cdtgt/settings.json" ] \
  && _fail "install.sh did not build into the CDPATH decoy" "decoy/cdtgt/settings.json exists" \
  || _pass "install.sh did not build into the CDPATH decoy"
rm -rf "$CDP_DIR"

# --- install.sh: native capability compiles to SKILL.md ---
nat_build="$(AI_CONFIG_LOCAL_ENV="$FIX_ENV" bash "$REPO_ROOT/scripts/install.sh" --build-only 2>/dev/null)"
sa_skill="$nat_build/skills/session-agent/SKILL.md"
assert_file "native compile: session-agent SKILL.md exists" "$sa_skill"
if [ -f "$sa_skill" ]; then
  sa_content="$(cat "$sa_skill")"
  assert_contains "session-agent SKILL.md frontmatter has name"    "$sa_content" "name: session-agent"
  assert_contains "session-agent SKILL.md has allowed-tools"        "$sa_content" "allowed-tools: Read, Bash"
  assert_contains "session-agent SKILL.md description mentions triggers" "$sa_content" "description:"
  assert_contains "session-agent SKILL.md body has neutral protocol" "$sa_content" "Session Agent — Session Kickoff Orient + Routing"
  assert_contains "session-agent SKILL.md body has Claude realization" "$sa_content" "Claude realization"
  assert_not_contains "session-agent SKILL.md body dropped realization frontmatter" "$sa_content" "allowed-tools: Read, Bash
---
## Claude"
fi
rm -rf "$nat_build"

# --- install.sh: vendored capability with a snapshot is copied as-is ---
# Synthesize a fixture vendored capability inside a throwaway repo copy so the
# test exercises compile_vendored independently of which (if any) vendored
# capabilities the real agentic-os-template currently authors. Names are chosen to not
# collide with any real or historical capability.
VREPO="$(mktemp -d)"
cp -R "$REPO_ROOT/." "$VREPO/"
rm -rf "$VREPO/.git"
mkdir -p "$VREPO/capabilities"
printf -- '---\nname: test-vendored\nsummary: synthetic vendored cap for compile_vendored test\ntriggers: []\nverification: none\nharnesses: [claude]\nkind: vendored\n---\n# test-vendored\n' \
  > "$VREPO/capabilities/test-vendored.md"
mkdir -p "$VREPO/harnesses/claude/vendored/test-vendored"
printf -- '---\nname: test-vendored\n---\nFIXTURE SNAPSHOT BODY\n' \
  > "$VREPO/harnesses/claude/vendored/test-vendored/SKILL.md"
VOUT="$(mktemp -d)/out"; mkdir -p "$VOUT"
VENV="$(mktemp -d)/local.env"
make_local_env "$VENV" "$VOUT"

vbuild="$(AI_CONFIG_LOCAL_ENV="$VENV" bash "$VREPO/scripts/install.sh" --build-only 2>/dev/null)"
assert_file "vendored compile: snapshot copied to skills/" "$vbuild/skills/test-vendored/SKILL.md"
if [ -f "$vbuild/skills/test-vendored/SKILL.md" ]; then
  assert_contains "vendored snapshot copied verbatim" "$(cat "$vbuild/skills/test-vendored/SKILL.md")" "FIXTURE SNAPSHOT BODY"
fi
rm -rf "$vbuild" "$VREPO"

# --- install.sh: vendored capability with no snapshot warns, does not fail ---
# Synthesize a vendored capability spec WITHOUT a snapshot dir. install.sh
# should emit a "no committed snapshot" warning and still exit 0 — a missing
# snapshot is non-fatal so the rest of the build still ships.
MREPO="$(mktemp -d)"
cp -R "$REPO_ROOT/." "$MREPO/"
rm -rf "$MREPO/.git"
mkdir -p "$MREPO/capabilities"
printf -- '---\nname: test-vendored-missing\nsummary: synthetic vendored cap with no committed snapshot\ntriggers: []\nverification: none\nharnesses: [claude]\nkind: vendored\n---\n# test-vendored-missing\n' \
  > "$MREPO/capabilities/test-vendored-missing.md"
# Deliberately no mkdir under harnesses/claude/vendored/test-vendored-missing.
MOUT_DIR="$(mktemp -d)"; MOUT="$MOUT_DIR/out"; mkdir -p "$MOUT"
MENV_DIR="$(mktemp -d)"; MENV="$MENV_DIR/local.env"
make_local_env "$MENV" "$MOUT"
# Capture stdout (build path) + stderr (warning) separately so we can assert
# on both — the build path is needed for the MT-2 "no orphan subdir"
# check below.
MERR="$(mktemp)"
mbuild="$(AI_CONFIG_LOCAL_ENV="$MENV" bash "$MREPO/scripts/install.sh" --build-only 2>"$MERR")"
warn_status=$?
warn_out="$(cat "$MERR")"
rm -f "$MERR"
assert_contains "missing vendored snapshot emits a warning" "$warn_out" "no committed snapshot"
# A skipped snapshot must still exit 0 — not merely "not 1" (which would let
# exit 2/126/127 from a genuinely broken build pass as success).
[ "$warn_status" -eq 0 ] && _pass "missing vendored snapshot does not fail the build" \
  || _fail "missing vendored snapshot does not fail the build" "exit was $warn_status"
# MT-2: a missing-snapshot vendored capability MUST NOT leave a
# half-created skills/<name>/ subdir behind. Otherwise compile_vendored could
# silently ship an empty Shape C skeleton that the operator would discover only
# at runtime. Warn + skip means: emit the warning AND do not create the subdir.
if [ -n "$mbuild" ] && [ -d "$mbuild" ]; then
  [ ! -d "$mbuild/skills/test-vendored-missing" ] \
    && _pass "missing vendored snapshot does not create skills/<name>/ subdir" \
    || _fail "missing vendored snapshot does not create skills/<name>/ subdir" "skills/test-vendored-missing/ exists in $mbuild"
fi
rm -rf "$MREPO" "$MOUT_DIR" "$MENV_DIR" "$mbuild"

# --- install.sh: hooks are compiled and placeholders resolved ---
hk_build="$(AI_CONFIG_LOCAL_ENV="$FIX_ENV" bash "$REPO_ROOT/scripts/install.sh" --build-only 2>/dev/null)"
for h in session-agent.sh framework-surface.sh; do
  assert_file "hook compiled: $h" "$hk_build/hooks/$h"
done
# negative guard: the closeout Stop hook was removed (closeout is now
# manual-fire) — a fresh build must NOT compile a closeout hook.
[ -e "$hk_build/hooks/closeout.sh" ] \
  && _fail "build does NOT compile a closeout hook" "hooks/closeout.sh still produced" \
  || _pass "build does NOT compile a closeout hook"
if [ -f "$hk_build/hooks/framework-surface.sh" ]; then
  fs_content="$(cat "$hk_build/hooks/framework-surface.sh")"
  assert_not_contains "framework-surface.sh placeholder resolved" "$fs_content" "@@AI_CONFIG_DIR@@"
  assert_contains "framework-surface.sh has the resolved agentic-os-template path" "$fs_content" "$REPO_ROOT"
fi
[ -x "$hk_build/hooks/session-agent.sh" ] && _pass "compiled hook is executable" \
  || _fail "compiled hook is executable"
rm -rf "$hk_build"

# --- install.sh: settings.json is generated and well-formed ---
st_build="$(AI_CONFIG_LOCAL_ENV="$FIX_ENV" bash "$REPO_ROOT/scripts/install.sh" --build-only 2>/dev/null)"
st="$st_build/settings.json"
assert_file "settings.json generated" "$st"
if [ -f "$st" ]; then
  assert_exit "settings.json is valid JSON" 0 -- jq empty "$st"
  # UserPromptSubmit was the cross-model-review prompt-scan hook, now
  # removed with the capability.: the closeout `Stop` hook was removed
  # (closeout is now manual-fire). PreToolUse / SessionStart are the wired events.
  for ev in PreToolUse SessionStart; do
    has="$(jq -r --arg e "$ev" '.hooks[$e] != null' "$st")"
    assert_eq "settings.json wires $ev" "true" "$has"
  done
  # spine-only base: NO cost/behavior preferences ship in a fresh render. theme +
  # effortLevel are operator-local, carried by preserve-live (proven in the
  # round-trip section below) — a fresh build must not ship them downstream.
  assert_eq "fresh build ships no theme (spine-only base)" "null" "$(jq -r '.theme // "null"' "$st")"
  assert_eq "fresh build ships no effortLevel (spine-only base)" "null" "$(jq -r '.effortLevel // "null"' "$st")"
  # The brain is spine-only: settings.base.json ships ZERO plugin opinions, so a
  # fresh build (no live settings.json) enables NO plugins. Plugin choices are
  # operator-local and carried across re-renders by generate_settings
  # (preserve-live) — proven in the preserve-live round-trip section below.
  assert_eq "settings.json does NOT auto-enable any plugin" \
    "null" "$(jq -r '.enabledPlugins["superpowers@claude-plugins-official"] // null' "$st")"
  assert_eq "settings.json enables no plugins by default (spine-only base)" \
    "0" "$(jq -r '.enabledPlugins | length' "$st")"
  # The agnostic marketplace 'doors' remain so operator-local enabled plugins resolve.
  assert_eq "settings.json keeps known marketplaces" "true" \
    "$(jq -r '(.extraKnownMarketplaces | type == "object") and (.extraKnownMarketplaces | length > 0)' "$st")"
  # hook command points into the TARGET hooks dir, args:[] present
  cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$st")"
  assert_contains "PreToolUse command points at target hooks dir" "$cmd" "$FIX_OUT/hooks/session-agent.sh"
  argn="$(jq -r '.hooks.PreToolUse[0].hooks[0].args | length' "$st")"
  assert_eq "PreToolUse hook has args array" "0" "$argn"
  # negative guard: closeout's Stop hook was removed — settings.json
  # must NOT wire any Stop hook.
  assert_eq "settings.json does NOT wire a Stop hook" "true" \
    "$(jq -r '.hooks.Stop == null' "$st")"
fi
rm -rf "$st_build"

# --- install.sh: generate_settings preserves operator-local settings ---
# The brain ships zero plugin opinions; the operator's LOCAL enabledPlugins +
# agentPushNotifEnabled must survive a re-render (otherwise every install reverts
# them to base — re-enabling disabled plugins, dropping the notif preference).
# Pins that preserve-live round-trip via a full install + mutate + re-install.
pl_out="$(mktemp -d)/target"; mkdir -p "$pl_out"
pl_env="$(mktemp -d)/local.env"
make_local_env "$pl_env" "$pl_out"
AI_CONFIG_LOCAL_ENV="$pl_env" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1
if [ -f "$pl_out/settings.json" ]; then
  assert_eq "fresh install enables no plugins (spine-only base)" \
    "0" "$(jq -r '.enabledPlugins | length' "$pl_out/settings.json")"
  assert_eq "fresh install ships no theme (spine-only base)" "null" \
    "$(jq -r '.theme // "null"' "$pl_out/settings.json")"
  assert_eq "fresh install ships no effortLevel (spine-only base)" "null" \
    "$(jq -r '.effortLevel // "null"' "$pl_out/settings.json")"
  # Operator enables a plugin, sets a notif preference, and sets cost/UI
  # preferences (theme, effortLevel) in their LOCAL config. theme uses a
  # non-default value ("dark") so the assertion proves the OPERATOR's value is
  # carried, not a base default re-asserted.
  jq '.enabledPlugins["claude-md-management@claude-plugins-official"] = true
      | .agentPushNotifEnabled = false
      | .theme = "dark"
      | .effortLevel = "xhigh"' \
    "$pl_out/settings.json" > "$pl_out/settings.json.tmp"
  mv "$pl_out/settings.json.tmp" "$pl_out/settings.json"
  # Re-render: generate_settings must carry the local choices forward.
  AI_CONFIG_LOCAL_ENV="$pl_env" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1
  assert_eq "re-render preserves operator-enabled plugin (preserve-live)" "true" \
    "$(jq -r '.enabledPlugins["claude-md-management@claude-plugins-official"] // "DROPPED"' "$pl_out/settings.json")"
  # NB: use has/if — `.x // "DROPPED"` would wrongly report a preserved `false`
  # as DROPPED (jq's // treats false as empty).
  assert_eq "re-render preserves agentPushNotifEnabled (preserve-live)" "false" \
    "$(jq -r 'if has("agentPushNotifEnabled") then .agentPushNotifEnabled else "DROPPED" end' "$pl_out/settings.json")"
  assert_eq "re-render preserves operator theme (preserve-live)" "dark" \
    "$(jq -r '.theme // "DROPPED"' "$pl_out/settings.json")"
  assert_eq "re-render preserves operator effortLevel (preserve-live)" "xhigh" \
    "$(jq -r '.effortLevel // "DROPPED"' "$pl_out/settings.json")"
  # Hooks remain wired after the preserve-live re-render.
  assert_eq "re-render still wires PreToolUse hook" "true" \
    "$(jq -r '.hooks.PreToolUse != null' "$pl_out/settings.json")"
else
  _fail "preserve-live: full install did not produce settings.json"
fi
rm -rf "$pl_out"

# --- install.sh: --build-only now fully succeeds (deferred from Task 3) ---
ok_build="$(AI_CONFIG_LOCAL_ENV="$FIX_ENV" bash "$REPO_ROOT/scripts/install.sh" --build-only 2>/dev/null)"
ok_status=$?
assert_eq "install.sh --build-only exits 0" "0" "$ok_status"
assert_file "build dir has settings.json" "$ok_build/settings.json"
rm -rf "$ok_build"

# --- install.sh: build manifest is well-formed ---
mf_build="$(AI_CONFIG_LOCAL_ENV="$FIX_ENV" bash "$REPO_ROOT/scripts/install.sh" --build-only 2>/dev/null)"
mf="$mf_build/.build-manifest.json"
assert_file "manifest generated" "$mf"
if [ -f "$mf" ]; then
  assert_exit "manifest is valid JSON" 0 -- jq empty "$mf"
  assert_eq "manifest records the harness" "claude" "$(jq -r '.harness' "$mf")"
  assert_eq "manifest has an adapterVersion" "true" "$(jq -r '(.adapterVersion | length) > 0' "$mf")"
  assert_eq "manifest lists source hashes" "true" \
    "$(jq -r '(.sources | length) > 0' "$mf")"
  assert_eq "manifest lists generated hashes" "true" \
    "$(jq -r '(.generated | length) > 0' "$mf")"
  # generated map keys are repo-relative, values are 64-hex hashes
  badhash="$(jq -r '.generated | to_entries[] | select(.value | test("^[0-9a-f]{64}$") | not) | .key' "$mf")"
  assert_eq "manifest generated hashes are sha256" "" "$badhash"
  # settings.json and a skill file are tracked
  assert_eq "manifest tracks settings.json" "true" \
    "$(jq -r '.generated["settings.json"] != null' "$mf")"
fi
rm -rf "$mf_build"

# --- install.sh: repeated builds are byte-identical ---
det_a="$(AI_CONFIG_LOCAL_ENV="$FIX_ENV" bash "$REPO_ROOT/scripts/install.sh" --build-only 2>/dev/null)"
det_b="$(AI_CONFIG_LOCAL_ENV="$FIX_ENV" bash "$REPO_ROOT/scripts/install.sh" --build-only 2>/dev/null)"
# The whole build tree must be identical, manifest included (it has no timestamp).
diff -r "$det_a" "$det_b" >/dev/null 2>&1
det_status=$?
assert_eq "two builds are byte-identical (diff -r)" "0" "$det_status"
# And the manifest's generated-hash map matches across runs.
ga="$(jq -S '.generated' "$det_a/.build-manifest.json")"
gb="$(jq -S '.generated' "$det_b/.build-manifest.json")"
assert_eq "manifest generated-hash maps are identical across runs" "$ga" "$gb"
rm -rf "$det_a" "$det_b"

# --- install.sh: full run swaps managed paths into the target ---
SW_OUT="$(mktemp -d)/target"; mkdir -p "$SW_OUT"
# Pre-populate the target with content that pre-dates this install run.
# skills/<subdir>/ that has no source in capabilities/ is a "Shape C"
# operator-authored skill — install.sh's per-subdir swap MUST preserve it.
# settings.json is fully managed and is replaced wholesale.
mkdir -p "$SW_OUT/skills/local-shape-c"; printf 'local\n' > "$SW_OUT/skills/local-shape-c/SKILL.md"
printf 'STALE\n' > "$SW_OUT/settings.json"
SW_ENV="$(mktemp -d)/local.env"
make_local_env "$SW_ENV" "$SW_OUT"

AI_CONFIG_LOCAL_ENV="$SW_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1
sw_status=$?
assert_eq "full install exits 0" "0" "$sw_status"
assert_file "target has generated session-agent SKILL.md"   "$SW_OUT/skills/session-agent/SKILL.md"
assert_file "target has generated session-agent hook"        "$SW_OUT/hooks/session-agent.sh"
assert_file "target has generated settings.json"     "$SW_OUT/settings.json"
assert_file "target has build manifest"              "$SW_OUT/.build-manifest.json"
# per-subdir swap preserves unmanaged (Shape C) skill subdirs. The
# install-shape-c.test.sh suite carries the dedicated coverage; this assertion
# is the inverse of the pre-fix "stale skill removed" expectation.
[ -d "$SW_OUT/skills/local-shape-c" ] \
  && _pass "unmanaged skill subdir preserved through swap (Shape C)" \
  || _fail "unmanaged skill subdir was wiped during swap" "skills/local-shape-c gone after install.sh"
assert_exit "swapped settings.json is valid JSON" 0 -- jq empty "$SW_OUT/settings.json"
# No backup or temp dirs left behind.
leftover="$(find "$SW_OUT" -maxdepth 1 -name '.install-bak.*' -o -maxdepth 1 -name '.install-build.*' | head -1)"
assert_eq "no backup/temp dirs left in target" "" "$leftover"
# Idempotent: a second run still succeeds and leaves the same tree.
first_mf="$(jq -S '.generated' "$SW_OUT/.build-manifest.json")"
AI_CONFIG_LOCAL_ENV="$SW_ENV" bash "$REPO_ROOT/scripts/install.sh" >/dev/null 2>&1
sw2_status=$?
assert_eq "second full install exits 0" "0" "$sw2_status"
assert_eq "second install yields the same generated hashes" \
  "$first_mf" "$(jq -S '.generated' "$SW_OUT/.build-manifest.json")"
rm -rf "$SW_OUT"

# --- @@AI_CONFIG_DIR@@ substitution survives # and & in the path ---
SUB_DIR="$(mktemp -d)"
SUB_OUT="$SUB_DIR/out"; mkdir -p "$SUB_OUT"
SUB_ENV="$SUB_DIR/local.env"
make_local_env "$SUB_ENV" "$SUB_OUT"
# local.env is sourced — a value with shell-special chars must be quoted there.
# The point of the test is install.sh's *substitution* of that resolved value.
printf "AI_CONFIG_DIR='/tmp/a#b&c d'\n" >> "$SUB_ENV"
sub_build="$(AI_CONFIG_LOCAL_ENV="$SUB_ENV" bash "$REPO_ROOT/scripts/install.sh" --build-only 2>/dev/null)"
if [ -n "$sub_build" ] && [ -f "$sub_build/hooks/framework-surface.sh" ]; then
  sub_fs="$(cat "$sub_build/hooks/framework-surface.sh")"
  assert_contains "substitution: path with #/& resolved verbatim" "$sub_fs" 'AI_CONFIG_DIR="/tmp/a#b&c d"'
  assert_not_contains "substitution: no placeholder left behind" "$sub_fs" "@@AI_CONFIG_DIR@@"
else
  _fail "substitution: build with a #/& path did not produce framework-surface.sh"
fi
[ -n "$sub_build" ] && rm -rf "$sub_build"
rm -rf "$SUB_DIR"

# --- a capability summary containing ': ' yields valid SKILL.md frontmatter ---
YREPO="$(mktemp -d)"
cp -R "$REPO_ROOT/." "$YREPO/"
rm -rf "$YREPO/.git"
awk '/^summary:/ && !done {print "summary: Walk the protocol: classify, route, verify — colon test"; done=1; next} {print}' \
  "$REPO_ROOT/capabilities/session-agent.md" > "$YREPO/capabilities/session-agent.md"
YOUT="$(mktemp -d)/out"; mkdir -p "$YOUT"
YENV="$(mktemp -d)/local.env"
make_local_env "$YENV" "$YOUT"
ybuild="$(AI_CONFIG_LOCAL_ENV="$YENV" bash "$YREPO/scripts/install.sh" --build-only 2>/dev/null)"
if [ -n "$ybuild" ] && [ -f "$ybuild/skills/session-agent/SKILL.md" ]; then
  yfm="$(awk 'NR==1{next} /^---[[:space:]]*$/{exit} {print}' "$ybuild/skills/session-agent/SKILL.md")"
  assert_contains "colon summary: description is a folded block scalar" "$yfm" "description: >-"
  assert_contains "colon summary: the colon text is preserved" "$yfm" "classify, route, verify"
else
  _fail "colon summary: build did not produce session-agent SKILL.md"
fi
[ -n "$ybuild" ] && rm -rf "$ybuild"
rm -rf "$YREPO"

# --- T-90D: settings.json defaults ---
# Rendered settings.json must NOT auto-enable superpowers@claude-plugins-official
# (moved to catalog.md, operator-discretion). Rendered settings.json must NOT
# contain mcp__codegraph__* perms (codegraph removed from framework integration).
T90D_CFG="$(mktemp -d)"
T90D_OUT="$(mktemp -d)"
make_local_env "$T90D_CFG/local.env" "$T90D_OUT"
T90D_BUILD="$(AI_CONFIG_LOCAL_ENV="$T90D_CFG/local.env" bash "$REPO_ROOT/scripts/install.sh" --build-only 2>/dev/null)"
T90D_SETTINGS="$T90D_BUILD/settings.json"

if [ -f "$T90D_SETTINGS" ]; then
  # superpowers plugin must be absent from enabledPlugins.
  T90D_SUP="$(jq -r '.enabledPlugins["superpowers@claude-plugins-official"] // "ABSENT"' "$T90D_SETTINGS")"
  if [ "$T90D_SUP" = "ABSENT" ]; then
    _pass "settings.json does not auto-enable superpowers@claude-plugins-official"
  else
    _fail "settings.json must NOT auto-enable superpowers plugin" \
      "found .enabledPlugins[superpowers@claude-plugins-official]=$T90D_SUP"
  fi

  # No mcp__codegraph__* perms in permissions.allow.
  T90D_CG_PERMS="$(jq -r '[.permissions.allow[]? | select(startswith("mcp__codegraph__"))] | length' "$T90D_SETTINGS")"
  if [ "$T90D_CG_PERMS" = "0" ]; then
    _pass "settings.json does not contain mcp__codegraph__* perms"
  else
    _fail "settings.json must NOT contain mcp__codegraph__* perms" \
      "found $T90D_CG_PERMS mcp__codegraph__* entries in .permissions.allow[]"
  fi
else
  _fail "T-90D: settings.json not generated by install.sh --build-only" \
    "expected at $T90D_SETTINGS"
fi
[ -n "$T90D_BUILD" ] && rm -rf "$T90D_BUILD"
rm -rf "$T90D_CFG" "$T90D_OUT"
