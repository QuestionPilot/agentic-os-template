#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# Focused acceptance tests for the read-only Codex trust-row detector.
# shellcheck disable=SC2034

CT_SCRIPT="$REPO_ROOT/scripts/check-codex-trust.sh"
CT_TMP="$(mktemp -d)"

ct_config="$CT_TMP/config.toml"
cat > "$ct_config" <<'TOML'
title = "ordinary config # not a project row"

[projects."/workspace/quoted # path"]
trust_level = "trusted" # a comment after the value
description = "trust_level = \"untrusted\" is text"
metadata = { trust_level = "trusted" }

[projects."/workspace/dotted.path"]
trust_level = "untrusted"

[projects."/workspace/escaped\npath"]
trust_level = "trusted"

[other]
trust_level = "trusted"
TOML

ct_out="$(CODEX_HOME= bash "$CT_SCRIPT" --config "$ct_config" 2>&1)"; ct_rc=$?
assert_eq "codex trust: valid TOML reports two trusted rows" "0" "$ct_rc"
assert_contains "codex trust: reports the trusted-row denominator" "$ct_out" "trusted project rows: 2"
assert_contains "codex trust: reports quoted project path" "$ct_out" 'path: "/workspace/quoted # path"'
assert_contains "codex trust: JSON-escapes a control character in a project path" "$ct_out" 'path: "/workspace/escaped\npath"'
assert_not_contains "codex trust: does not report untrusted project path" "$ct_out" "/workspace/dotted.path"
assert_not_contains "codex trust: does not leak a sibling config value" "$ct_out" 'description ='

ct_home="$CT_TMP/codex-home"; mkdir -p "$ct_home"
cp "$ct_config" "$ct_home/config.toml"
ct_out="$(CODEX_HOME="$ct_home" bash "$CT_SCRIPT" 2>&1)"; ct_rc=$?
assert_eq "codex trust: CODEX_HOME default config reports trusted rows" "0" "$ct_rc"
assert_contains "codex trust: CODEX_HOME default config reports its inventory" "$ct_out" "trusted project rows: 2"

cat > "$ct_config" <<'TOML'
[projects]
TOML
ct_out="$(CODEX_HOME= bash "$CT_SCRIPT" --config "$ct_config" 2>&1)"; ct_rc=$?
assert_eq "codex trust: valid empty projects table reports zero" "0" "$ct_rc"
assert_contains "codex trust: zero is explicit" "$ct_out" "trusted project rows: 0"

cat > "$ct_config" <<'TOML'
[projects."/broken"
trust_level = "trusted"
TOML
ct_out="$(CODEX_HOME= bash "$CT_SCRIPT" --config "$ct_config" 2>&1)"; ct_rc=$?
assert_eq "codex trust: malformed TOML fails instead of reporting zero" "2" "$ct_rc"
assert_contains "codex trust: malformed TOML explains the failure" "$ct_out" "config.toml is malformed"

cat > "$ct_config" <<'TOML'
[projects]
"/not-a-table" = "trusted"
TOML
assert_exit "codex trust: unsupported project schema fails instead of reporting zero" 2 -- \
  bash "$CT_SCRIPT" --config "$ct_config"

cat > "$ct_config" <<'TOML'
[projects."/wrong-type"]
trust_level = 1
TOML
assert_exit "codex trust: non-string trust level fails instead of reporting zero" 2 -- \
  bash "$CT_SCRIPT" --config "$ct_config"

cat > "$ct_config" <<'TOML'
[projects."/unknown-level"]
trust_level = "later"
TOML
assert_exit "codex trust: unknown trust level fails instead of reporting zero" 2 -- \
  bash "$CT_SCRIPT" --config "$ct_config"

assert_exit "codex trust: unavailable explicit config fails" 2 -- \
  bash "$CT_SCRIPT" --config "$CT_TMP/missing.toml"
assert_exit "codex trust: unset CODEX_HOME fails" 2 -- \
  env -u CODEX_HOME bash "$CT_SCRIPT"

rm -rf "$CT_TMP"
