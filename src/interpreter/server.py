import asyncio
import hmac
import json
import os
import re
from collections.abc import Awaitable, Callable
from typing import Any
from urllib.parse import urlencode

import requests
import uvicorn
from bs4 import BeautifulSoup
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


def _search_craigslist(query: str, site: str, limit: int) -> dict[str, Any]:
    if not query.strip():
        raise ValueError("query must not be empty")
    if len(query) > 200:
        raise ValueError("query must be at most 200 characters")
    if not re.fullmatch(r"[a-z0-9-]{1,40}", site):
        raise ValueError("site must be a Craigslist subdomain such as 'seattle'")
    if not 1 <= limit <= 20:
        raise ValueError("limit must be between 1 and 20")

    params = urlencode({"query": query, "sort": "date"})
    search_url = f"https://{site}.craigslist.org/search/sss?{params}"
    response = requests.get(
        search_url,
        headers={"User-Agent": "StateStreetReferenceAgent/1.0"},
        timeout=20,
    )
    response.raise_for_status()

    soup = BeautifulSoup(response.text, "html.parser")
    elements = soup.select(
        "li.cl-static-search-result, li.cl-search-result, div.cl-search-result"
    )
    results: list[dict[str, str]] = []
    seen_urls: set[str] = set()
    for element in elements:
        link = element.select_one("a[href]")
        if link is None:
            continue
        url = str(link.get("href", "")).strip()
        if not url or url in seen_urls:
            continue
        seen_urls.add(url)
        title_element = element.select_one(".title")
        price_element = element.select_one(".price")
        location_element = element.select_one(".location")
        results.append(
            {
                "title": (
                    title_element.get_text(" ", strip=True)
                    if title_element
                    else link.get_text(" ", strip=True)
                ),
                "price": (
                    price_element.get_text(" ", strip=True)
                    if price_element
                    else ""
                ),
                "location": (
                    location_element.get_text(" ", strip=True)
                    if location_element
                    else ""
                ),
                "url": url,
            }
        )
        if len(results) >= limit:
            break

    return {
        "query": query,
        "site": site,
        "search_url": search_url,
        "results": results,
    }


@mcp.tool()
async def search_craigslist(
    query: str,
    site: str = "seattle",
    limit: int = 10,
) -> dict[str, Any]:
    """Search recent Craigslist listings through the governed Sandbox egress path."""

    return await asyncio.to_thread(_search_craigslist, query, site, limit)


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
