#!/usr/bin/env bash
# standalone-invocation guard: this file is SOURCED by tests/run.sh (which
# defines the assert_* helpers). Run standalone the helpers are absent, assertions
# error, yet the file still exits 0 — a false green. Bail loudly instead.
declare -F assert_exit >/dev/null 2>&1 || { printf 'ERROR: run via tests/run.sh (e.g. bash tests/run.sh <stem>), not standalone\n' >&2; exit 1; }
# tests/vault-scaffolding-retrieval.test.sh — the scaffold's retrieval baseline
# (bin/vault-search.sh + bin/retrieval-evals.sh + 00-System/Retrieval Fixtures.md)
# and its generated session index (bin/generate-session-index.js), plus the two
# audit checks that gate them.
#
# Pins the contract these ship with:
#   1. the shipped fixture set is GREEN against the pristine scaffold — every
#      positive surfaces its target, every negative control reports absence;
#   2. a broken fixture pointer FAILs the audit (positive control: the check can
#      actually go red, so a green run means something);
#   3. a fixture set stripped of its negative controls FAILs — a surface that can
#      never say "nothing here" is untestable;
#   4. the session index --check is green on the pristine (EMPTY) scaffold: a
#      fresh vault has zero session logs, and the truthful zero-coverage view
#      must be byte-stable rather than an error;
#   5. the empty view states the zero rather than implying coverage it lacks;
#   6. a hand-edited session index FAILs the audit as drift;
#   7. an optional artifact that is ABSENT reports N/A — a visible line, never
#      silence, and never a hard FAIL on something a fresh vault never made.
#
# Runs against TMP COPIES of the scaffolding — never mutates the live repo tree.
# Sourced by tests/run.sh; uses assert_* helpers from tests/lib.sh. Never call
# `exit` — failures bubble through assertion counters.

VSR_SCAFFOLD="$REPO_ROOT/obsidian/vault-scaffolding"
VSR_EVALS="bin/retrieval-evals.sh"
VSR_SEARCH="bin/vault-search.sh"
VSR_SESSION="bin/generate-session-index.js"
VSR_AUDIT="bin/memory-vault-audit.js"
VSR_FIXTURES="00-System/Retrieval Fixtures.md"
VSR_VIEW="90-Indexes/Session Index.md"

if ! command -v node >/dev/null 2>&1; then
  _skip "vault-scaffolding-retrieval suite" "node not installed"
elif [ ! -f "$VSR_SCAFFOLD/$VSR_SESSION" ]; then
  _fail "session index generator present" "missing: $VSR_SCAFFOLD/$VSR_SESSION"
else
  VSR_TMP="$(mktemp -d)/vault"
  cp -R "$VSR_SCAFFOLD" "$VSR_TMP"

  # --- T1: the shipped fixture set is green on the pristine scaffold.
  # ripgrep is the baseline's only external dependency; without it the eval
  # cannot run at all, and a skipped instrument must say so rather than pass.
  if ! command -v rg >/dev/null 2>&1; then
    _skip "vault-scaffolding-retrieval: retrieval evals" "ripgrep (rg) not installed"
  else
    assert_exit "shipped retrieval fixtures pass on the pristine scaffold" 0 -- \
      bash "$VSR_TMP/$VSR_EVALS"

    # A green run must not be green because nothing ran. Prove the runner parsed
    # a real fixture set and exercised both arms.
    vsr_evals_out="$(bash "$VSR_TMP/$VSR_EVALS" 2>&1)"
    assert_contains "the eval run reports a non-zero fixture denominator" \
      "$vsr_evals_out" "0 failed ("
    assert_contains "the eval run exercises negative controls" \
      "$vsr_evals_out" "[negative-control] correctly found nothing"

    # The baseline must exclude the fixture note from the CALLER surface, not
    # merely from the runner's view — otherwise a control passes for a caller
    # who gets a match. Ask a control query directly.
    vsr_probe="$(bash "$VSR_TMP/$VSR_SEARCH" "kubernetes ingress controller" --scope durable --paths-only 2>&1)"
    assert_not_contains "the baseline itself excludes the fixture note from results" \
      "$vsr_probe" "Retrieval Fixtures.md"

    # --- T1b: --context actually renders context lines. The display filter must
    # accept ripgrep's dash-separated context records (`path-lineno-text`), not
    # just the colon-separated match records — a colon-only filter silently
    # dropped every context line the caller asked for (panel finding).
    vsr_ctx_out="$(bash "$VSR_TMP/$VSR_SEARCH" "source of truth" --context 1 2>&1)"
    assert_contains "--context renders at least one context line (L<n>| marker)" \
      "$vsr_ctx_out" "| "
    printf '%s\n' "$vsr_ctx_out" | grep -Eq 'L[0-9]+\|' \
      && _pass "--context emits dash-record context lines" \
      || _fail "--context emits dash-record context lines" "no L<n>| line in output"

    # --- T1c: --paths-only keeps stdout machine-clean on an empty result. The
    # no-match notice must go to stderr there; a caller consuming stdout must
    # never mistake prose for a path (panel finding).
    vsr_po_stdout="$(bash "$VSR_TMP/$VSR_SEARCH" "zzzz-no-such-concept-in-this-vault" --paths-only 2>/dev/null)"
    vsr_po_rc=$?
    assert_eq "empty --paths-only exits 1" 1 "$vsr_po_rc"
    assert_eq "empty --paths-only emits nothing on stdout" "" "$vsr_po_stdout"

    # --- T1d: the eval runner normalizes Windows-shaped baseline output. On
    # Windows, a baseline that misses its own normalization emits
    # `<root>/<relative-with-backslashes>` and the runner's exact-line compare
    # then fails EVERY positive fixture while retrieval is actually correct.
    # Pin the runner-side guard with a wrapper baseline that mangles the real
    # output into exactly that shape; the shipped fixture set must stay green.
    VSR_WIN="$(mktemp -d)/vault"
    cp -R "$VSR_SCAFFOLD" "$VSR_WIN"
    mv "$VSR_WIN/bin/vault-search.sh" "$VSR_WIN/bin/vault-search-real.sh"
    # Stub factory: wrap the real baseline and mangle each output line as
    # `<prefix><sep><relative-with-backslashes>`. The prefix rides in ENVIRON,
    # never `awk -v` — the shipped fix's own rule (a -v value undergoes escape
    # processing, so backslashes in it would be interpreted).
    vsr_win_stub() {
      printf '%s\n' \
        '#!/usr/bin/env bash' \
        'DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' \
        'ROOT="$(cd "$DIR/.." && pwd)"' \
        'out="$(bash "$DIR/vault-search-real.sh" "$@")"; rc=$?' \
        "[ -n \"\$out\" ] && printf '%s\\n' \"\$out\" | VS_PREFIX=\"$1\" VS_SEP=\"$2\" awk 'BEGIN { p = ENVIRON[\"VS_PREFIX\"]; s = ENVIRON[\"VS_SEP\"] } { gsub(\"/\", \"\\\\\"); print p s \$0 }'" \
        'exit "$rc"' > "$VSR_WIN/bin/vault-search.sh"
      chmod +x "$VSR_WIN/bin/vault-search.sh"
    }
    vsr_win_stub "\$ROOT" "/"
    assert_exit "fixtures stay green when the baseline emits absolute+backslash paths" 0 -- \
      bash "$VSR_WIN/$VSR_EVALS"

    # Restraint: normalization must not have loosened the compare into a
    # substring/suffix match — a wrong-directory hit is still a miss.
    vsr_win_stub "\$ROOT" "/wrong\\\\"
    assert_exit "a wrong-directory hit still fails the fixture compare" 1 -- \
      bash "$VSR_WIN/$VSR_EVALS"

    # Restraint: normalization is ROOT-ANCHORED. A line that does NOT sit
    # under the vault root's literal `<root>/` spelling (here: root followed
    # by a backslash — the shape of a sibling POSIX path whose name contains
    # backslashes) must pass through untouched and stay a miss.
    vsr_win_stub "\$ROOT" "\\\\"
    assert_exit "a non-root-anchored backslash path is not normalized into a match" 1 -- \
      bash "$VSR_WIN/$VSR_EVALS"

    # The NATIVE-root branch, via the script's test-injection seam: the stub
    # emits `C:/fake vault/<relative-with-backslashes>` and the runner is told
    # that native root; normalization must strip it and the fixtures go green.
    vsr_win_stub "C:/fake vault" "/"
    RETRIEVAL_EVALS_NATIVE_ROOT="C:/fake vault" bash "$VSR_WIN/$VSR_EVALS" >/dev/null 2>&1
    vsr_native_rc=$?
    assert_eq "the native-root branch strips an injected drive-letter root" 0 "$vsr_native_rc"
    # ...and WITHOUT the seam the same drive-letter lines must stay misses on
    # POSIX (no native root exists here) — red, not silently green.
    assert_exit "drive-letter lines stay misses when no native root exists" 1 -- \
      bash "$VSR_WIN/$VSR_EVALS"

    # A baseline that CRASHES after emitting output must surface as a baseline
    # error, never as "no matches" — the exit-status capture is load-bearing
    # (the old in-pipeline PIPESTATUS could never see it).
    printf '%s\n' '#!/usr/bin/env bash' 'echo garbage-line' 'exit 2' \
      > "$VSR_WIN/bin/vault-search.sh"
    chmod +x "$VSR_WIN/bin/vault-search.sh"
    vsr_err_out="$(bash "$VSR_WIN/$VSR_EVALS" 2>&1)"
    vsr_err_rc=$?
    assert_eq "a crashing baseline fails the eval run" 1 "$vsr_err_rc"
    assert_contains "a crashing baseline is reported as a baseline error, not as no-matches" \
      "$vsr_err_out" "baseline errored (exit 2)"
    rm -rf "${VSR_WIN%/vault}"
  fi

  # --- T2: session index --check is green on the pristine, EMPTY scaffold.
  assert_exit "session index --check passes on the pristine (empty) scaffold" 0 -- \
    node "$VSR_TMP/$VSR_SESSION" --check

  # --- T3: the empty view is TRUTHFUL — it states the zero and does not print a
  # sessions table it has no rows for. A header-only view that reads as
  # "the archive is indexed" is the false clean this generator exists to avoid.
  vsr_view="$(cat "$VSR_TMP/$VSR_VIEW")"
  assert_contains "the empty session index states zero coverage" \
    "$vsr_view" "Session logs: **0**"
  assert_contains "the empty session index says plainly that no logs exist yet" \
    "$vsr_view" "No session logs exist yet"
  assert_not_contains "the empty session index omits the sessions table" \
    "$vsr_view" "| Date | Harness | Machine |"

  # --- T4: the audit is green on the pristine scaffold, with BOTH new checks
  # actually reporting (a check that silently did not run is not a pass).
  vsr_audit_out="$(node "$VSR_TMP/$VSR_AUDIT" 2>&1)"; vsr_audit_rc=$?
  assert_eq "the audit is green on the pristine scaffold" 0 "$vsr_audit_rc"
  assert_contains "the audit reports the retrieval-pointer check" \
    "$vsr_audit_out" "PASS retrieval fixture pointers resolve"
  assert_contains "the audit reports the session-index view check" \
    "$vsr_audit_out" "PASS session index view matches regeneration"

  rm -rf "${VSR_TMP%/vault}"

  # --- T5: positive control — a broken fixture pointer FAILs the audit.
  # Runs on a fresh copy so the only defect in the tree is the planted one.
  VSR_T5="$(mktemp -d)/vault"
  cp -R "$VSR_SCAFFOLD" "$VSR_T5"
  # Re-point R1 at a note that does not exist. sed on a whole table row keeps the
  # row shape intact, so the parse still succeeds and the FAIL is attributable to
  # the pointer check rather than to a shape change.
  sed -e 's#| R1 |.*#| R1 | promotion test | durable | 4 | `00-System/__no-such-note__.md` | policy-lookup |#' \
    "$VSR_T5/$VSR_FIXTURES" > "$VSR_T5/$VSR_FIXTURES.new"
  mv "$VSR_T5/$VSR_FIXTURES.new" "$VSR_T5/$VSR_FIXTURES"
  vsr_bp_out="$(node "$VSR_T5/$VSR_AUDIT" 2>&1)"; vsr_bp_rc=$?
  assert_eq "a broken fixture pointer FAILs the audit (non-zero exit)" 1 "$vsr_bp_rc"
  assert_contains "a broken fixture pointer surfaces as a FAIL line (not WARN)" \
    "$vsr_bp_out" "FAIL retrieval fixture broken pointer: R1 -> 00-System/__no-such-note__.md does not exist"
  rm -rf "${VSR_T5%/vault}"

  # --- T6: a fixture set with no negative controls FAILs. An instrument that can
  # never report absence will always find something.
  VSR_T6="$(mktemp -d)/vault"
  cp -R "$VSR_SCAFFOLD" "$VSR_T6"
  grep -v '^| N[0-9]* |' "$VSR_T6/$VSR_FIXTURES" > "$VSR_T6/$VSR_FIXTURES.new"
  mv "$VSR_T6/$VSR_FIXTURES.new" "$VSR_T6/$VSR_FIXTURES"
  vsr_nc_out="$(node "$VSR_T6/$VSR_AUDIT" 2>&1)"; vsr_nc_rc=$?
  assert_eq "a fixture set with no negative controls FAILs the audit" 1 "$vsr_nc_rc"
  assert_contains "the missing-negative-controls FAIL names the reason" \
    "$vsr_nc_out" "FAIL retrieval fixtures: no negative controls"
  rm -rf "${VSR_T6%/vault}"

  # --- T7: a hand-edited session index FAILs the audit as drift.
  VSR_T7="$(mktemp -d)/vault"
  cp -R "$VSR_SCAFFOLD" "$VSR_T7"
  printf 'HAND EDIT\n' >> "$VSR_T7/$VSR_VIEW"
  assert_exit "a hand-edited session index fails generator --check" 1 -- \
    node "$VSR_T7/$VSR_SESSION" --check
  vsr_dr_out="$(node "$VSR_T7/$VSR_AUDIT" 2>&1)"; vsr_dr_rc=$?
  assert_eq "a hand-edited session index FAILs the audit (non-zero exit)" 1 "$vsr_dr_rc"
  assert_contains "session index drift surfaces as a FAIL line" \
    "$vsr_dr_out" "FAIL session index drift:"
  rm -rf "${VSR_T7%/vault}"

  # --- T8: NOT-APPLICABLE, not silence and not a FAIL. Deleting the optional
  # generator must leave the audit green with a visible N/A line — a fresh vault
  # that never adopted the session index is not a broken vault.
  VSR_T8="$(mktemp -d)/vault"
  cp -R "$VSR_SCAFFOLD" "$VSR_T8"
  rm -f "$VSR_T8/$VSR_SESSION"
  vsr_na_out="$(node "$VSR_T8/$VSR_AUDIT" 2>&1)"; vsr_na_rc=$?
  assert_eq "an absent session index generator does not FAIL the audit" 0 "$vsr_na_rc"
  assert_contains "an absent session index generator reports a visible N/A line" \
    "$vsr_na_out" "N/A  session index generator absent"
  assert_contains "the audit summary counts the n/a outcome" \
    "$vsr_na_out" " n/a, "
  rm -rf "${VSR_T8%/vault}"

  # --- T9: same for the fixture note. Removing it also breaks the wikilinks that
  # point at it (so the audit exit code is not asserted here — that FAIL belongs
  # to checkWikilinks); what MUST hold is that the pointer check reports N/A
  # rather than passing silently or failing on an artifact that was never made.
  VSR_T9="$(mktemp -d)/vault"
  cp -R "$VSR_SCAFFOLD" "$VSR_T9"
  rm -f "$VSR_T9/$VSR_FIXTURES"
  vsr_na2_out="$(node "$VSR_T9/$VSR_AUDIT" 2>&1 || true)"
  assert_contains "absent retrieval fixtures report a visible N/A line" \
    "$vsr_na2_out" "N/A  retrieval fixtures absent"
  assert_not_contains "absent retrieval fixtures do not report a pointer PASS" \
    "$vsr_na2_out" "PASS retrieval fixture pointers resolve"
  rm -rf "${VSR_T9%/vault}"
fi
