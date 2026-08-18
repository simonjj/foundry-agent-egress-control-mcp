import hmac
import json
import os
from collections.abc import Awaitable, Callable
from typing import Any

import uvicorn
from mcp.server.fastmcp import FastMCP
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.types import Message, Receive, Scope, Send

from executor import execute_python

MCP_AUTH_TOKEN = os.environ.get("MCP_AUTH_TOKEN")
if not MCP_AUTH_TOKEN:
    raise RuntimeError("MCP_AUTH_TOKEN must be configured.")

mcp = FastMCP(
    name="aca-sandbox-python",
    instructions="Execute isolated Python code and return captured output.",
    host=os.environ.get("MCP_HOST", "0.0.0.0"),
    port=int(os.environ.get("MCP_PORT", "8080")),
    streamable_http_path="/mcp",
    stateless_http=True,
    json_response=True,
)


@mcp.tool()
async def run_python(code: str, timeout_seconds: int = 30) -> dict[str, Any]:
    """Run Python 3.12 code in an isolated temporary working directory.

    The process has no access to the MCP bearer token. Network access is
    governed independently by the ACA Sandbox egress policy.
    """

    return await execute_python(code, timeout_seconds)


@mcp.custom_route("/health", methods=["GET"])
async def health(_: Request) -> JSONResponse:
    return JSONResponse({"status": "ok"})


class BearerTokenMiddleware:
    def __init__(self, app: Callable[[Scope, Receive, Send], Awaitable[None]]) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http" or scope.get("path") == "/health":
            await self.app(scope, receive, send)
            return

        headers = {
            key.decode("latin-1").lower(): value.decode("latin-1")
            for key, value in scope.get("headers", [])
        }
        expected = f"Bearer {MCP_AUTH_TOKEN}"
        if not hmac.compare_digest(headers.get("authorization", ""), expected):
            body = json.dumps({"error": "unauthorized"}).encode("utf-8")

            async def unauthorized_send(message: Message) -> None:
                await send(message)

            await unauthorized_send(
                {
                    "type": "http.response.start",
                    "status": 401,
                    "headers": [
                        (b"content-type", b"application/json"),
                        (b"content-length", str(len(body)).encode("ascii")),
                    ],
                }
            )
            await unauthorized_send(
                {"type": "http.response.body", "body": body, "more_body": False}
            )
            return

        await self.app(scope, receive, send)


if __name__ == "__main__":
    app = BearerTokenMiddleware(mcp.streamable_http_app())
    uvicorn.run(
        app,
        host=mcp.settings.host,
        port=mcp.settings.port,
        log_level="info",
    )

