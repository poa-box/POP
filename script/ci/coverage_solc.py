#!/usr/bin/env python3
"""Coverage-only adapter for Forge's unsupported unoptimized-viaIR combination.

Set POA_COVERAGE_SOLC to the already installed, pinned Solc 0.8.33 executable.
Every compiler setting except optimizer is retained, including source contents,
viaIR, output selection, library linking, EVM version and metadata options.
The optimizer object matches this repository's passing default-profile artifacts.
"""

import json
import os
import subprocess
import sys


def compiler_input(raw):
    payload = json.loads(raw)
    if not isinstance(payload, dict) or payload.get("language") != "Solidity":
        raise ValueError("coverage adapter requires Solidity standard JSON")
    settings = payload.get("settings", {})
    if not isinstance(settings, dict) or settings.get("viaIR") is not True:
        raise ValueError("coverage adapter requires forge coverage --ir-minimum")
    settings["optimizer"] = {"enabled": False, "runs": 200}
    return json.dumps(payload).encode()


def run(args, raw=None):
    if args != ["--version"] and "--standard-json" not in args:
        raise ValueError("coverage adapter only supports --version or --standard-json")
    executable = os.environ.get("POA_COVERAGE_SOLC")
    if not executable:
        raise ValueError("POA_COVERAGE_SOLC must point to the pinned Solc 0.8.33 executable")
    version = subprocess.run([executable, "--version"], stdout=subprocess.PIPE, check=False)
    if version.returncode:
        return version.returncode
    if b"Version: 0.8.33+commit.64118f21" not in version.stdout:
        raise ValueError("coverage adapter requires Solc 0.8.33+commit.64118f21")
    if "--standard-json" in args:
        raw = sys.stdin.buffer.read() if raw is None else raw
        return subprocess.run([executable, *args], input=compiler_input(raw), check=False).returncode
    return subprocess.run([executable, *args], check=False).returncode


if __name__ == "__main__":
    try:
        sys.exit(run(sys.argv[1:]))
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"coverage compiler adapter: {error}", file=sys.stderr)
        sys.exit(1)
