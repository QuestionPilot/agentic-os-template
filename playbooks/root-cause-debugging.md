# Root-Cause Debugging

Use this playbook whenever a fix is in scope: a failing test, a runtime error, a regression, a flaky check, or any reported defect. It is the upstream discipline for fixing things correctly the first time. The escalation rule in `core/routing.md` ("the same failure repeats") is the downstream rescue when this discipline stalls.

## Iron Law

No fix without a demonstrated root cause.

Before editing any file, trace the data flow from symptom back to cause and state a written hypothesis: what the broken value is, where it originates, and why the current code produces it. A patch that suppresses the symptom without naming the cause is not a fix — it is a new bug with a delay.

## Steps

1. Reproduce the failure deterministically. Capture the exact command, input, and observed-versus-expected output.
2. Trace the data flow backward from the symptom to the earliest point where state goes wrong.
3. State a single root-cause hypothesis in writing before touching code.
4. Confirm the hypothesis against the actual code or runtime state — not against memory or assumption.
5. Apply the smallest fix that addresses the named cause.
6. Re-run the reproduction. Confirm it now passes and that nothing adjacent broke.

## Scope Lock

Run two phases. During investigation, stay read-only except for probes, logging, and tests — no production edits while the cause is still a hypothesis. Once the cause is confirmed, write only the files named in the confirmed hypothesis; widen scope only when fresh evidence forces it. This keeps the search disciplined and the diff attributable. When a session-safety scope-freeze guardrail is installed (a freeze / guard capability), use it to enforce the lock mechanically rather than by intention alone.

## Three-Strike Stop

Count fix attempts. After three failed attempts at the same failure, stop. Do not keep editing.

A failed attempt is any code change that does not make the reproduction pass — including a change that merely shifts the failure to a different symptom. A clean revert back to a known state is not itself a strike. Three failed attempts means the working hypothesis is wrong, not that the next edit is closer. The three-strike rule is the hard ceiling on solo iteration; the existing escalation rule may fire sooner — the repeated-failure rescue in `core/routing.md` already triggers independent or another model's review once the same failure recurs, which can be before the third strike. At the stop point, escalate per `core/routing.md` and bring in that independent perspective (cross-model review as the rescue path) with a compact packet: the reproduction, the hypotheses already falsified, and the data flow traced so far. Thrashing past the third attempt burns context and buries the real cause deeper.

## Regression Test

Every fix ships with a test that would have caught the bug. Write the test so it fails against the unfixed code and passes against the fix. If an automated test is genuinely impossible for this surface, name the manual guard that replaces it and state why automation is not feasible — silence is not an option. A fix without a guarding test leaves the defect free to return silently.

## Closeout

State the demonstrated root cause, the reproduction used, the attempt count, the regression test added, and whether the fix was confirmed against the live failure or only reasoned about. If the three-strike stop fired, name the escalation taken and its outcome.
