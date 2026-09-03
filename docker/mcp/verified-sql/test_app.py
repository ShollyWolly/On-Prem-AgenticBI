"""Focused tests for the verifier's strict judge contract."""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import time
import unittest
from unittest.mock import patch

from starlette.requests import Request

os.environ.setdefault("AUTHENTIK_CUBE_ISSUER", "http://authentik.localhost:9000/application/o/cube-mcp/")
os.environ.setdefault("AUTHENTIK_CUBE_JWKS_URL", "http://authentik.localhost:9000/application/o/cube-mcp/jwks/")
os.environ.setdefault("VERIFIED_SQL_MCP_PUBLIC_URL", "http://verified-sql-mcp:8000")
os.environ.setdefault("AZURE_FOUNDRY_BASE_URL", "http://foundry.invalid")
os.environ.setdefault("AZURE_FOUNDRY_API_KEY", "test-key")
os.environ.setdefault("AZURE_FOUNDRY_MODEL", "test-model")
os.environ.setdefault("VERIFICATION_JUDGE_MODEL", "")
os.environ.setdefault("AUDIT_DB_NAME", "audit")
os.environ.setdefault("AUDIT_WRITER_USER", "writer")
os.environ.setdefault("AUDIT_WRITER_PASSWORD", "writer-password")
os.environ.setdefault("AUDIT_CONTEXT_HMAC_KEY", "test-hmac-key")
os.environ.setdefault("AUDIT_PAYLOAD_ENCRYPTION_KEY", "MDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDA=")

import app
from app import VerificationVerdict, judge_messages, parse_verdict


class VerdictContractTests(unittest.TestCase):
    def test_accepts_a_complete_verdict(self) -> None:
        verdict = parse_verdict(
            '{"verdict":"pass","confidence":0.91,"rationale":"The metric and grouping match the request.","issues":[]}'
        )
        self.assertEqual(verdict.verdict, "pass")

    def test_rejects_extra_or_partial_judge_output(self) -> None:
        with self.assertRaises(Exception):
            parse_verdict('{"verdict":"pass","confidence":0.9,"rationale":"ok","issues":[],"extra":true}')
        with self.assertRaises(Exception):
            parse_verdict('{"verdict":"pass","confidence":0.9}')

    def test_judge_context_never_contains_result_rows(self) -> None:
        messages = judge_messages(
            "Show total revenue by store.",
            {
                "views": [
                    {
                        "name": "store_performance",
                        "description": "Store revenue reporting.",
                        "columns": [{"name": "total_revenue", "description": "Total revenue measure."}],
                    },
                    {"name": "raw_customer", "description": "Admin source-table view.", "columns": []},
                ]
            },
            "SELECT MEASURE(total_revenue) FROM store_performance",
        )
        system = messages[0]["content"]
        context = messages[1]["content"]
        self.assertIn('"store_performance"', system)
        self.assertIn('"raw_customer"', system)
        self.assertIn("Total revenue measure.", system)
        self.assertIn("executed_sql", context)
        self.assertNotIn("semantic_schema", context)
        self.assertNotIn("rows", context)


class AuditContextTests(unittest.TestCase):
    def signed_request(self, mutate: bool = False) -> Request:
        payload = {
            "version": 1,
            "audit_id": "00000000-0000-0000-0000-000000000001",
            "conversation_id": "conversation-1",
            "message_id": "message-1",
            "run_id": "run-1",
            "agent_id": "agent-1",
            "librechat_user_id": "user-1",
            "librechat_user_email": "analyst@demo.local",
            "issued_at": int(time.time()),
        }
        encoded = base64.urlsafe_b64encode(json.dumps(payload, separators=(",", ":")).encode()).rstrip(b"=").decode()
        signature = base64.urlsafe_b64encode(
            hmac.new(app.AUDIT_CONTEXT_HMAC_KEY, encoded.encode("ascii"), hashlib.sha256).digest()
        ).rstrip(b"=").decode()
        if mutate:
            signature = f"x{signature[1:]}"
        return Request(
            {
                "type": "http",
                "method": "POST",
                "scheme": "http",
                "path": "/mcp",
                "query_string": b"",
                "headers": [(b"x-agenticbi-audit-context", f"{encoded}.{signature}".encode())],
                "client": ("127.0.0.1", 10000),
                "server": ("testserver", 80),
            }
        )

    def test_accepts_a_signed_librechat_context(self) -> None:
        with patch.object(app, "get_http_request", return_value=self.signed_request()):
            context = app.audit_context_from_request()
        self.assertEqual(context.conversation_id, "conversation-1")

    def test_rejects_a_tampered_librechat_context(self) -> None:
        with patch.object(app, "get_http_request", return_value=self.signed_request(mutate=True)):
            with self.assertRaises(PermissionError):
                app.audit_context_from_request()


class AuditWriteTests(unittest.IsolatedAsyncioTestCase):
    async def test_encrypts_full_payload_before_insert(self) -> None:
        captured: list[object] = []

        class Connection:
            async def execute(self, *_args: object) -> None:
                captured.extend(_args)

            async def close(self) -> None:
                return None

        async def connect(*_args: object, **_kwargs: object) -> Connection:
            return Connection()

        context = app.AuditContext(
            version=1,
            audit_id="00000000-0000-0000-0000-000000000001",
            conversation_id="conversation-1",
            message_id="message-1",
            run_id="run-1",
            agent_id="agent-1",
            librechat_user_id="user-1",
            librechat_user_email="analyst@demo.local",
            issued_at=1,
        )
        payload = {
            "user_request": "Show revenue.",
            "cube_response": {"data": [{"total": "123"}]},
            "judge": {
                "verdict": {
                    "verdict": "pass",
                    "confidence": 0.99,
                    "rationale": "The metric matches.",
                    "issues": [],
                }
            },
        }
        with patch.object(app.asyncpg, "connect", connect):
            await app.write_audit_event(
                context,
                {"subject": "subject-1", "email": "analyst@demo.local", "role": "analyst"},
                "pass",
                1,
                25,
                payload,
            )
        self.assertEqual(len(captured), 21)
        encrypted = captured[-1]
        self.assertIsInstance(encrypted, bytes)
        self.assertEqual(captured[15:18], [0.99, "The metric matches.", "[]"])
        self.assertEqual(json.loads(app.AUDIT_FERNET.decrypt(encrypted)), payload)


class VerificationVisibilityTests(unittest.IsolatedAsyncioTestCase):
    async def test_passing_verdict_is_not_returned_to_the_agent(self) -> None:
        async def cube_sql_tool(name: str, _arguments: dict) -> dict:
            if name == "query_sql":
                return {"data": [{"total_revenue": "123.45"}]}
            if name == "get_schema":
                return {"views": []}
            raise AssertionError(f"unexpected tool: {name}")

        async def judge_sql(_request: str, _schema: dict, _sql: str):
            return VerificationVerdict(
                verdict="pass",
                confidence=0.99,
                rationale="The request and SQL match.",
                issues=[],
            ), 1, []

        async def write_audit_event(*_args: object) -> None:
            return None

        context = app.AuditContext(
            version=1,
            audit_id="00000000-0000-0000-0000-000000000001",
            conversation_id="conversation-1",
            message_id="message-1",
            run_id="run-1",
            agent_id="agent-1",
            librechat_user_id="user-1",
            librechat_user_email="analyst@demo.local",
            issued_at=1,
        )
        with patch.object(app, "cube_sql_tool", cube_sql_tool), patch.object(app, "judge_sql", judge_sql), patch.object(app, "write_audit_event", write_audit_event), patch.object(app, "audit_context_from_request", lambda: context), patch.object(app, "token_identity", lambda: {"subject": "subject-1", "email": "analyst@demo.local", "role": "analyst"}):
            result = await app.query_sql("Show total revenue.", "SELECT MEASURE(total_revenue) FROM revenue_analytics")

        self.assertEqual(result, {"data": [{"total_revenue": "123.45"}]})
        self.assertNotIn("verification", result)


if __name__ == "__main__":
    unittest.main()
