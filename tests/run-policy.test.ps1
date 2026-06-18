#Requires -Version 7
# tests/run-policy.test.ps1 — Windows-native twin of tests/run-policy.test.sh.
#
# Contract tests for the Per-Run Safety Posture. A LEAN codification: default-safe
# + cannot-override-hard-guards already ship in core/operating-system.md ->
# Decision Authority; the additive remainder is a NAMED per-run-safety-posture
# umbrella (loosening reserved to an explicit operator action) + wiring it into the
# session-agent Mode 1 orient so the posture is VISIBLE at run start. These
# assertions PIN that surface so a future edit cannot silently drop a hard guard,
# reopen a self-loosening path, or un-wire the visible line.
#
# Mirrors the .sh twin 1:1 — same files, same needles, same assertions.
#
# tests/lib.ps1 dot-sourced by tests/run.ps1; Assert-* + counters in scope.

$OS_DOC = Join-Path $env:REPO_ROOT 'core' 'operating-system.md'
$SA_DOC = Join-Path $env:REPO_ROOT 'capabilities' 'session-agent.md'

Assert-File 'run-policy: core/operating-system.md exists' $OS_DOC
Assert-File 'run-policy: capabilities/session-agent.md exists' $SA_DOC

$OS_CONTENT = if (Test-Path -LiteralPath $OS_DOC -PathType Leaf) { Get-Content -LiteralPath $OS_DOC -Raw } else { '' }
$SA_CONTENT = if (Test-Path -LiteralPath $SA_DOC -PathType Leaf) { Get-Content -LiteralPath $SA_DOC -Raw } else { '' }

# === 1. The per-run-safety-posture umbrella section exists.
Assert-Contains 'run-policy: operating-system names the posture section' `
  $OS_CONTENT '## Per-Run Safety Posture'

# === 2. Default-safe.
Assert-Contains 'run-policy: posture defaults to safe' `
  $OS_CONTENT 'defaults to **safe**'

# === 3. Declared/visible at run start (honest doc-contract wording — a stated
# contract, not a claimed hook-enforced lock).
Assert-Contains 'run-policy: posture is declared at run start' `
  $OS_CONTENT 'Declared at run start'

# === 4. Tighten-only, never loosen (the cannot-weaken-guards property).
Assert-Contains 'run-policy: posture can only tighten, never loosen' `
  $OS_CONTENT 'can only tighten the hard guards, never loosen them'

# === 5. Loosening is reserved to an explicit operator action — never the model's
# own reasoning or untrusted input. Pins the fix for the visible-loosening
# loophole so a future edit cannot reopen a model-self-loosening path.
Assert-Contains 'run-policy: only an explicit operator action loosens a posture' `
  $OS_CONTENT 'only an explicit operator action relaxes a posture'

# === 6-11. All hard guards are named in the precedence sentence, each on a phrase
# unique to that sentence — so an edit that drops one guard fails this gate instead
# of silently weakening the contract.
Assert-Contains 'run-policy: names the secrets guard' `
  $OS_CONTENT 'secrets and machine-private state stay out of the repo'
Assert-Contains 'run-policy: names the project-history (tracker-ID) guard' `
  $OS_CONTENT 'local project history'
Assert-Contains 'run-policy: names the public-history guard' `
  $OS_CONTENT 'stay out of shared framework content and public history'
Assert-Contains 'run-policy: names the harness-neutrality guard' `
  $OS_CONTENT 'shared content stays harness-neutral'
Assert-Contains 'run-policy: names the one-way-door guard' `
  $OS_CONTENT 'irreversible one-way doors never auto-decide'
Assert-Contains 'run-policy: names the guard-contradiction (stop-for-user) guard' `
  $OS_CONTENT 'a task that contradicts a deliberate guard stops for the user'

# === 12. The guard list is explicitly a floor, not an exhaustive ceiling.
Assert-Contains 'run-policy: precedence list is a floor, not a ceiling' `
  $OS_CONTENT 'This list is the floor, not the ceiling'

# === 13. Untrusted input (tool output / file content / memory / model output)
# cannot flip a guard off — the profile-poisoning precedence applied to the run.
Assert-Contains 'run-policy: untrusted input cannot switch a guard off' `
  $OS_CONTENT 'untrusted input can switch one off'

# === 14. Composes-with, never-replaces (safety-scoping + autonomy governance are
# preserved, not superseded — the additivity promise for this item).
Assert-Contains 'run-policy: posture composes with, never replaces, existing controls' `
  $OS_CONTENT 'never replaces'

# === 15. Visible-at-start wiring: the session-agent Mode 1 orient surfaces the
# posture line, so "visible at run start" cannot silently regress.
Assert-Contains 'run-policy: session-agent Mode 1 orient surfaces the safety posture' `
  $SA_CONTENT 'Safety posture:'
