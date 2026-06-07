# Test tiers — fast inner loop vs full pre-push suite

The acceptance suite (`tests/run.sh` / `tests/run.ps1`) supports two tiers so the
edit→test inner loop stays fast without weakening the pre-push gate. Introduced
to cut the clone/build-fixture feedback-loop cost.

## The two tiers

| Tier | What runs | When to use |
| --- | --- | --- |
| **full** (default) | every `tests/*.test.{sh,ps1}` file | pre-push, pre-PR, CI, and `make verify`. The authoritative gate — never skip it before pushing. |
| **fast** | every file **except** those marked `slow` | the local inner loop while iterating. Skips the clone/build-heavy files that dominate wall-clock. |

The runner picks the tier from the `TEST_TIER` environment variable; unset (or
any value other than `fast`) means **full**, so existing callers — CI, `make
verify`, a bare `bash tests/run.sh` — are unaffected.

## Running each tier

```bash
make test          # full tier (same as `make verify`'s test gate)
make test-fast     # fast tier — skips slow-marked files

# Equivalent direct invocations:
bash tests/run.sh                 # full
TEST_TIER=fast bash tests/run.sh  # fast
```

```powershell
pwsh tests/run.ps1                            # full
$env:TEST_TIER='fast'; pwsh tests/run.ps1     # fast
```

`make test-fast` is a convenience, **not** a substitute for `make verify`. Run
the full suite before opening a PR.

## How a test opts into the slow tier

Add a marker comment line — on its own line, at column 0 — anywhere in the file:

```
# test-tier: slow
```

Files without the marker are **fast** (run in every tier). The detector
(`_test_tier_of` in `tests/lib.sh`, `Get-TestTier` in `tests/lib.ps1`) anchors
the match to the start of the line (`^#`) and matches case-sensitively, so a
reference to the marker string inside a test body — quoted, indented, or in a
heredoc — does **not** misclassify that file. Keep the marker as a clean line
with nothing after `slow`.

## Current slow set

These are the heaviest files by wall-clock — each repeatedly drives the snapshot
builder, the whole-repo validator, or the installer over fixtures, and adds
little to a quick correctness inner loop. Times below are per-file, measured on
the baseline:

| File | ~time | Why slow |
| --- | --- | --- |
| `tests/links.test.sh` | ~61s | runs the full `scripts/validate.sh` (whole-repo markdown link scan) once per staged-fixture assertion (~30×) |
| `tests/bootstrap.test.sh` | ~30s | runs `bootstrap.sh` / `install.sh` ~28× across fresh-clone + re-render cases |

A bare `--shared` clone of this repo is ~0.1s (objects are shared, not copied),
so the cost is the **builder / validator / installer work after** each clone, not
the clone itself — confirming the scrubber speedup and the `--shared`
clone change already removed the clone overhead the original audit (C2) flagged.
The remaining cost is inherent end-to-end work, so these tests are *tiered out*
of the inner loop rather than rewritten; the full tier (and CI) always runs them.

## Measured

The fast tier is the inner-loop target (well under 5 min). The slow files — the
whole-repo validator (`links.test`) and the installer/bootstrap path
(`bootstrap.test`) — dominate full-suite wall-clock, so tiering them out keeps
the inner loop quick while the full tier (CI + `make verify`) keeps total
coverage.

Each file's `.ps1` twin carries the same marker, so the pwsh runner skips it in
the fast tier too — the slow set is per-stem, not per-shell.

## Adding a new slow test

1. Add the `# test-tier: slow` marker line to **both twins** (`.sh` and `.ps1`)
   so the file is skipped under both runners (see above).
2. Add the stem to the marker-presence guard in `tests/tiers.test.sh` and
   `tests/tiers.test.ps1` (the loop checks both twins of each stem) so the
   marker can't silently drift off one side and quietly slow the loop back down.
3. Note it in the **Current slow set** table above.

## What still runs in the fast tier

Everything else — the compiler, install/render, drift, links, lifecycle,
hooks, closeout, spine-capability, and parity tests. The fast tier is a broad
correctness sweep; it omits only the snapshot/publish build-heavy paths, which
the full tier (and CI) always covers.
