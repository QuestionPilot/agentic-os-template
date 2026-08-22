# Script and Guard Authoring

Use this playbook when writing or changing any script that other work depends on: a verification gate, a scanner, a drift or hygiene checker, a hook, or a build step. These scripts are trusted by everything downstream, so a defect in one does not announce itself — it prints `PASS` and hides the problem it was written to catch. The rules below are the failure modes that have actually shipped, each stated with the reason it binds.

## Portability

Write for the least capable shell and text tools your operators will actually run, not for the ones on your machine.

- **Do not assume a command exists because your platform has it.** Not every platform ships GNU coreutils — macOS, for one, has no `timeout` binary. The rule is: a script that needs a bounded run must *detect* an available implementation (`timeout`, a vendor-prefixed variant such as `gtimeout`, a language-runtime alarm wrapper) or bound the work another way (a poll loop with a deadline, a background job plus a wait cap), and it must degrade with a clear message rather than dying on `command not found`. Prescribing one binary just moves the breakage to a different platform.
- **Target Bash 3.2.** Some platforms still ship it as `/bin/bash`. No associative arrays (`declare -A`), no `mapfile`/`readarray`, no `${var^^}`. Use parallel indexed arrays, `while read` loops, and `tr` instead. A script that only runs on the newest shell is a script that fails on half the machines that clone the repo.
- **Pin `LC_ALL=C` wherever correctness depends on byte semantics.** BSD `awk`, `sort`, and `tr` change behavior with the caller's locale: collation order, character-class membership, and multi-byte handling all shift under a UTF-8 locale. A guard that passes in one locale and silently mis-parses in another is a false CLEAN, and green in your locale proves only your locale. Locale-sensitive guards must **force** a locale rather than inherit one — set it explicitly in the script and, where the result is load-bearing, assert that the forced setting actually took effect.
- **Use portable invocations.** Prefer POSIX flags, avoid GNU-only options (`sed -i` without an argument, `grep -P`, `readlink -f`), and quote every path — a space in a directory name has broken more checkers than any logic bug.

## Guard and Scanner Design

A guard exists to fail. Every design choice should make failure louder and success harder to counterfeit.

- **Fail loud, never open.** A guard that hits an unexpected condition — missing input, an unparsable file, a tool that is not installed — must exit non-zero with a message naming what went wrong. Printing `PASS` on an internal error converts a broken checker into a silent permanent green, which is worse than having no checker at all. Reserve fail-open for genuinely advisory surfaces, and say so in the script header.
- **Print the denominator.** Every checker must report how many items it actually compared, not just its verdict. A path-parsing bug once let a checker compare one of three roots and still print `PASS`; the count would have exposed it instantly. Make the number part of the normal output so a drop is visible in a diff of logs.
- **Presence is not content.** `test -f`, a row count, and set-equality of filenames all prove that something exists — they prove nothing about what is inside it. When the claim is parity or correctness, hash or diff the bytes, and allowlist deliberate variants explicitly so the allowlist is reviewable.
- **Bias toward under-reporting.** A scanner that infers intent from prose or structure will produce false positives, and a noisy scanner gets ignored, which is the same as being deleted. Run the first cut against the real corpus before writing tests, then pin each false positive as a restraint fixture so future changes cannot re-introduce it. Under-reporting costs you a missed finding; over-reporting costs you the whole guard.
- **Prove the guard with two controls.** A positive control — a planted defect the guard must catch — proves it can detect anything at all. A negative control — known-clean input that must pass — proves it is not just failing everything. A guard shipped with neither is an untested assertion; a guard with only the negative control cannot be distinguished from a guard that does nothing.
- **An empty scan set is a SKIP or an error, never a PASS.** Zero files matched almost always means the glob, path, or filter is wrong, not that the repository is clean. Report the skip explicitly so the gap is visible.

## Gate Placement

The same rule is often enforced at several positions: a directive at session start, a hook before the action, a gate before publish, and a check in CI. Layering is correct, but only if each layer is placed where it can see what it gates on.

- **Place each layer where the signal exists.** A pre-action hook can see the action about to happen but not the final diff; a pre-publish gate can see the whole tree but not intent; CI can see the merge result but not local-only state. Putting a check at a position where its input is not yet available produces a layer that always passes.
- **A later layer is a safety net, not a replacement.** The earlier layer exists to make the failure cheap; the later one exists to make it impossible. Removing the earlier layer because "CI catches it anyway" trades a one-second correction for a full round trip, and CI cannot catch what never leaves the machine.
- **Document every layer's kill switch.** Each hook or gate needs a named, discoverable way to disable it, and that switch belongs in the documentation next to the gate. Undocumented switches get discovered by the person debugging at the worst moment; missing switches get worked around by disabling something larger.
- **The mechanism is not the rule.** Automation covers the cases it can see. Where the rule binds but no check exists — judgment calls, prose quality, whether a change is in scope — the rule still binds. Never treat "the gate passed" as evidence that the rule was followed.

## Counts and Reported Numbers

- **Re-derive every count at report time.** Any number in a report, summary, comment, or commit message must be recomputed from the source at the moment of reporting. A count carried forward from earlier in the session describes a state that no longer exists; the work done in between is exactly what changed it. This applies to file counts, failure counts, item tallies, and anything derived from them.
- **A fail-fast run gives a lower bound, not a total.** A gate that stops on the first failure has shown you one failure and nothing about the rest. Scope estimated from a single red run is a floor. Loop fix and re-run until the gate exits zero before quoting how much was wrong.
- **Never gate on a piped exit code.** `cmd | tail` exits with the status of `tail`, so a zero there proves the last stage of the pipe ran, not that the command passed. Set `pipefail`, inspect `PIPESTATUS`, or parse the run's own PASS/FAIL lines. Capture full output when diagnosing — trimming to the tail keeps the verdict and discards the diagnosis.

## Where the Repository Demonstrates This

`scripts/validate.sh` is the fast local gate; `scripts/check-drift.sh` is the manifest-based parity check across rendered outputs; `scripts/check-clean.sh` is the pre-publish boundary gate. Each `scripts/*.sh` script has a `.ps1` twin, and behavior changes must be mirrored into both plus their test twins under `tests/` — a change to one side only is a guard that holds on one platform. (Vault-scaffolding `bin/` tooling is bash + node by scope; where a script has no twin, say so in its header rather than implying one.)

## Closeout

State what the script or guard checks, the positive and negative controls that prove it works, the denominator it prints, the locale and shell assumptions it pins, its kill switch, and whether the platform twin and its tests were updated alongside it.
