# Audit Systems

Use this when a repeated class of work needs mechanical accuracy checks beyond normal review.

## When To Create An Audit

- The same mistake or stale-state risk can recur.
- A completion claim depends on many small files, links, settings, or tool versions.
- A manual checklist is important but easy to skip or apply inconsistently.
- The check can run without secrets and without destructive side effects.

## What Good Audits Check

- Required files, folders, indexes, or configuration exist.
- Links, references, or machine-readable files parse.
- Secrets and disposable artifacts are absent.
- The right source of truth owns the information.
- Tool availability or version freshness is visible when relevant.
- Child checks summarize warnings and failures clearly.

## Generic Example

```bash
#!/usr/bin/env bash
set -u

PASS=0
WARN=0
FAIL=0

pass() { printf 'PASS %s\n' "$1"; PASS=$((PASS + 1)); }
warn() { printf 'WARN %s\n' "$1"; WARN=$((WARN + 1)); }
fail() { printf 'FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

check_file() {
  [ -f "$1" ] && pass "file exists: $1" || fail "missing file: $1"
}

check_cmd() {
  command -v "$1" >/dev/null 2>&1 && pass "command available: $1" || warn "command missing: $1"
}

check_file README.md
check_file AGENTS.md
check_cmd rg
check_cmd node

if rg -n --hidden --glob '!.git/**' 'sk-[A-Za-z0-9_-]{20,}|-----BEGIN .*PRIVATE KEY-----' .; then
  fail "likely secret pattern found"
else
  pass "secret pattern scan clean"
fi

printf '\nSummary: %s pass, %s warn, %s fail\n' "$PASS" "$WARN" "$FAIL"
[ "$FAIL" -eq 0 ]
```

## Design Rules

- Keep audits read-only unless the user explicitly approves repair behavior.
- Make output boring and grep-friendly: `PASS`, `WARN`, `FAIL`, then a summary.
- Warnings should require adjudication but not always block completion.
- Do not hide failed child checks behind a green parent result.
- Prefer project-local audits for project behavior and framework-level audits for operating-system health.

## Closeout

State the audit command, result summary, unresolved warnings, and whether a stronger manual or browser check was still needed.
