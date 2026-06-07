# Tool Freshness Verification

Use when tools, CLIs, SDKs, plugins, or agent capabilities may be stale or were changed.

## Proof

- Compare installed version against the current source for that tool.
- Avoid blind reinstalling before understanding the current state.
- Run a harmless non-interactive smoke test.
- Confirm instruction files do not name stale versions.
- Keep credentials and auth state out of shared docs.
- Treat a successful version command as insufficient on its own when the tool is used for real work.
- Prefer automated checks where practical, but keep freshness checks optional and explicit so ordinary repo validation stays fast.

## Closeout

State installed version, current source checked, smoke result, instruction drift result, and remaining setup gaps.
