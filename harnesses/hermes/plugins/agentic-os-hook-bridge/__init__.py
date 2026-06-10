"""agentic-os-hook-bridge — shell-hook registration bridge.

The desktop app's dashboard entrypoint (hermes_cli.web_server) never calls
agent.shell_hooks.register_from_config, so config.yaml shell hooks silently
do not fire in GUI sessions (verified empirically 2026-06-10, Hermes v0.16.0).
Hook DISPATCH is engine-level (plugin manager), so registering here from a
plugin -- which the desktop process does load -- restores parity.

Consent is unchanged: register_from_config still honors the
shell-hooks-allowlist; non-allowlisted hooks are skipped, never auto-approved
(accept_hooks=False).
"""
import logging

logger = logging.getLogger(__name__)


def register(ctx) -> None:
    try:
        from hermes_cli.config import load_config
        from agent.shell_hooks import register_from_config

        specs = register_from_config(load_config(), accept_hooks=False)
        logger.info(
            "agentic-os-hook-bridge: %d shell hook(s) registered", len(specs)
        )
    except Exception:
        logger.warning(
            "agentic-os-hook-bridge: shell-hook registration failed",
            exc_info=True,
        )
