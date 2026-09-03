"""Read-only admin console for verified Cube SQL audit records."""
from __future__ import annotations

import asyncio
import json
import os
from contextlib import asynccontextmanager
from typing import Any
from urllib.parse import quote_plus

import asyncpg
from authlib.integrations.starlette_client import OAuth
from bson import ObjectId
from cryptography.fernet import Fernet, InvalidToken
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from pymongo import MongoClient
from starlette.middleware.sessions import SessionMiddleware
from starlette.staticfiles import StaticFiles
from starlette.templating import Jinja2Templates

AUDIT_DB_NAME = os.environ["AUDIT_DB_NAME"]
AUDIT_READER_USER = os.environ["AUDIT_READER_USER"]
AUDIT_READER_PASSWORD = os.environ["AUDIT_READER_PASSWORD"]
AUDIT_CONSOLE_SESSION_SECRET = os.environ["AUDIT_CONSOLE_SESSION_SECRET"]
AUTHENTIK_ISSUER = os.environ["AUTHENTIK_AUDIT_CONSOLE_ISSUER"].rstrip("/")
AUTHENTIK_CLIENT_SECRET = os.environ["AUTHENTIK_AUDIT_CONSOLE_CLIENT_SECRET"]
AUTHENTIK_CONSOLE_URL = os.environ["AUDIT_CONSOLE_PUBLIC_URL"].rstrip("/")
MONGO_URI = os.environ.get("MONGO_URI", "mongodb://mongodb:27017/LibreChat")
DATABASE_URL = (
    f"postgresql://{quote_plus(AUDIT_READER_USER)}:{quote_plus(AUDIT_READER_PASSWORD)}"
    f"@postgres:5432/{quote_plus(AUDIT_DB_NAME)}"
)
FERNET = Fernet(os.environ["AUDIT_PAYLOAD_ENCRYPTION_KEY"].encode("ascii"))
templates = Jinja2Templates(directory="/app/templates")

oauth = OAuth()
oauth.register(
    name="authentik",
    server_metadata_url=f"{AUTHENTIK_ISSUER}/.well-known/openid-configuration",
    client_id=os.environ.get("AUTHENTIK_AUDIT_CONSOLE_CLIENT_ID", "audit-console"),
    client_secret=AUTHENTIK_CLIENT_SECRET,
    client_kwargs={"scope": "openid profile email groups"},
)


def admin_claims(session: dict[str, Any]) -> dict[str, Any]:
    """Require exactly the admins group claim."""
    user = session.get("audit_user")
    if not isinstance(user, dict):
        raise HTTPException(status_code=401, detail="Sign in is required")
    groups = {str(group).strip().lower() for group in user.get("groups", []) if isinstance(group, str)}
    if groups != {"admins"}:
        raise HTTPException(status_code=403, detail="Only an unambiguous admins group claim may view audit data")
    return user


def render(request: Request, name: str, **context: Any) -> HTMLResponse:
    user = admin_claims(request.session)
    return templates.TemplateResponse(request, name, {"admin_email": user.get("email", "admin"), **context})


async def mongo_call(fn: Any) -> Any:
    return await asyncio.to_thread(fn)


def mongo_object_id(value: Any) -> Any:
    """Use a LibreChat string user id with Mongo ObjectId records."""
    try:
        return ObjectId(str(value))
    except Exception:
        return value


def decode_payload(value: bytes) -> dict[str, Any]:
    try:
        return json.loads(FERNET.decrypt(value).decode("utf-8"))
    except (InvalidToken, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise HTTPException(status_code=500, detail="Stored audit payload cannot be decrypted") from error


def pretty_json(value: Any) -> str:
    """Render stored JSON safely for the administrator review page."""
    return json.dumps(value, indent=2, sort_keys=True, default=str)


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.audit_pool = await asyncpg.create_pool(DATABASE_URL, min_size=1, max_size=4, command_timeout=15)
    app.state.mongo = MongoClient(MONGO_URI, serverSelectionTimeoutMS=3000).get_default_database()
    yield
    await app.state.audit_pool.close()
    app.state.mongo.client.close()


app = FastAPI(title="Verified SQL audit", lifespan=lifespan)
app.add_middleware(SessionMiddleware, secret_key=AUDIT_CONSOLE_SESSION_SECRET, https_only=False, same_site="lax")
app.mount("/static", StaticFiles(directory="/app/static"), name="static")


@app.get("/health")
async def health(request: Request) -> JSONResponse:
    try:
        async with request.app.state.audit_pool.acquire() as connection:
            await connection.fetchval("SELECT 1")
        await mongo_call(lambda: request.app.state.mongo.command("ping"))
    except Exception:
        return JSONResponse({"status": "unhealthy"}, status_code=503)
    return JSONResponse({"status": "ok"})


@app.get("/login")
async def login(request: Request) -> RedirectResponse:
    return await oauth.authentik.authorize_redirect(request, f"{AUTHENTIK_CONSOLE_URL}/auth/callback")


@app.get("/auth/callback")
async def auth_callback(request: Request) -> RedirectResponse:
    token = await oauth.authentik.authorize_access_token(request)
    userinfo = token.get("userinfo") or await oauth.authentik.userinfo(token=token)
    groups = userinfo.get("groups") if isinstance(userinfo, dict) else None
    if not isinstance(groups, list):
        raise HTTPException(status_code=403, detail="The audit console requires the groups claim")
    request.session["audit_user"] = {"email": userinfo.get("email"), "groups": groups, "sub": userinfo.get("sub")}
    admin_claims(request.session)
    return RedirectResponse("/", status_code=303)


@app.get("/logout")
async def logout(request: Request) -> RedirectResponse:
    request.session.clear()
    return RedirectResponse("/", status_code=303)


@app.get("/", response_class=HTMLResponse)
async def dashboard(request: Request) -> HTMLResponse:
    if not isinstance(request.session.get("audit_user"), dict):
        return templates.TemplateResponse(request, "login.html", {})
    admin_claims(request.session)
    async with request.app.state.audit_pool.acquire() as connection:
        summary = await connection.fetchrow(
            "SELECT COUNT(*) AS total, COUNT(*) FILTER (WHERE outcome = 'pass') AS passed, "
            "COUNT(*) FILTER (WHERE outcome = 'fail') AS failed, "
            "COUNT(*) FILTER (WHERE outcome = 'unavailable') AS unavailable FROM audit_events"
        )
        events = await connection.fetch(
            "SELECT event_id, occurred_at, conversation_id, agent_id, oauth_email, outcome, row_count, duration_ms, "
            "judge_confidence, judge_rationale "
            "FROM audit_events ORDER BY occurred_at DESC LIMIT 50"
        )
    return render(request, "dashboard.html", summary=dict(summary), events=events)


@app.get("/conversations", response_class=HTMLResponse)
async def conversations(request: Request, q: str = "") -> HTMLResponse:
    admin_claims(request.session)
    search = q.strip().lower()

    def load() -> list[dict[str, Any]]:
        rows = list(request.app.state.mongo.conversations.aggregate([
            {"$lookup": {"from": "users", "let": {"owner_id": "$user"}, "pipeline": [{"$match": {"$expr": {"$eq": [{"$toString": "$_id"}, "$$owner_id"]}}}], "as": "owner"}},
            {"$lookup": {"from": "agents", "localField": "agent_id", "foreignField": "id", "as": "agent"}},
            {"$project": {"conversationId": 1, "title": 1, "user": 1, "agent_id": 1, "updatedAt": 1, "owner.email": 1, "agent.name": 1}},
            {"$sort": {"updatedAt": -1}}, {"$limit": 300},
        ]))
        visible = []
        for row in rows:
            row["user_email"] = (row.get("owner") or [{}])[0].get("email")
            row["agent_name"] = (row.get("agent") or [{}])[0].get("name")
            terms = " ".join(str(row.get(key) or "") for key in ("user_email", "title", "agent_id", "agent_name"))
            if not search or search in terms.lower():
                visible.append(row)
        return visible

    rows = await mongo_call(load)
    identifiers = [row["conversationId"] for row in rows if row.get("conversationId")]
    counts: dict[str, int] = {}
    if identifiers:
        async with request.app.state.audit_pool.acquire() as connection:
            count_rows = await connection.fetch(
                "SELECT conversation_id, COUNT(*) AS count FROM audit_events WHERE conversation_id = ANY($1::text[]) GROUP BY conversation_id",
                identifiers,
            )
        counts = {row["conversation_id"]: row["count"] for row in count_rows}
    for row in rows:
        row["audit_count"] = counts.get(row.get("conversationId"), 0)
    if request.headers.get("X-Audit-Fragment") == "conversations":
        return templates.TemplateResponse(request, "conversation_rows.html", {"conversations": rows})
    return render(request, "conversations.html", conversations=rows, q=q)


@app.get("/conversations/{conversation_id}", response_class=HTMLResponse)
async def conversation(request: Request, conversation_id: str) -> HTMLResponse:
    admin_claims(request.session)

    def load() -> tuple[dict[str, Any] | None, list[dict[str, Any]]]:
        convo = request.app.state.mongo.conversations.find_one({"conversationId": conversation_id})
        if not convo:
            return None, []
        owner = request.app.state.mongo.users.find_one({"_id": mongo_object_id(convo.get("user"))}, {"email": 1}) or {}
        agent = request.app.state.mongo.agents.find_one({"id": convo.get("agent_id")}, {"name": 1}) or {}
        convo["user_email"], convo["agent_name"] = owner.get("email"), agent.get("name")
        messages = list(request.app.state.mongo.messages.find({"conversationId": conversation_id}).sort("createdAt", 1))
        return convo, messages

    convo, messages = await mongo_call(load)
    if not convo:
        raise HTTPException(status_code=404, detail="Conversation not found")
    async with request.app.state.audit_pool.acquire() as connection:
        events = await connection.fetch(
            "SELECT event_id, occurred_at, outcome, row_count, duration_ms FROM audit_events WHERE conversation_id = $1 ORDER BY occurred_at",
            conversation_id,
        )
    return render(request, "conversation.html", conversation=convo, messages=messages, events=events)


@app.get("/events/{event_id}", response_class=HTMLResponse)
async def event_detail(request: Request, event_id: str) -> HTMLResponse:
    admin_claims(request.session)
    async with request.app.state.audit_pool.acquire() as connection:
        event = await connection.fetchrow("SELECT * FROM audit_events WHERE event_id = $1::uuid", event_id)
    if not event:
        raise HTTPException(status_code=404, detail="Audit event not found")
    payload = decode_payload(event["encrypted_payload"])
    judge = payload.get("judge") if isinstance(payload.get("judge"), dict) else {}
    prompts = judge.get("prompt") if isinstance(judge.get("prompt"), list) else []
    attempts = judge.get("attempts") if isinstance(judge.get("attempts"), list) else []
    return render(
        request,
        "event.html",
        event=event,
        tool_parameters=pretty_json(payload.get("request", {})),
        executed_sql=str(payload.get("request", {}).get("sql", "")),
        cube_response=pretty_json(payload.get("cube", {}).get("query_result")),
        caller_schema=pretty_json(payload.get("cube", {}).get("caller_visible_schema")),
        judge_verdict=pretty_json(judge.get("verdict")),
        judge_system_prompt=str(prompts[0].get("content", "")) if prompts else "",
        judge_request_context=str(prompts[1].get("content", "")) if len(prompts) > 1 else "",
        judge_attempts=attempts,
        agent_response=pretty_json(payload.get("release", {}).get("response_to_agent")),
        raw_payload=pretty_json(payload),
    )
