import asyncio
import contextvars
import json
import logging
import os
from collections.abc import Awaitable, Callable
from datetime import timedelta
from typing import Any

import httpx
import jwt
import uvicorn
from jwt import PyJWKClient
from jwt.exceptions import (
    InvalidAlgorithmError,
    InvalidTokenError,
)
from auth_diagnostics import AuthenticationError, log_authentication_failure
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client
from mcp.server.fastmcp import FastMCP
from routing import (
    CustomerRoute,
    CustomerRouter,
    require_allowed_craigslist_site,
)
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.types import Message, Receive, Scope, Send


def required_environment(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise RuntimeError(f"Required environment variable {name} is not set.")
    return value


TENANT_ID = required_environment("ENTRA_TENANT_ID")
AUDIENCE = required_environment("ENTRA_AUDIENCE")
REQUIRED_SCOPE = os.getenv("ENTRA_REQUIRED_SCOPE", "McpBroker.Invoke")
ISSUER = f"https://login.microsoftonline.com/{TENANT_ID}/v2.0"
JWKS_CLIENT = PyJWKClient(
    f"https://login.microsoftonline.com/{TENANT_ID}/discovery/v2.0/keys",
    cache_keys=False,
    cache_jwk_set=False,
    timeout=5,
)
JWKS_CACHE_SECONDS = 300
JWKS_REFRESH_COOLDOWN_SECONDS = 30
UNKNOWN_KID_CACHE_SECONDS = 30
UNKNOWN_KID_CACHE_LIMIT = 128
JWKS_REFRESH_LOCK = asyncio.Lock()
JWT_VALIDATION_LIMIT = asyncio.Semaphore(16)
SANDBOX_CALL_LIMIT = asyncio.Semaphore(16)
SANDBOX_REQUEST_TIMEOUT_SECONDS = 120
SANDBOX_SSE_TIMEOUT_SECONDS = 180
ROUTER = CustomerRouter.from_environment()
LOGGER = logging.getLogger("broker.routing")

_signing_keys: dict[str, Any] = {}
_signing_keys_expires_at = 0.0
_next_forced_jwks_refresh = 0.0
_jwks_refresh_retry_at = 0.0
_unknown_kids: dict[str, float] = {}

_claims: contextvars.ContextVar[dict[str, Any] | None] = contextvars.ContextVar(
    "broker_claims",
    default=None,
)

mcp = FastMCP(
    name="state-street-tenant-aware-broker",
    instructions=(
        "Expose governed tools only after validating the calling user's "
        "Microsoft Entra delegated identity."
    ),
    host=os.getenv("MCP_HOST", "0.0.0.0"),
    port=int(os.getenv("MCP_PORT", "8080")),
    streamable_http_path="/mcp",
    stateless_http=True,
    json_response=True,
)


class JwksUnavailableError(RuntimeError):
    pass


def _extract_token(authorization: str) -> tuple[str, str]:
    if not authorization.startswith("Bearer "):
        raise AuthenticationError("missing_bearer")

    token = authorization.removeprefix("Bearer ").strip()
    if not token or len(token) > 8192:
        raise AuthenticationError("invalid_bearer")

    header = jwt.get_unverified_header(token)
    if header.get("alg") != "RS256":
        raise InvalidAlgorithmError("The token signing algorithm is unsupported.")

    kid = header.get("kid")
    if not isinstance(kid, str) or not kid or len(kid) > 256:
        raise InvalidTokenError("The token signing key identifier is invalid.")

    return token, kid


def _fetch_signing_keys() -> dict[str, Any]:
    return {
        signing_key.key_id: signing_key
        for signing_key in JWKS_CLIENT.get_signing_keys(refresh=True)
    }


def _remember_unknown_kid(kid: str, now: float) -> None:
    expired_kids = [
        cached_kid
        for cached_kid, expires_at in _unknown_kids.items()
        if expires_at <= now
    ]
    for cached_kid in expired_kids:
        _unknown_kids.pop(cached_kid, None)

    while len(_unknown_kids) >= UNKNOWN_KID_CACHE_LIMIT:
        _unknown_kids.pop(next(iter(_unknown_kids)))
    _unknown_kids[kid] = now + UNKNOWN_KID_CACHE_SECONDS


async def _resolve_signing_key(kid: str) -> Any:
    global _jwks_refresh_retry_at
    global _next_forced_jwks_refresh
    global _signing_keys
    global _signing_keys_expires_at

    loop = asyncio.get_running_loop()
    now = loop.time()
    signing_key = _signing_keys.get(kid)
    if signing_key is not None and now < _signing_keys_expires_at:
        return signing_key
    if _unknown_kids.get(kid, 0) > now:
        raise InvalidTokenError("The token signing key is unknown.")

    async with JWKS_REFRESH_LOCK:
        now = loop.time()
        signing_key = _signing_keys.get(kid)
        if signing_key is not None and now < _signing_keys_expires_at:
            return signing_key
        if _unknown_kids.get(kid, 0) > now:
            raise InvalidTokenError("The token signing key is unknown.")

        if now < _jwks_refresh_retry_at:
            raise JwksUnavailableError("JWKS refresh is temporarily unavailable.")

        cache_expired = now >= _signing_keys_expires_at
        if (
            _signing_keys
            and not cache_expired
            and now < _next_forced_jwks_refresh
        ):
            _remember_unknown_kid(kid, now)
            raise InvalidTokenError("The token signing key is unknown.")

        try:
            refreshed_keys = await asyncio.to_thread(_fetch_signing_keys)
        except (jwt.PyJWTError, ValueError, OSError, TimeoutError) as error:
            _jwks_refresh_retry_at = (
                loop.time() + JWKS_REFRESH_COOLDOWN_SECONDS
            )
            raise JwksUnavailableError(
                "Unable to refresh Entra signing keys."
            ) from error

        refreshed_at = loop.time()
        _signing_keys = refreshed_keys
        _signing_keys_expires_at = refreshed_at + JWKS_CACHE_SECONDS
        _next_forced_jwks_refresh = (
            refreshed_at + JWKS_REFRESH_COOLDOWN_SECONDS
        )
        _jwks_refresh_retry_at = 0.0
        _unknown_kids.clear()

        signing_key = _signing_keys.get(kid)
        if signing_key is None:
            _remember_unknown_kid(kid, refreshed_at)
            raise InvalidTokenError("The token signing key is unknown.")
        return signing_key


def _decode_claims(authorization: str, signing_key: Any) -> dict[str, Any]:
    if not authorization.startswith("Bearer "):
        raise PermissionError("Bearer authentication is required.")

    token = authorization.removeprefix("Bearer ").strip()
    if not token or len(token) > 8192:
        raise PermissionError("The bearer token is invalid.")
    claims = jwt.decode(
        token,
        signing_key.key,
        algorithms=["RS256"],
        audience=AUDIENCE,
        issuer=ISSUER,
        options={"require": ["aud", "exp", "iat", "iss", "sub", "tid"]},
    )

    scopes = set(str(claims.get("scp", "")).split())
    if REQUIRED_SCOPE not in scopes:
        raise PermissionError(f"Required delegated scope {REQUIRED_SCOPE} is missing.")
    if claims.get("tid") != TENANT_ID:
        raise PermissionError("The caller belongs to an unsupported tenant.")
    if not claims.get("oid"):
        raise PermissionError("The delegated token does not identify a user.")

    return claims


async def validated_claims(authorization: str) -> dict[str, Any]:
    _, kid = _extract_token(authorization)
    signing_key = await _resolve_signing_key(kid)
    async with JWT_VALIDATION_LIMIT:
        return await asyncio.to_thread(_decode_claims, authorization, signing_key)


def current_claims() -> dict[str, Any]:
    claims = _claims.get()
    if claims is None:
        raise PermissionError("No validated delegated identity is available.")
    return claims


def current_customer_route() -> CustomerRoute:
    return ROUTER.resolve(current_claims())


def _result_payload(result: Any) -> dict[str, Any]:
    if result.isError:
        raise RuntimeError("The selected Sandbox tool returned an error.")
    return result.model_dump(mode="json", by_alias=True, exclude_none=True)


async def _call_sandbox_tools(
    route: CustomerRoute,
    calls: list[tuple[str, dict[str, Any]]],
) -> list[dict[str, Any]]:
    endpoint = route.python_mcp_url
    token = route.python_token

    timeout = httpx.Timeout(
        SANDBOX_REQUEST_TIMEOUT_SECONDS,
        connect=10,
        read=SANDBOX_SSE_TIMEOUT_SECONDS,
        write=30,
        pool=10,
    )
    headers = {
        "Authorization": f"Bearer {token}",
        "User-Agent": "state-street-tenant-aware-broker/1.0",
    }
    LOGGER.info(
        "sandbox_route_started customer_id=%s sandbox_type=python tools=%s",
        route.customer_id,
        ",".join(name for name, _ in calls),
    )
    async with SANDBOX_CALL_LIMIT:
        async with httpx.AsyncClient(
            headers=headers,
            timeout=timeout,
            follow_redirects=False,
        ) as http_client:
            async with streamable_http_client(
                endpoint,
                http_client=http_client,
            ) as (read_stream, write_stream, _):
                async with ClientSession(
                    read_stream,
                    write_stream,
                    read_timeout_seconds=timedelta(
                        seconds=SANDBOX_SSE_TIMEOUT_SECONDS
                    ),
                ) as session:
                    await session.initialize()
                    results = [
                        _result_payload(
                            await session.call_tool(
                                name,
                                arguments,
                                read_timeout_seconds=timedelta(
                                    seconds=SANDBOX_SSE_TIMEOUT_SECONDS
                                ),
                            )
                        )
                        for name, arguments in calls
                    ]
    LOGGER.info(
        "sandbox_route_completed customer_id=%s sandbox_type=python",
        route.customer_id,
    )
    return results


@mcp.tool()
async def who_am_i() -> dict[str, Any]:
    """Return non-sensitive identity claims for the OAuth proof gate."""

    claims = current_claims()
    return {
        "aud": claims["aud"],
        "azp": claims.get("azp"),
        "oid": claims["oid"],
        "scp": claims["scp"],
        "sub": claims["sub"],
        "tid": claims["tid"],
    }


@mcp.tool()
async def customer_context() -> dict[str, Any]:
    """Return the customer route selected from the validated delegated identity."""

    route = current_customer_route()
    return {
        "customer_id": route.customer_id,
        "allowed_hosts": list(route.allowed_hosts),
    }


@mcp.tool()
async def run_python(
    code: str,
    timeout_seconds: int = 30,
) -> dict[str, Any]:
    """Run Python in the Sandbox assigned to the authenticated customer."""

    if not code.strip():
        raise ValueError("code must not be empty.")
    if len(code) > 100_000:
        raise ValueError("code must be at most 100000 characters.")
    if not 1 <= timeout_seconds <= 60:
        raise ValueError("timeout_seconds must be between 1 and 60.")

    route = current_customer_route()
    results = await _call_sandbox_tools(
        route,
        [("run_python", {"code": code, "timeout_seconds": timeout_seconds})],
    )
    return results[0]


@mcp.tool()
async def search_craigslist(
    query: str,
    site: str,
    limit: int = 10,
) -> dict[str, Any]:
    """Search the customer-approved Craigslist site through its Sandbox."""

    if not query.strip():
        raise ValueError("query must not be empty.")
    if len(query) > 200:
        raise ValueError("query must be at most 200 characters.")
    if not 1 <= limit <= 20:
        raise ValueError("limit must be between 1 and 20.")

    route = current_customer_route()
    allowed_site = require_allowed_craigslist_site(site, route.allowed_hosts)
    results = await _call_sandbox_tools(
        route,
        [
            (
                "search_craigslist",
                {"query": query, "site": allowed_site, "limit": limit},
            )
        ],
    )
    return results[0]


@mcp.custom_route("/health", methods=["GET"])
async def health(_: Request) -> JSONResponse:
    return JSONResponse({"status": "ok"})


class EntraBearerMiddleware:
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
        authorization = headers.get("authorization", "")
        try:
            claims = await validated_claims(authorization)
        except JwksUnavailableError:
            body = json.dumps({"error": "service_unavailable"}).encode("utf-8")
            await send(
                {
                    "type": "http.response.start",
                    "status": 503,
                    "headers": [
                        (b"content-type", b"application/json"),
                        (b"content-length", str(len(body)).encode("ascii")),
                    ],
                }
            )
            await send(
                {
                    "type": "http.response.body",
                    "body": body,
                    "more_body": False,
                }
            )
            return
        except (jwt.PyJWTError, PermissionError, ValueError) as error:
            log_authentication_failure(
                error,
                scope.get("method", ""),
                scope.get("path", ""),
                authorization,
            )
            body = json.dumps({"error": "unauthorized"}).encode("utf-8")
            await send(
                {
                    "type": "http.response.start",
                    "status": 401,
                    "headers": [
                        (b"content-type", b"application/json"),
                        (b"content-length", str(len(body)).encode("ascii")),
                    ],
                }
            )
            await send(
                {
                    "type": "http.response.body",
                    "body": body,
                    "more_body": False,
                }
            )
            return

        context_token = _claims.set(claims)
        try:
            await self.app(scope, receive, send)
        finally:
            _claims.reset(context_token)


if __name__ == "__main__":
    app = EntraBearerMiddleware(mcp.streamable_http_app())
    uvicorn.run(
        app,
        host=mcp.settings.host,
        port=mcp.settings.port,
        log_level="info",
    )
