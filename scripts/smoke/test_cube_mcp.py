#!/usr/bin/env python3
"""Minimal black-box checks for the OAuth-protected Cube MCP gateway."""
from __future__ import annotations

import os
import sys

import httpx

URL = os.environ.get("CUBE_MCP_URL", "http://localhost:8003/mcp")


def main() -> int:
    checks: list[tuple[str, bool, str]] = []
    with httpx.Client(timeout=20) as client:
        unauthenticated = client.get(URL)
        checks.append(("MCP endpoint rejects an anonymous request", unauthenticated.status_code == 401,
                       f"HTTP {unauthenticated.status_code}"))
        forged = client.get(URL, headers={"Authorization": "Bearer not-a-jwt"})
        checks.append(("MCP endpoint rejects a forged token", forged.status_code == 401,
                       f"HTTP {forged.status_code}"))
    for name, ok, detail in checks:
        print(("PASS" if ok else "FAIL") + f"  {name} ({detail})")
    failures = sum(not ok for _, ok, _ in checks)
    print(f"{len(checks) - failures} passed, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
