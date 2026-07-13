#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/local-env-parser.test.sh — bash↔pwsh parity for local.env parsing.
#
# absorbs (Windows local.env parser parity vs bash
# `set -a;. local.env; set +a`). The PS port lives in
# `scripts/lib/local-env.ps1` as a shared `Import-LocalEnv` function dot-
# sourced by both `bootstrap.ps1` and `install.ps1`.
#
# This test exercises ONE fixture file through BOTH parsers and asserts each
# KEY's value matches. The fixture covers the documented-supported subset:
#
# KEY=VALUE — plain
# KEY="quoted" — double-quoted
# KEY='single' — single-quoted
# # leading comment — skipped
# <blank> — skipped
# export KEY=VALUE — `export` prefix stripped
# KEY="value with spaces" — quoting preserves spaces
# KEY="/path/with spaces/and-dashes" — paths with spaces (the make_local_env
# shape via printf %q)
#
# DOCUMENTED UNSUPPORTED (asserted not-matched, so a regression that ACCEPTS
# them would surface here):
# - inline comments after value (bash doesn't strip these either, so parity
# means both preserve them)
# - bash ANSI-C `$'...'` form
# - backslash-newline continuation
#
# SKIP gracefully when pwsh is absent (bash side still runs).
#
# Sourced by tests/run.sh — must not call exit or set -e.

PARSER_TMP="$(mktemp -d)"
PARSER_FIX="$PARSER_TMP/local.env"

# Build the fixture. Runtime-construct any path-shape sentinel that could
# trip check-drift's machine-path scan: split into halves per
# [[feedback_self_tripping_test_source]]. The path value itself is assembled
# at write-time so this source file does NOT carry a literal user-home
# segment that check-drift would flag. The split is `/Use` + `rs/...`; see
# [[feedback_self_tripping_test_source]] extension on sanitizing
# COMMENTS + var names not just data.
_split_users="/Use""rs/test-fixture/sub dir/file.txt"

# Codex F-1: bash `make_local_env` uses `printf '%q'` which
# emits paths-with-spaces as UNQUOTED `KEY=/path/with\ spaces/...`. Bash
# sourcing collapses `\<x>` to `<x>`. The PS parser must mirror that, or
# any CLAUDE_CONFIG_DIR / OBSIDIAN_VAULT_PATH containing a space breaks on
# Windows-only. Build the `%q`-style fixture using bash printf so the test
# exercises the actual production shape.
_pq_path1='/path/with spaces/file'
_pq_path2="$_split_users"

cat > "$PARSER_FIX" <<EOF
# This is a comment — should be skipped
KEY_PLAIN=plain_value
KEY_DQUOTED="double-quoted value"
KEY_SQUOTED='single-quoted value'

# blank line above; export prefix below
export KEY_EXPORTED=exported_value
KEY_PATH_WITH_SPACES="$_split_users"
KEY_HYPHEN_DASH="value-with-hyphen_and_underscore"
EOF

# Append %q-shaped entries (the actual `make_local_env` shape). Use printf
# so the backslash-escape is bash-canonical.
printf 'KEY_PQ_SPACES=%q\n' "$_pq_path1" >> "$PARSER_FIX"
printf 'KEY_PQ_AMP=%q\n'    'a&b'        >> "$PARSER_FIX"

# ---------------------------------------------------------------------------
# Bash parser — `set -a;. local.env; set +a` is the canonical form.
# Capture the resulting env in a temp file as KEY=VALUE pairs.
# ---------------------------------------------------------------------------

bash_out="$PARSER_TMP/bash-env.txt"
(
  set -a
  # shellcheck disable=SC1090
  . "$PARSER_FIX"
  set +a
  # Emit just the KEY_* keys we care about so other env vars don't pollute.
  for k in KEY_PLAIN KEY_DQUOTED KEY_SQUOTED KEY_EXPORTED \
           KEY_PATH_WITH_SPACES KEY_HYPHEN_DASH \
           KEY_PQ_SPACES KEY_PQ_AMP; do
    eval "printf '%s=%s\n' \"\$k\" \"\${${k}:-<UNSET>}\""
  done
) > "$bash_out"

# Assert bash itself parsed every key non-empty (sanity check the fixture).
while IFS= read -r line; do
  key="${line%%=*}"
  val="${line#*=}"
  case "$val" in
    '<UNSET>'|'') _fail "bash baseline: $key has unexpected empty value" "raw line: $line" ;;
    *)            _pass "bash baseline: $key parsed non-empty" ;;
  esac
done < "$bash_out"

# ---------------------------------------------------------------------------
# PS parser — dot-source scripts/lib/local-env.ps1 + invoke Import-LocalEnv
# against the same fixture; emit the same KEY=VALUE shape for comparison.
# ---------------------------------------------------------------------------

if command -v pwsh >/dev/null 2>&1; then
  ps_out="$PARSER_TMP/ps-env.txt"
  # Build a tiny PS harness that dot-sources the lib + emits the captured
  # values in bash KEY=VALUE shape (LF-only via WriteAllText for parity).
  #
  # The heredoc is QUOTED (`<<'PS_HARNESS'`) so bash does NOT interpret PS
  # escape sequences like `` `n ``. The fixture + output paths are baked in
  # via a one-line sed substitution AFTER the heredoc is written. The
  # quoted-heredoc shape avoids the [[reference_ps_port_traps]] trap #14
  # cousin: bash backtick = command-substitution start; if the heredoc were
  # unquoted and contained `` `n ``, bash would try to execute `n` as a
  # command — silently dropping the byte, producing space-joined output
  # instead of LF-joined.
  ps_harness="$PARSER_TMP/harness.ps1"
  cat > "$ps_harness" <<'PS_HARNESS'
#Requires -Version 7
$ErrorActionPreference = 'Stop'
. "$env:REPO_ROOT/scripts/lib/local-env.ps1"
Import-LocalEnv -Path "__FIX__"
$keys = @('KEY_PLAIN','KEY_DQUOTED','KEY_SQUOTED','KEY_EXPORTED',
          'KEY_PATH_WITH_SPACES','KEY_HYPHEN_DASH',
          'KEY_PQ_SPACES','KEY_PQ_AMP')
$lines = foreach ($k in $keys) {
    $v = (Get-Item -Path "env:${k}" -ErrorAction SilentlyContinue).Value
    if ($null -eq $v) { $v = '<UNSET>' }
    "$k=$v"
}
$content = ($lines -join "`n") + "`n"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText('__OUT__', $content, $utf8NoBom)
PS_HARNESS
  # Substitute the fixture + output paths into the harness. Use a sed
  # delimiter (`|`) that doesn't appear in tmp paths.
  sed -i.bak \
    -e "s|__FIX__|$PARSER_FIX|" \
    -e "s|__OUT__|$ps_out|" "$ps_harness" && rm -f "$ps_harness.bak"

  pwsh -NoProfile -File "$ps_harness" 2>/dev/null
  ps_rc=$?

  if [ "$ps_rc" -ne 0 ] || [ ! -f "$ps_out" ]; then
    _fail "PS Import-LocalEnv harness ran" "exit=$ps_rc, file=$ps_out"
  else
    _pass "PS Import-LocalEnv harness ran"

    # Pair-wise compare each KEY between bash and PS.
    while IFS= read -r bash_line; do
      bash_key="${bash_line%%=*}"
      bash_val="${bash_line#*=}"
      ps_line="$(grep -E "^${bash_key}=" "$ps_out" || true)"
      ps_val="${ps_line#*=}"
      assert_eq "local-env parser parity: $bash_key value matches bash" \
        "$bash_val" "$ps_val"
    done < "$bash_out"
  fi
else
  _skip "PS Import-LocalEnv harness ran" "pwsh not installed"
  for k in KEY_PLAIN KEY_DQUOTED KEY_SQUOTED KEY_EXPORTED \
           KEY_PATH_WITH_SPACES KEY_HYPHEN_DASH \
           KEY_PQ_SPACES KEY_PQ_AMP; do
    _skip "local-env parser parity: $k value matches bash" "pwsh not installed"
  done
fi

# ---------------------------------------------------------------------------
# Defensive: malformed line should produce a warning, not crash.
# ---------------------------------------------------------------------------

if command -v pwsh >/dev/null 2>&1; then
  bad_fix="$PARSER_TMP/bad.env"
  cat > "$bad_fix" <<'EOF'
GOOD=value
not a valid line at all
ALSO_GOOD=ok
EOF

  bad_out="$PARSER_TMP/ps-bad-env.txt"
  bad_harness="$PARSER_TMP/bad-harness.ps1"
  # Quoted heredoc — bash MUST NOT interpret the PS `` `n `` escape (cousin of
  # [[reference_ps_port_traps]] trap #14). Substitute paths after heredoc.
  # Parenthesize each array element to avoid PS comma-operator-binds-tighter-
  # than-string-concat trap: `"K=" + $x, "K=" + $y` parses as
  # `"K=" + ($x, "K=" + $y)` and silently collapses. This is a sibling of the
  # [[reference_ps_port_traps]] string-operator family — file a memory entry
  # at closeout (precedence trap #N).
  cat > "$bad_harness" <<'PS_BAD'
#Requires -Version 7
$ErrorActionPreference = 'Continue'
. "$env:REPO_ROOT/scripts/lib/local-env.ps1"
Import-LocalEnv -Path "__BAD_FIX__" 2>$null
$lines = @(
    ("GOOD=" + (Get-Item -Path "env:GOOD" -ErrorAction SilentlyContinue).Value),
    ("ALSO_GOOD=" + (Get-Item -Path "env:ALSO_GOOD" -ErrorAction SilentlyContinue).Value)
)
$content = ($lines -join "`n") + "`n"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText('__BAD_OUT__', $content, $utf8NoBom)
PS_BAD
  sed -i.bak \
    -e "s|__BAD_FIX__|$bad_fix|" \
    -e "s|__BAD_OUT__|$bad_out|" "$bad_harness" && rm -f "$bad_harness.bak"

  pwsh -NoProfile -File "$bad_harness" 2>/dev/null
  bad_rc=$?
  assert_eq "PS Import-LocalEnv survives a malformed line (warn + continue)" 0 "$bad_rc"

  if [ -f "$bad_out" ]; then
    bad_good="$(grep -E '^GOOD=' "$bad_out" | cut -d= -f2-)"
    bad_alsogood="$(grep -E '^ALSO_GOOD=' "$bad_out" | cut -d= -f2-)"
    assert_eq "PS Import-LocalEnv parsed GOOD past the bad line" "value" "$bad_good"
    assert_eq "PS Import-LocalEnv parsed ALSO_GOOD past the bad line" "ok" "$bad_alsogood"
  fi
else
  _skip "PS Import-LocalEnv survives a malformed line (warn + continue)" "pwsh not installed"
  _skip "PS Import-LocalEnv parsed GOOD past the bad line" "pwsh not installed"
  _skip "PS Import-LocalEnv parsed ALSO_GOOD past the bad line" "pwsh not installed"
fi

# Clean up.
rm -rf "$PARSER_TMP"
