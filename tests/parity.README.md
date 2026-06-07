# Cross-shell parity drift detector

`tests/parity.test.sh` + `tests/parity.test.ps1` enforce bash↔pwsh
behavioral parity for the four cross-shell surfaces shipped under
Windows-native full parity:

1. **validate** — `scripts/validate.sh` vs `scripts/validate.ps1` on an
   isolated tmp fixture.
2. **install --build-only** — `scripts/install.sh --build-only` vs
   `scripts/install.ps1 --build-only` against the same `local.env`. Compares
   resulting `.build-manifest.json` hashes (after normalization) to assert
   deterministic byte-identical builds.
3. **check-drift** — `scripts/check-drift.sh --manifest <fixture>` vs
   `scripts/check-drift.ps1 -Manifest <fixture>`.
4. **snapshot-builder** — `scripts/build-public-snapshot.sh` vs
   `scripts/build-public-snapshot.ps1`. Both are currently stubs; the
   parity test asserts symmetric exit codes (both non-zero with the same
   stub reference).

The bash side does the comparisons; the PS side preserves the assertion
count via mirrored `_Skip` calls (per
[[feedback_port_parity_vs_regression_split]]) — the PS lane on Windows has
no bash to compare against, so the cross-shell parity check is intrinsically
macOS/Linux-only.

When pwsh is absent on the bash lane, the bash side SKIPs the comparison
half of every assertion (preserving counts).

## Normalization rules

The detector compares OUTPUTS after applying these byte-level normalizations
(per the Codex v3 GAP):

1. **Line endings** — strip CR; LF-only. PS native output on Windows is CRLF;
   `tr -d '\r'` collapses to LF.
2. **Path separators** — `\` → `/`. Bash twin always emits forward slashes;
   PS twin on Windows emits backslash. The mask makes platform-divergent
   path-string content compare equal.
3. **Temp paths** — mask any path-shape under `/tmp/<rand>`, `/private/tmp/<rand>`,
   `/var/folders/<rand>` (BSD/GNU `mktemp` outputs) AND
   the Windows `%LOCALAPPDATA%\Temp\<rand>` shape (drive-letter prefix +
   AppData/Local/Temp or Windows/Temp) → `<TMP>`. The masking patterns are
   runtime-constructed from non-trip halves in the test source so this README
   + the test file itself do NOT self-trip check-drift's machine-path scan
   (per [[feedback_self_tripping_test_source]] extension — sanitize
   comments + identifiers, not just data literals).
4. **Output classes** — sort `PASS / FAIL / NOTE / INFO / SKIP` lines and
   `uniq` them before comparing. The detector compares CLASSES as SETS, not
   sequences, so message-body differences (e.g. path quoting that legitimately
   differs by shell) don't trip parity.

## Comparison granularity

| Surface | Exit codes | Output classes | Manifest hash | Test counts |
|---|---|---|---|---|
| validate           | exact | sorted set       | n/a   | n/a   |
| install --build-only | exact | sorted set     | exact | n/a   |
| check-drift        | exact | sorted set       | n/a   | n/a   |
| snapshot-builder   | exact | (stub: skipped)  | n/a   | n/a   |

Exact = byte-identical after normalization. Sorted set = both sides produce
the same multiset of PASS/FAIL/NOTE class lines.

## When a parity check fails

1. Inspect both raw outputs side-by-side: `diff <(_normalize bash.out) <(_normalize ps.out)`.
2. Identify whether the divergence is platform-legitimate (e.g. macOS-specific
   `find` output) or a PS-port bug (e.g. silent encoding mismatch per
   [[feedback_powershell_set_content_crlf]] or trap #15 in [[reference_ps_port_traps]]).
3. Platform-legitimate → add an entry to the normalization rule set above and
   propagate to both `_normalize` and `_sort_classes` helpers.
4. PS-port bug → file a `feedback_*` memory + fix the PS port; the parity
   test is the regression guard.

## Adding a new pair-test surface

When porting a new `scripts/<x>.sh` to a PS twin, add a 4-step block to
`tests/parity.test.sh`:

```bash
if [ -f "$REPO_ROOT/scripts/<x>.sh" ] && [ -f "$REPO_ROOT/scripts/<x>.ps1" ]; then
  fix_dir="$PARITY_TMP/<x>-fix"
  mkdir -p "$fix_dir"
  # ... build fixture ...

  bash_out="$PARITY_TMP/<x>-bash.out"
  bash "$REPO_ROOT/scripts/<x>.sh" --flag "$fix_dir" > "$bash_out" 2>&1
  bash_rc=$?

  if [ "$_have_pwsh" -eq 1 ]; then
    ps_out="$PARITY_TMP/<x>-ps.out"
    pwsh -NoProfile -File "$REPO_ROOT/scripts/<x>.ps1" -Flag "$fix_dir" > "$ps_out" 2>&1
    ps_rc=$?
    assert_eq "<x> parity: exit codes match"   "$bash_rc" "$ps_rc"
    assert_eq "<x> parity: output classes match" \
      "$(_normalize "$bash_out" | _sort_classes)" \
      "$(_normalize "$ps_out"   | _sort_classes)"
  else
    _skip "<x> parity: exit codes match"   "pwsh not installed"
    _skip "<x> parity: output classes match" "pwsh not installed"
  fi
fi
```

Then mirror the assertion labels in `tests/parity.test.ps1` as `_Skip`
entries with rationale per [[feedback_port_parity_vs_regression_split]].
