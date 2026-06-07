#!/usr/bin/env bash
# tests/make-verify.test.sh — assert the Makefile contract + Pre-Push
# surface contract + internal-vs-boundary doc + code-change.md pointer.
#
# Per [[reference_shell_grep_overlay]]: use /usr/bin/grep explicitly so the
# bash subshell sees BSD grep semantics, not the interactive zsh ugrep alias.
# Per [[reference_awk_portability]]: wrap awk with LC_ALL=C to avoid
# locale-dependent gsub no-op behavior under empty LANG.

GREP=/usr/bin/grep

# --- Makefile contract -----------------------------------------------------

assert_file "Makefile exists at repo root" "$REPO_ROOT/Makefile"

# Per-target presence — match `^<target>:` at line start (POSIX-portable
# Makefile rule definition).
for target in verify test validate drift render; do
  if $GREP -qE "^${target}:" "$REPO_ROOT/Makefile"; then
    _pass "Makefile defines target: ${target}"
  else
    _fail "Makefile defines target: ${target}" \
          "no '^${target}:' line found"
  fi
done

# verify recipe must invoke test, validate, drift sequentially via $(MAKE) —
# NOT via a prerequisite list. Prerequisite-list form
# (`verify: test validate drift`) loses fail-fast ordering under `make -j`.
# Sequential $(MAKE) calls enforce order even under -j. Pin the sequential
# shape (Codex F-1).
#
# Use awk to extract just the verify recipe and check sequential invocations.
VERIFY_RECIPE="$(LC_ALL=C awk '
  /^verify:/{f=1; next}
  /^[a-zA-Z]/{f=0}
  f
' "$REPO_ROOT/Makefile")"
for sub in test validate drift; do
  if printf '%s\n' "$VERIFY_RECIPE" | $GREP -qE "\\\$\\(MAKE\\) ${sub}\$"; then
    _pass "Makefile verify recipe sequentially calls \$(MAKE) ${sub}"
  else
    _fail "Makefile verify recipe sequentially calls \$(MAKE) ${sub}" \
          "expected '\$(MAKE) ${sub}' line in verify recipe"
  fi
done

# PHONY: must include EVERY public target (hygienic against same-named files
# AND defends against bare `verify` being treated as a real file). Per Codex
# missing-tests suggestion.
for phony_target in verify test validate drift render; do
  if $GREP -qE "^\.PHONY:.*\\b${phony_target}\\b" "$REPO_ROOT/Makefile"; then
    _pass "Makefile marks ${phony_target} as .PHONY"
  else
    _fail "Makefile marks ${phony_target} as .PHONY" \
          "expected '^.PHONY:' line including '${phony_target}'"
  fi
done

# verify recipe must use sequential $(MAKE) invocations, NOT a prerequisite
# list. Prerequisite-list form (`verify: test validate drift`) loses
# fail-fast ordering under `make -j` (Codex F-1). Pin the sequential
# recipe shape.
if $GREP -qE '^	@?\$\(MAKE\) test' "$REPO_ROOT/Makefile"; then
  _pass "Makefile verify recipe calls \$(MAKE) test sequentially"
else
  _fail "Makefile verify recipe calls \$(MAKE) test sequentially" \
        "expected '\t\$(MAKE) test' line in recipe"
fi

# The drift recipe must use $$CLAUDE_CONFIG_DIR (shell-time expansion) — Make
# substitutes $$ → $, so the shell sees the env var, not an empty string.
# Codex missing-tests pin.
if $GREP -qE 'check-drift.sh --manifest "\$\$CLAUDE_CONFIG_DIR"' "$REPO_ROOT/Makefile"; then
  _pass "Makefile drift recipe uses \$\$CLAUDE_CONFIG_DIR (shell-time expansion)"
else
  _fail "Makefile drift recipe uses \$\$CLAUDE_CONFIG_DIR (shell-time expansion)" \
        "expected 'check-drift.sh --manifest \"\$\$CLAUDE_CONFIG_DIR\"'"
fi

# --- Pre-Push sections in harness templates --------------------------------

for tpl in \
  "harnesses/claude/CLAUDE.template.md" \
  "harnesses/codex/AGENTS.template.md"; do
  if $GREP -qE '^## Pre-Push' "$REPO_ROOT/$tpl"; then
    _pass "${tpl} has ## Pre-Push section"
  else
    _fail "${tpl} has ## Pre-Push section" \
          "no '^## Pre-Push' header found"
  fi

  # Extract the section body and harden the content assertion — must name
  # `make verify` AND each underlying gate inside the Pre-Push section
  # specifically, not just somewhere in the template. Per Codex
  # missing-tests pin.
  PREPUSH_BODY="$(LC_ALL=C awk '
    /^## Pre-Push/{f=1; next}
    /^## /{f=0}
    f
  ' "$REPO_ROOT/$tpl")"
  assert_contains "${tpl} Pre-Push body names 'make verify'" \
    "$PREPUSH_BODY" "make verify"
  assert_contains "${tpl} Pre-Push body names tests/run.sh" \
    "$PREPUSH_BODY" "tests/run.sh"
  assert_contains "${tpl} Pre-Push body names scripts/validate.sh" \
    "$PREPUSH_BODY" "scripts/validate.sh"
  assert_contains "${tpl} Pre-Push body names check-drift.sh" \
    "$PREPUSH_BODY" "check-drift.sh"

  # Ordering: ## Pre-Push must appear before ## Ground Rules in both
  # templates so operators read the verification gate before the rule
  # list. Per Codex missing-tests pin.
  PRE_LINE="$($GREP -nE '^## Pre-Push' "$REPO_ROOT/$tpl" | head -1 | cut -d: -f1)"
  GR_LINE="$($GREP -nE '^## Ground Rules' "$REPO_ROOT/$tpl" | head -1 | cut -d: -f1)"
  if [ -n "$PRE_LINE" ] && [ -n "$GR_LINE" ] && [ "$PRE_LINE" -lt "$GR_LINE" ]; then
    _pass "${tpl} Pre-Push appears before Ground Rules"
  else
    _fail "${tpl} Pre-Push appears before Ground Rules" \
          "Pre-Push line ($PRE_LINE) not strictly before Ground Rules line ($GR_LINE)"
  fi
done

# --- Internal-vs-boundary section in core/operating-system.md -------------

if $GREP -qE '^## Internal vs Boundary' "$REPO_ROOT/core/operating-system.md"; then
  _pass "core/operating-system.md has ## Internal vs Boundary section"
else
  _fail "core/operating-system.md has ## Internal vs Boundary section" \
        "no '^## Internal vs Boundary' header"
fi

# Extract the section body (between the section header and the next '## '
# header or EOF). LC_ALL=C wraps awk per portability lesson.
OPSYS_BODY="$(LC_ALL=C awk '
  /^## Internal vs Boundary/{f=1; next}
  /^## /{f=0}
  f
' "$REPO_ROOT/core/operating-system.md")"
assert_contains "core/operating-system.md Internal vs Boundary names \$CLAUDE_CONFIG_DIR" \
  "$OPSYS_BODY" '$CLAUDE_CONFIG_DIR'
assert_contains "core/operating-system.md Internal vs Boundary uses 'internal'" \
  "$OPSYS_BODY" "internal"
assert_contains "core/operating-system.md Internal vs Boundary uses 'boundary'" \
  "$OPSYS_BODY" "boundary"

# --- make help shows $CLAUDE_CONFIG_DIR (no backslash) --------------------
# Per Codex missing-tests pin: assert `make help` renders the literal
# $CLAUDE_CONFIG_DIR, NOT a backslashed `\$CLAUDE_CONFIG_DIR`. The Makefile
# uses `$$CLAUDE_CONFIG_DIR` (Make-level $ escape) without a leading
# backslash. Skip if `make` isn't on PATH (CI containers without build-essential).
if command -v make >/dev/null 2>&1; then
  HELP_OUT="$(cd "$REPO_ROOT" && make help 2>&1)"
  assert_contains "make help shows literal \$CLAUDE_CONFIG_DIR" \
    "$HELP_OUT" '$CLAUDE_CONFIG_DIR'
  assert_not_contains "make help has no backslash-dollar prefix" \
    "$HELP_OUT" '\$CLAUDE_CONFIG_DIR'
else
  _skip "make help shows literal \$CLAUDE_CONFIG_DIR" "make not on PATH"
fi

# --- verification/code-change.md names make verify -------------------------

if $GREP -qE 'make verify' "$REPO_ROOT/verification/code-change.md"; then
  _pass "verification/code-change.md names 'make verify'"
else
  _fail "verification/code-change.md names 'make verify'" \
        "no 'make verify' substring"
fi

# --- Fresh-checkout safety: make test/test-fast degrade when tests/ absent --
# The acceptance suite ships with the framework, but a partial checkout or a
# pre-suite snapshot can lack tests/. A bare `bash tests/run.sh` recipe would
# hard-fail "No such file" there — breaking `make verify`, which CONTRIBUTING
# tells contributors to run. The test/test-fast recipes must presence-guard
# tests/run.sh. Prove it BEHAVIORALLY: copy the SHIPPED Makefile into a
# tests/-absent sandbox and assert `make test`/`make test-fast` exit 0 with a
# skip notice. Fixed result count (4) regardless of make presence so the.ps1
# twin's _Skip count stays in lockstep. Skip the live `make` runs when make is
# not on PATH (CI containers without build-essential).
if command -v make >/dev/null 2>&1; then
  MV_SANDBOX="$(mktemp -d)"
  cp "$REPO_ROOT/Makefile" "$MV_SANDBOX/Makefile"   # no tests/ dir = public-snapshot condition
  for mvtgt in test test-fast; do
    mv_out="$(cd "$MV_SANDBOX" && make "$mvtgt" 2>&1)"; mv_rc=$?
    if [ "$mv_rc" -eq 0 ]; then
      _pass "make ${mvtgt} exits 0 when tests/ absent (public-snapshot safety)"
    else
      _fail "make ${mvtgt} exits 0 when tests/ absent (public-snapshot safety)" \
            "rc=$mv_rc; output: $mv_out"
    fi
    if printf '%s' "$mv_out" | $GREP -qiE 'not shipped|maintained upstream|skip'; then
      _pass "make ${mvtgt} prints a skip notice when tests/ absent"
    else
      _fail "make ${mvtgt} prints a skip notice when tests/ absent" \
            "expected an upstream/skip notice; got: $mv_out"
    fi
  done
  rm -rf "$MV_SANDBOX"
  unset MV_SANDBOX mv_out mv_rc mvtgt
  # Failure propagation: when tests/run.sh IS present, a nonzero suite exit must
  # propagate through `make test` — the presence-guard must not mask private
  # suite failures (e.g. a future `bash tests/run.sh || true` regression would
  # pass the public-snapshot skip guard above while silently swallowing real
  # failures). Sandbox a Makefile + a tests/run.sh that exits 1; `make test`
  # must exit nonzero.
  MVF_SANDBOX="$(mktemp -d)"
  cp "$REPO_ROOT/Makefile" "$MVF_SANDBOX/Makefile"
  mkdir -p "$MVF_SANDBOX/tests"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$MVF_SANDBOX/tests/run.sh"
  chmod +x "$MVF_SANDBOX/tests/run.sh"
  ( cd "$MVF_SANDBOX" && make test >/dev/null 2>&1 ); mvf_rc=$?
  if [ "$mvf_rc" -ne 0 ]; then
    _pass "make test propagates a nonzero tests/run.sh exit (no masking)"
  else
    _fail "make test propagates a nonzero tests/run.sh exit (no masking)" \
          "expected nonzero rc; got 0 — the guard is masking private-suite failures"
  fi
  rm -rf "$MVF_SANDBOX"
  unset MVF_SANDBOX mvf_rc
  # Fresh-clone safety: `make verify` → `make drift` needs CLAUDE_CONFIG_DIR + a
  # rendered manifest. On a bare public clone (pre-bootstrap) it is unset; the
  # drift recipe must skip + exit 0 rather than erroring "--manifest needs a
  # target directory", so `make verify` is fresh-clone-safe. (Surfaced by the
  # convergence adversarial pass.)
  mvd_out="$(env -u CLAUDE_CONFIG_DIR make -C "$REPO_ROOT" drift 2>&1)"; mvd_rc=$?
  if [ "$mvd_rc" -eq 0 ] && printf '%s' "$mvd_out" | $GREP -qiE 'not set|skipping'; then
    _pass "make drift exits 0 + skips when CLAUDE_CONFIG_DIR unset (fresh-clone safety)"
  else
    _fail "make drift exits 0 + skips when CLAUDE_CONFIG_DIR unset (fresh-clone safety)" \
          "rc=$mvd_rc; output: $mvd_out"
  fi
  unset mvd_out mvd_rc
else
  for mvtgt in test test-fast; do
    _skip "make ${mvtgt} exits 0 when tests/ absent (public-snapshot safety)" "make not on PATH"
    _skip "make ${mvtgt} prints a skip notice when tests/ absent" "make not on PATH"
  done
  _skip "make test propagates a nonzero tests/run.sh exit (no masking)" "make not on PATH"
  _skip "make drift exits 0 + skips when CLAUDE_CONFIG_DIR unset (fresh-clone safety)" "make not on PATH"
  unset mvtgt
fi
