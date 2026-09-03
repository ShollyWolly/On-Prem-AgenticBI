"""OAuth-protected verified SQL MCP layered on Cube Semantic SQL."""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import time
from typing import Any, Literal
from urllib.parse import quote_plus
from uuid import UUID, uuid4

import asyncpg
from cryptography.fernet import Fernet
import httpx
from fastmcp import Client, FastMCP
from fastmcp.client.transports import StreamableHttpTransport
from fastmcp.server.auth import RemoteAuthProvider, require_scopes
from fastmcp.server.auth.providers.jwt import JWTVerifier
from fastmcp.server.dependencies import get_access_token, get_http_request
from pydantic import AnyHttpUrl, BaseModel, ConfigDict, Field, ValidationError

CUBE_SQL_MCP_URL = os.environ.get("CUBE_SQL_MCP_URL", "http://cube-sql-mcp:8000/mcp")
AUTHENTIK_ISSUER = os.environ["AUTHENTIK_CUBE_ISSUER"]
AUTHENTIK_JWKS = os.environ["AUTHENTIK_CUBE_JWKS_URL"]
MCP_PUBLIC_URL = os.environ["VERIFIED_SQL_MCP_PUBLIC_URL"]
FOUNDRY_BASE_URL = os.environ["AZURE_FOUNDRY_BASE_URL"].rstrip("/")
FOUNDRY_API_KEY = os.environ["AZURE_FOUNDRY_API_KEY"]
FOUNDRY_MODEL = os.environ["VERIFICATION_JUDGE_MODEL"] or os.environ["AZURE_FOUNDRY_MODEL"]
VERIFICATION_ENABLED = os.environ.get("VERIFICATION_ENABLED", "true").lower() == "true"
VERIFICATION_MAX_ATTEMPTS = max(1, int(os.environ.get("VERIFICATION_MAX_ATTEMPTS", "2")))
VERIFICATION_JUDGE_MAX_TOKENS = max(128, int(os.environ.get("VERIFICATION_JUDGE_MAX_TOKENS", "1000")))
VERIFICATION_JUDGE_REASONING_EFFORT = os.environ.get("VERIFICATION_JUDGE_REASONING_EFFORT", "minimal").strip()
AUDIT_DB_NAME = os.environ["AUDIT_DB_NAME"]
AUDIT_WRITER_USER = os.environ["AUDIT_WRITER_USER"]
AUDIT_WRITER_PASSWORD = os.environ["AUDIT_WRITER_PASSWORD"]
AUDIT_CONTEXT_HMAC_KEY = os.environ["AUDIT_CONTEXT_HMAC_KEY"].encode("utf-8")
AUDIT_PAYLOAD_ENCRYPTION_KEY = os.environ["AUDIT_PAYLOAD_ENCRYPTION_KEY"].encode("ascii")
AUDIT_DATABASE_URL = (
    f"postgresql://{quote_plus(AUDIT_WRITER_USER)}:{quote_plus(AUDIT_WRITER_PASSWORD)}"
    f"@postgres:5432/{quote_plus(AUDIT_DB_NAME)}"
)
AUDIT_FERNET = Fernet(AUDIT_PAYLOAD_ENCRYPTION_KEY)


class VerificationIssue(BaseModel):
    """One concise reason why a successful SQL query does not answer the request."""

    model_config = ConfigDict(extra="forbid")
    code: Literal["wrong_view", "wrong_member", "wrong_metric", "wrong_filter", "wrong_grain", "unsupported_claim", "other"]
    message: str = Field(min_length=1, max_length=400)


class VerificationVerdict(BaseModel):
    """Strict response contract for the SQL relevance judge."""

    model_config = ConfigDict(extra="forbid")
    verdict: Literal["pass", "fail"]
    confidence: float = Field(ge=0, le=1)
    rationale: str = Field(min_length=1, max_length=500)
    issues: list[VerificationIssue] = Field(default_factory=list, max_length=5)


VERDICT_SCHEMA = VerificationVerdict.model_json_schema()


class AuditContext(BaseModel):
    """Trusted LibreChat correlation data signed before the MCP request is sent."""

    model_config = ConfigDict(extra="forbid")
    version: Literal[1]
    audit_id: UUID
    conversation_id: str = Field(min_length=1, max_length=200)
    message_id: str = Field(min_length=1, max_length=200)
    run_id: str = Field(min_length=1, max_length=200)
    agent_id: str = Field(min_length=1, max_length=200)
    librechat_user_id: str = Field(min_length=1, max_length=200)
    librechat_user_email: str = Field(min_length=1, max_length=320)
    issued_at: int


def b64url_decode(value: str) -> bytes:
    """Decode unpadded URL-safe base64 without accepting malformed input."""
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def audit_context_from_request() -> AuditContext:
    """Require the trusted request correlation header minted by LibreChat."""
    value = get_http_request().headers.get("x-agenticbi-audit-context", "")
    try:
        payload_part, signature_part = value.split(".", 1)
        expected = hmac.new(AUDIT_CONTEXT_HMAC_KEY, payload_part.encode("ascii"), hashlib.sha256).digest()
        supplied = b64url_decode(signature_part)
        if not hmac.compare_digest(expected, supplied):
            raise ValueError("signature mismatch")
        context = AuditContext.model_validate_json(b64url_decode(payload_part))
    except (ValueError, ValidationError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise PermissionError("A valid LibreChat audit context is required for verified SQL") from error
    if abs(int(time.time()) - context.issued_at) > 300:
        raise PermissionError("The LibreChat audit context has expired")
    return context


def token_identity() -> dict[str, str]:
    """Extract the caller identity already verified by the OAuth middleware."""
    token = get_access_token()
    claims = token.claims if token else {}
    subject = str(claims.get("sub") or "").strip()
    email = str(claims.get("email") or "").strip().lower()
    groups = {str(group).strip().lower() for group in claims.get("groups", []) if isinstance(group, str)}
    role = "admin" if groups == {"admins"} else "analyst" if groups == {"analysts"} else "denied"
    if not subject or not email or role == "denied":
        raise PermissionError("Authenticated token has no unambiguous governed identity")
    return {"subject": subject, "email": email, "role": role}


async def write_audit_event(
    context: AuditContext,
    identity: dict[str, str],
    outcome: Literal["pass", "fail", "unavailable"],
    row_count: int | None,
    duration_ms: int,
    payload: dict[str, Any],
) -> None:
    """Persist encrypted full evidence before any successful rows are released."""
    plaintext = json.dumps(payload, separators=(",", ":"), default=str).encode("utf-8")
    encrypted = AUDIT_FERNET.encrypt(plaintext)
    payload_hash = hashlib.sha256(plaintext).hexdigest()
    judge = payload.get("judge", {}).get("verdict")
    confidence = judge.get("confidence") if isinstance(judge, dict) else None
    rationale = judge.get("rationale") if isinstance(judge, dict) else None
    issues = judge.get("issues") if isinstance(judge, dict) else None
    event_id = uuid4()
    event_hash = hashlib.sha256(
        f"{event_id}:{context.audit_id}:{payload_hash}:{outcome}".encode("utf-8")
    ).hexdigest()
    connection = await asyncpg.connect(AUDIT_DATABASE_URL, timeout=10, command_timeout=15)
    try:
        await connection.execute(
            "INSERT INTO audit_events "
            "(event_id, audit_id, conversation_id, message_id, run_id, agent_id, librechat_user_id, "
            "librechat_user_email, oauth_subject, oauth_email, cube_role, outcome, row_count, duration_ms, "
            "judge_confidence, judge_rationale, judge_issues, payload_sha256, event_hash, encrypted_payload) "
            "VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20)",
            event_id,
            context.audit_id,
            context.conversation_id,
            context.message_id,
            context.run_id,
            context.agent_id,
            context.librechat_user_id,
            context.librechat_user_email,
            identity["subject"],
            identity["email"],
            identity["role"],
            outcome,
            row_count,
            duration_ms,
            confidence,
            rationale,
            json.dumps(issues) if issues is not None else None,
            payload_hash,
            event_hash,
            encrypted,
        )
    finally:
        await connection.close()


def inbound_token() -> str:
    """Return the caller bearer token for delegated calls without logging it."""
    token = get_access_token()
    raw = str(token.token or "") if token else ""
    if not raw:
        raise PermissionError("Authenticated access token is required")
    return raw


async def cube_sql_tool(name: str, arguments: dict[str, Any]) -> dict[str, Any]:
    """Call the existing SQL MCP with the same authenticated caller token."""
    transport = StreamableHttpTransport(CUBE_SQL_MCP_URL, auth=inbound_token())
    async with Client(transport, timeout=60) as client:
        # Return downstream tool errors as data so unsuccessful SQL never reaches
        # the verifier and is reported as a normal retryable tool response.
        result = await client.call_tool(name, arguments, raise_on_error=False)
    if result.is_error:
        raise ValueError(str(result.data or "Cube Semantic SQL rejected the request"))
    if not isinstance(result.data, dict):
        raise RuntimeError("Cube Semantic SQL returned an invalid tool payload")
    return result.data


def judge_messages(user_request: str, schema: dict[str, Any], sql: str) -> list[dict[str, str]]:
    """Build the isolated judge context without including query result rows."""
    system = (
        "You are a strict SQL relevance judge for a governed Cube Semantic SQL service. "
        "Judge only whether the SQL answers the user's request using the supplied caller-visible schema. "
        "The SQL has already executed successfully, but you never receive its rows. "
        "MEASURE(member) is valid Cube Semantic SQL for a metric. "
        "A raw_* view is valid only when it appears in the supplied schema. "
        "Pass only when the requested metric, grain, filters, time logic, and visible members are appropriate. "
        "Reject guesses, wrong semantic views, misleading aggregations, and claims unsupported by the SQL. "
        "Return only JSON in this exact shape: "
        '{"verdict":"pass or fail","confidence":0.0,"rationale":"short reason",'
        '"issues":[{"code":"wrong_view, wrong_member, wrong_metric, wrong_filter, wrong_grain, unsupported_claim, or other",'
        '"message":"short reason"}]}. '
        "Caller-visible semantic schema: "
        f"{json.dumps(schema, separators=(',', ':'))}"
    )
    context = json.dumps(
        {"user_request": user_request, "executed_sql": sql},
        separators=(",", ":"),
    )
    return [{"role": "system", "content": system}, {"role": "user", "content": context}]


async def request_judge(messages: list[dict[str, str]], structured: bool) -> tuple[str, dict[str, Any]]:
    """Request a compact verdict while retaining the raw response for the audit record."""
    payload: dict[str, Any] = {
        "model": FOUNDRY_MODEL,
        "messages": messages,
        "max_completion_tokens": VERIFICATION_JUDGE_MAX_TOKENS,
    }
    if structured:
        payload["response_format"] = {
            "type": "json_schema",
            "json_schema": {"name": "sql_verdict", "strict": True, "schema": VERDICT_SCHEMA},
        }
    if VERIFICATION_JUDGE_REASONING_EFFORT:
        payload["reasoning_effort"] = VERIFICATION_JUDGE_REASONING_EFFORT
    async with httpx.AsyncClient(timeout=45) as client:
        response = await client.post(
            f"{FOUNDRY_BASE_URL}/chat/completions",
            headers={"Authorization": f"Bearer {FOUNDRY_API_KEY}", "Content-Type": "application/json"},
            json=payload,
        )
    response.raise_for_status()
    body = response.json()
    try:
        content = body["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError) as error:
        raise ValueError("Judge returned no assistant content") from error
    if not isinstance(content, str):
        raise ValueError("Judge returned non-text assistant content")
    return content, body


def parse_verdict(content: str) -> VerificationVerdict:
    """Accept only complete JSON that conforms to the declared verdict contract."""
    return VerificationVerdict.model_validate_json(content)


async def judge_sql(
    user_request: str, schema: dict[str, Any], sql: str
) -> tuple[VerificationVerdict | None, int, list[dict[str, Any]]]:
    """Retry malformed judge output, never silently accepting a partial verdict."""
    messages = judge_messages(user_request, schema, sql)
    use_structured = True
    audit_attempts: list[dict[str, Any]] = []
    for attempt in range(1, VERIFICATION_MAX_ATTEMPTS + 1):
        try:
            content, response = await request_judge(messages, structured=use_structured)
            verdict = parse_verdict(content)
            audit_attempts.append({"attempt": attempt, "structured": use_structured, "raw_content": content, "response": response})
            return verdict, attempt, audit_attempts
        except httpx.HTTPStatusError as error:
            audit_attempts.append(
                {"attempt": attempt, "structured": use_structured, "error": f"HTTP {error.response.status_code}", "response": error.response.text}
            )
            # Some compatible Azure deployments do not support JSON schema mode.
            if use_structured and error.response.status_code in {400, 404, 422}:
                use_structured = False
                continue
        except (ValidationError, ValueError, json.JSONDecodeError) as error:
            audit_attempts.append({"attempt": attempt, "structured": use_structured, "error": str(error)})
        except httpx.HTTPError as error:
            audit_attempts.append({"attempt": attempt, "structured": use_structured, "error": str(error)})
        messages = [
            *messages,
            {
                "role": "user",
                "content": "Your previous verdict was invalid. Return only complete JSON matching the required schema.",
            },
        ]
    return None, VERIFICATION_MAX_ATTEMPTS, audit_attempts


def compact_verification(status: str, attempts: int, verdict: VerificationVerdict | None = None) -> dict[str, Any]:
    """Return user-displayable status without exposing hidden prompt context."""
    payload: dict[str, Any] = {"status": status, "attempts": attempts}
    if verdict:
        payload.update({"confidence": verdict.confidence, "rationale": verdict.rationale})
    return payload


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
mcp = FastMCP("Verified Cube Semantic SQL", auth=auth)


@mcp.tool(auth=require_scopes("cube.read"))
async def get_schema() -> dict[str, Any]:
    """List the caller-visible Cube Semantic SQL schema used to write verified queries."""
    return await cube_sql_tool("get_schema", {})


@mcp.tool(auth=require_scopes("cube.read"))
async def query_sql(user_request: str, sql: str) -> dict[str, Any]:
    """Execute SQL, then return rows only when the independent SQL judge passes it."""
    if not isinstance(user_request, str) or not user_request.strip():
        raise ValueError("user_request must contain the current user request")
    context = audit_context_from_request()
    identity = token_identity()
    started = time.monotonic()
    try:
        result = await cube_sql_tool("query_sql", {"sql": sql})
    except (ValueError, RuntimeError) as error:
        return {"status": "sql_error", "error": str(error)}

    schema: dict[str, Any] | None = None
    verdict: VerificationVerdict | None = None
    attempts = 0
    judge_attempts: list[dict[str, Any]] = []
    outcome: Literal["pass", "fail", "unavailable"] = "pass"
    response: dict[str, Any] = result
    if not VERIFICATION_ENABLED:
        judge_attempts = [{"verification_enabled": False}]
    else:
        try:
            schema = await cube_sql_tool("get_schema", {})
            verdict, attempts, judge_attempts = await judge_sql(user_request.strip(), schema, sql)
        except (ValueError, RuntimeError, httpx.HTTPError) as error:
            verdict, attempts = None, VERIFICATION_MAX_ATTEMPTS
            judge_attempts = [{"error": str(error)}]

        if verdict is None:
            outcome = "unavailable"
            response = {
                "status": "verification_unavailable",
                "verification": compact_verification("unavailable", attempts),
                "error": "The SQL executed, but verification did not return a valid verdict. Revise or retry the query.",
            }
        elif verdict.verdict == "fail":
            outcome = "fail"
            response = {
                "status": "verification_failed",
                "verification": compact_verification("failed", attempts, verdict),
                "revision_feedback": [issue.model_dump() for issue in verdict.issues],
            }

    payload = {
        "version": 1,
        "audit_context": context.model_dump(mode="json"),
        "identity": identity,
        "request": {"user_request": user_request.strip(), "sql": sql},
        "cube": {"query_result": result, "caller_visible_schema": schema},
        "judge": {
            "prompt": judge_messages(user_request.strip(), schema, sql) if schema is not None else None,
            "attempts": judge_attempts,
            "verdict": verdict.model_dump() if verdict else None,
        },
        "release": {"outcome": outcome, "response_to_agent": response},
    }
    try:
        await write_audit_event(
            context,
            identity,
            outcome,
            int(result.get("row_count")) if isinstance(result.get("row_count"), int) else None,
            int((time.monotonic() - started) * 1000),
            payload,
        )
    except Exception:
        return {
            "status": "audit_unavailable",
            "error": "The SQL executed, but its required audit record could not be written. No rows were released.",
        }
    return response


@mcp.tool(auth=require_scopes("cube.read"))
async def whoami() -> dict[str, Any]:
    """Show the caller's effective governed identity through Cube Semantic SQL."""
    return await cube_sql_tool("whoami", {})


if __name__ == "__main__":
    mcp.run(transport="http", host="0.0.0.0", port=8000)
