"""OAuth-protected MCP gateway for Cube Semantic SQL."""
from __future__ import annotations

import os
import time
from datetime import date, datetime, time as clock_time
from decimal import Decimal
from typing import Any
from uuid import UUID

import asyncpg
import httpx
import jwt
import sqlglot
from fastmcp import FastMCP
from fastmcp.server.auth import RemoteAuthProvider, require_scopes
from fastmcp.server.auth.providers.jwt import JWTVerifier
from fastmcp.server.dependencies import get_access_token
from pydantic import AnyHttpUrl
from sqlglot import exp

DENIED = "denied"
SQL_HOST = os.environ.get("CUBE_SQL_HOST", "cube")
SQL_PORT = int(os.environ.get("CUBE_SQL_PORT", "15432"))
SQL_DATABASE = os.environ.get("CUBE_SQL_DATABASE", "cube")
SQL_PASSWORD = os.environ["CUBEJS_SQL_PASSWORD"]
CUBE_SECRET = os.environ["CUBEJS_API_SECRET"]
CUBE_API_URL = os.environ.get("CUBE_API_URL", "http://cube:4000/cubejs-api/v1")
AUTHENTIK_ISSUER = os.environ["AUTHENTIK_CUBE_ISSUER"]
AUTHENTIK_JWKS = os.environ["AUTHENTIK_CUBE_JWKS_URL"]
MCP_PUBLIC_URL = os.environ["CUBE_SQL_MCP_PUBLIC_URL"]


def identity_from_token() -> dict[str, Any]:
    """Return the fail-closed Cube security context from the OAuth token."""
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


def sql_password(identity: dict[str, Any]) -> str:
    """Create the short-lived Cube SQL password that carries the caller context."""
    now = int(time.time())
    return jwt.encode(
        {"iat": now, "exp": now + 60, "securityContext": identity},
        CUBE_SECRET,
        algorithm="HS256",
    )


async def connect(identity: dict[str, Any]) -> asyncpg.Connection:
    """Open a new Cube SQL session for one authenticated user."""
    return await asyncpg.connect(
        host=SQL_HOST,
        port=SQL_PORT,
        database=SQL_DATABASE,
        user=identity["user"],
        password=sql_password(identity),
        timeout=15,
        command_timeout=45,
        ssl=False,
    )


async def visible_views(connection: asyncpg.Connection) -> set[str]:
    """Return the public semantic views visible through the current Cube session."""
    records = await connection.fetch(
        "SELECT table_name FROM information_schema.tables "
        "WHERE table_schema = 'public' AND table_type IN ('BASE TABLE', 'VIEW')"
    )
    return {str(record["table_name"]).lower() for record in records}


async def cube_metadata(identity: dict[str, Any]) -> dict[str, Any]:
    """Fetch the caller-filtered Cube catalog used to describe SQL columns."""
    headers = {"Authorization": f"Bearer {sql_password(identity)}"}
    async with httpx.AsyncClient(timeout=45) as client:
        response = await client.get(f"{CUBE_API_URL}/meta", headers=headers)
    if response.status_code >= 400:
        raise RuntimeError(f"Cube metadata returned HTTP {response.status_code}: {response.text[:500]}")
    payload = response.json()
    if not isinstance(payload, dict):
        raise RuntimeError("Cube metadata response was not an object")
    return payload


def semantic_schema(
    views: set[str], records: list[asyncpg.Record], metadata: dict[str, Any]
) -> dict[str, Any]:
    """Attach public Cube descriptions to the SQL views and columns they describe."""
    cubes = metadata.get("cubes")
    raw_cubes = cubes if isinstance(cubes, list) else []
    catalog = {
        str(cube.get("name")).lower(): cube
        for cube in raw_cubes if isinstance(cube, dict)
        and str(cube.get("name") or "").lower() in views
    }
    columns: dict[str, list[dict[str, str]]] = {view: [] for view in sorted(views)}
    for record in records:
        view_name = str(record["table_name"]).lower()
        if view_name not in columns:
            continue
        column = {"name": str(record["column_name"]), "type": str(record["data_type"])}
        cube = catalog.get(view_name, {})
        for member_type in ("measures", "dimensions", "segments"):
            for member in cube.get(member_type, []):
                if str(member.get("name") or "").lower() != f"{view_name}.{column['name'].lower()}":
                    continue
                for field in ("title", "description"):
                    value = member.get(field)
                    if isinstance(value, str) and value.strip():
                        column[field] = value.strip()
                break
        columns[view_name].append(column)

    result = []
    for view_name in sorted(columns):
        cube = catalog.get(view_name, {})
        view = {"name": view_name, "columns": columns[view_name]}
        for field in ("title", "description"):
            value = cube.get(field)
            if isinstance(value, str) and value.strip():
                view[field] = value.strip()
        result.append(view)
    return {"views": result}


async def described_schema(identity: dict[str, Any]) -> dict[str, Any]:
    """Return visible SQL columns with descriptions from the same Cube context."""
    metadata = await cube_metadata(identity)
    connection = await connect(identity)
    try:
        views = await visible_views(connection)
        records = await connection.fetch(
            "SELECT table_name, column_name, data_type "
            "FROM information_schema.columns WHERE table_schema = 'public' "
            "ORDER BY table_name, ordinal_position"
        )
    finally:
        await connection.close()
    return semantic_schema(views, records, metadata)


def validate_sql(sql: str, allowed_views: set[str]) -> tuple[str, int | None]:
    """Allow one read-only Semantic SQL query against visible Cube views."""
    if not isinstance(sql, str) or not sql.strip():
        raise ValueError("sql must be a non-empty string")
    statement_sql = sql.strip()
    if statement_sql.endswith(";"):
        statement_sql = statement_sql[:-1].rstrip()
    if not statement_sql or ";" in statement_sql:
        raise ValueError("exactly one SQL statement is required")

    statements = sqlglot.parse(statement_sql, read="postgres")
    if len(statements) != 1 or not isinstance(statements[0], exp.Select):
        raise ValueError("only SELECT or WITH SELECT queries are supported")
    statement = statements[0]
    if statement.find(exp.Into):
        raise ValueError("SELECT INTO is not supported")

    cte_names = {cte.alias_or_name.lower() for cte in statement.find_all(exp.CTE)}
    source_views = {
        table.name.lower()
        for table in statement.find_all(exp.Table)
        if table.name.lower() not in cte_names
    }
    unknown_views = source_views - allowed_views
    if unknown_views:
        raise ValueError(f"only visible Cube views may be queried: {', '.join(sorted(unknown_views))}")

    limit = statement.args.get("limit")
    if limit is None:
        return statement_sql, None
    limit_value = limit.expression
    if not isinstance(limit_value, exp.Literal) or not limit_value.is_int:
        raise ValueError("LIMIT must be an integer")
    value = int(limit_value.this)
    if value < 1:
        raise ValueError("LIMIT must be a positive integer")
    return statement_sql, value


def json_value(value: Any) -> Any:
    """Convert PostgreSQL values into JSON values that MCP clients can read."""
    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, (datetime, date, clock_time, UUID)):
        return str(value)
    if isinstance(value, list):
        return [json_value(item) for item in value]
    if isinstance(value, dict):
        return {str(key): json_value(item) for key, item in value.items()}
    return value


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
mcp = FastMCP("Cube Semantic SQL", auth=auth)


@mcp.tool(auth=require_scopes("cube.read"))
async def get_schema() -> dict[str, Any]:
    """List visible Semantic SQL views, columns, and Cube descriptions."""
    return await described_schema(identity_from_token())


@mcp.tool(auth=require_scopes("cube.read"))
async def query_sql(sql: str) -> dict[str, Any]:
    """Run a read-only Cube Semantic SQL query."""
    identity = identity_from_token()
    connection = await connect(identity)
    try:
        allowed_views = await visible_views(connection)
        safe_sql, requested_limit = validate_sql(sql, allowed_views)
        records = await connection.fetch(safe_sql)
    finally:
        await connection.close()
    rows = [{key: json_value(value) for key, value in record.items()} for record in records]
    return {
        "columns": list(rows[0]) if rows else [],
        "rows": rows,
        "row_count": len(rows),
        "requested_limit": requested_limit,
    }


@mcp.tool(auth=require_scopes("cube.read"))
async def whoami() -> dict[str, Any]:
    """Show the effective governed identity without revealing credentials."""
    return identity_from_token()


if __name__ == "__main__":
    mcp.run(transport="http", host="0.0.0.0", port=8000)
