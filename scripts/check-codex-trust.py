#!/usr/bin/env python3
"""Read and report Codex project trust rows without exposing config values."""

from __future__ import annotations

import argparse
import json
import os
import sys

try:
    import tomllib
except ModuleNotFoundError:
    print("FAIL check-codex-trust: Python 3.11+ with tomllib is required", file=sys.stderr)
    raise SystemExit(2)


def fail(message: str) -> None:
    print(f"FAIL check-codex-trust: {message}", file=sys.stderr)
    raise SystemExit(2)


def main() -> None:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--config", metavar="PATH")
    parser.add_argument("--help", action="store_true")
    args, extra = parser.parse_known_args()
    if args.help:
        print("usage: check-codex-trust [--config PATH]")
        return
    if extra:
        fail("unexpected argument")

    config_path = args.config
    if config_path is None:
        codex_home = os.environ.get("CODEX_HOME")
        if not codex_home:
            fail("CODEX_HOME is unset; pass --config for an explicit file")
        config_path = os.path.join(codex_home, "config.toml")

    try:
        with open(config_path, "rb") as config_file:
            config = tomllib.load(config_file)
    except FileNotFoundError:
        fail("config.toml is unavailable")
    except OSError as error:
        fail(f"cannot read config.toml: {error.strerror or error.__class__.__name__}")
    except tomllib.TOMLDecodeError:
        fail("config.toml is malformed")

    projects = config.get("projects", {})
    if not isinstance(projects, dict):
        fail("[projects] is not a table")

    trusted_paths: list[str] = []
    for path, project in projects.items():
        if not isinstance(path, str) or not isinstance(project, dict):
            fail("[projects] contains an unsupported entry")
        trust_level = project.get("trust_level")
        if trust_level is not None and trust_level not in ("trusted", "untrusted"):
            fail("[projects] contains an unsupported trust_level")
        if trust_level == "trusted":
            trusted_paths.append(path)

    trusted_paths.sort()
    print(f"trusted project rows: {len(trusted_paths)}")
    for path in trusted_paths:
        # JSON strings keep a control character inside a path from changing the
        # output shape. This reports only the key, never sibling config values.
        print(f"path: {json.dumps(path, ensure_ascii=True)}")


if __name__ == "__main__":
    main()
