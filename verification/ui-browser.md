# UI And Browser Verification

Use for frontend, rendered UI, visual quality, accessibility, or interaction changes.

## Target Identity First

Before any screenshot, recording, or rendered-state check counts as evidence, prove the check reached the intended build — whether that build is a local process, a static export, a preview deployment, or a remote environment:

- Assert the browser target (host and port, or deployment URL) actually serves the build under test, not whatever else holds the port or a stale deployment. A dead dev server plus an occupied port can return a clean `200` for a site that was never built.
- Confirm a build identity marker: a version string, commit hash, build timestamp, or one asset known to exist only in the change under test.
- If the target-identity assertion fails or was skipped, every downstream screenshot is unverified output, not proof.

## Proof

- Inspect rendered desktop and mobile states.
- Check text fit, spacing, hierarchy, overflow, and interaction states.
- Run accessibility checks when relevant.
- Check console errors and failed requests when running a browser flow.
- Use screenshots or videos when visual quality is a material requirement.

## Emulation Is Not Device Proof

A resized viewport or emulated user agent proves layout at that size; it does not prove behavior on a physical device. Touch input, media autoplay, scroll physics, and performance can all differ on real hardware. A green emulated run must state that it did not cover a physical device, and name device coverage as residual risk when mobile behavior is material.

## Closeout

State the target-identity assertion result, viewport coverage, whether coverage was emulated or on-device, browser checks, accessibility result, and residual visual risk.
