# Makefile — agentic-os-template verification + render aggregator.
#
# One verb for the framework verification surface. `make verify` runs the same
# three gates a future-AI or future-operator will run when they pick up the
# change — fails fast on first non-zero exit.
#
# POSIX-portable: .PHONY targets, plain TAB recipes, $$ to escape $ in shell.
# Tested under both BSD make (macOS default) and GNU make (Linux dev boxes).

.PHONY: verify test test-fast validate drift render help

# Default target — read-only verification gate (pre-push, pre-PR).
# Sequential recipe form: under `make -j` (parallel), prerequisite-list form
# (`verify: test validate drift`) would schedule the three jobs concurrently
# and lose fail-fast ordering. Calling sub-make sequentially enforces
# test → validate → drift order even under `-j`.
verify:
	@$(MAKE) test
	@$(MAKE) validate
	@$(MAKE) drift

# Acceptance test suite (full tier — every test file; the pre-push gate).
# Presence-guarded: the suite ships with the framework, but a partial checkout
# or a pre-suite snapshot may lack tests/run.sh. When it is absent, this target
# reports that and exits 0 so `make verify` degrades to validate + drift instead
# of hard-failing "No such file".
test:
	@if [ -f tests/run.sh ]; then bash tests/run.sh; else echo 'make test: tests/run.sh not present in this checkout; skipping'; fi

# Fast inner-loop tier — skips slow-marked (clone/build-heavy) tests for a quick
# edit→test cycle. NOT a substitute for `make verify`; run the full suite before
# pushing. Same presence-guard as `make test`.
test-fast:
	@if [ -f tests/run.sh ]; then TEST_TIER=fast bash tests/run.sh; else echo 'make test-fast: tests/run.sh not present in this checkout; skipping'; fi

# Static repo validation (drift, link, lifecycle, allowlist).
validate:
	bash scripts/validate.sh

# Manifest-based drift check against EVERY rendered harness home — claude
# ($$CLAUDE_CONFIG_DIR), codex ($$CODEX_HOME), hermes ($$HERMES_HOME), cursor
# ($$CURSOR_CONFIG_DIR) — via
# check-drift.sh --auto (env var first, then local.env read as data). The old
# recipe checked only $$CLAUDE_CONFIG_DIR while the codex entrypoint promised
# $$CODEX_HOME coverage. Fresh-clone-safe: a home that is unset or has no
# rendered manifest is skipped with a notice and the target still exits 0.
drift:
	@bash scripts/check-drift.sh --auto

# Re-render harness entrypoints from templates (writes into $CLAUDE_CONFIG_DIR).
# Not a verify prerequisite — render is an explicit operator action because it
# writes into the rendered-output boundary.
render:
	bash scripts/install.sh

# Show available targets.
help:
	@printf 'Targets:\n'
	@printf '  verify   - run test + validate + drift (default; read-only)\n'
	@printf '  test     - run acceptance suite (full tier) when present\n'
	@printf '  test-fast- run only fast-tier tests (skips clone/build-heavy; inner loop)\n'
	@printf '  validate - run repo validation (scripts/validate.sh)\n'
	@printf '  drift    - run drift gate against every rendered harness home (claude/codex/hermes/cursor; $$CLAUDE_CONFIG_DIR et al.)\n'
	@printf '  render   - re-render harness entrypoints (writes to $$CLAUDE_CONFIG_DIR)\n'
