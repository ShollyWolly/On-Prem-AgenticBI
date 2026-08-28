"""Authenticated Cube MCP gateway."""
from __future__ import annotations

import os
import time
from collections.abc import Mapping
from typing import Any

import httpx
import jwt
from fastmcp import FastMCP
from fastmcp.server.auth import RemoteAuthProvider, require_scopes
from fastmcp.server.auth.providers.jwt import JWTVerifier
from fastmcp.server.dependencies import get_access_token
from pydantic import AnyHttpUrl

DENIED = "denied"
ALLOWED_QUERY_KEYS = {
    "measures", "dimensions", "filters", "timeDimensions", "segments",
    "order", "limit", "offset", "timezone", "total", "ungrouped",
    "renewQuery", "responseFormat",
}
CUBE_BASE_URL = os.environ.get("CUBE_API_URL", "http://cube:4000/cubejs-api/v1")
CUBE_SECRET = os.environ["CUBEJS_API_SECRET"]
AUTHENTIK_ISSUER = os.environ["AUTHENTIK_CUBE_ISSUER"]
AUTHENTIK_JWKS = os.environ["AUTHENTIK_CUBE_JWKS_URL"]
MCP_PUBLIC_URL = os.environ["CUBE_MCP_PUBLIC_URL"]


def identity_from_token() -> dict[str, Any]:
    """Return a canonical, fail-closed Cube security context."""
    token = get_access_token()
    claims = token.claims if token else {}
    subject = str(claims.get("sub") or "").strip()
    email = str(claims.get("email") or "").strip().lower()
    groups = claims.get("groups")
    if not subject or not email or not isinstance(groups, list):
        raise ValueError("Authenticated token is missing a required identity claim")

    group_names = {str(group).strip().lower() for group in groups}
    mapped = []
    if "analysts" in group_names:
        mapped.append("analyst")
    if "admins" in group_names:
        mapped.append("admin")
    if len(mapped) != 1:
        raise PermissionError("No unambiguous Cube role is assigned to this user")
    return {"user": email, "subject": subject, "role": mapped[0], "groups": mapped}


def cube_token(identity: Mapping[str, Any]) -> str:
    now = int(time.time())
    return jwt.encode(
        {"iat": now, "exp": now + 60, "securityContext": dict(identity)},
        CUBE_SECRET,
        algorithm="HS256",
    )


def validate_query(query: Mapping[str, Any]) -> dict[str, Any]:
    if not isinstance(query, Mapping) or not query:
        raise ValueError("query must be a non-empty Cube REST query object")
    unknown = set(query) - ALLOWED_QUERY_KEYS
    if unknown:
        raise ValueError(f"unsupported Cube query fields: {', '.join(sorted(unknown))}")
    if "sql" in query or "query" in query:
        raise ValueError("raw SQL is not supported by this gateway")
    for field in ("measures", "dimensions", "segments"):
        if field in query and not isinstance(query[field], list):
            raise ValueError(f"{field} must be an array")
    if "limit" in query and (not isinstance(query["limit"], int) or not 1 <= query["limit"] <= 1000):
        raise ValueError("limit must be an integer from 1 through 1000")
    if "offset" in query and (not isinstance(query["offset"], int) or query["offset"] < 0):
        raise ValueError("offset must be a non-negative integer")
    return dict(query)


async def cube_request(method: str, path: str, identity: Mapping[str, Any], **kwargs: Any) -> dict[str, Any]:
    headers = {"Authorization": f"Bearer {cube_token(identity)}"}
    async with httpx.AsyncClient(timeout=45) as client:
        response = await client.request(method, f"{CUBE_BASE_URL}{path}", headers=headers, **kwargs)
    if response.status_code >= 400:
        raise RuntimeError(f"Cube returned HTTP {response.status_code}: {response.text[:500]}")
    return response.json()


token_verifier = JWTVerifier(
    jwks_uri=AUTHENTIK_JWKS,
    issuer=AUTHENTIK_ISSUER,
    required_scopes=["cube.read"],
)
auth = RemoteAuthProvider(
    token_verifier=token_verifier,
    authorization_servers=[AnyHttpUrl(AUTHENTIK_ISSUER)],
    base_url=MCP_PUBLIC_URL,
)
mcp = FastMCP("Cube Semantic Layer", auth=auth)


@mcp.tool(auth=require_scopes("cube.read"))
async def get_schema() -> dict[str, Any]:
    """List views, dimensions, measures, and segments allowed to the caller."""
    return await cube_request("GET", "/meta", identity_from_token())


@mcp.tool(auth=require_scopes("cube.read"))
async def query(query: dict[str, Any]) -> dict[str, Any]:
    """Run a governed Cube semantic query."""
    identity = identity_from_token()
    return await cube_request("POST", "/load", identity, json={"query": validate_query(query)})


@mcp.tool(auth=require_scopes("cube.read"))
async def whoami() -> dict[str, Any]:
    """Show the effective governed identity without revealing credentials."""
    return identity_from_token()


if __name__ == "__main__":
    mcp.run(transport="http", host="0.0.0.0", port=8000)
