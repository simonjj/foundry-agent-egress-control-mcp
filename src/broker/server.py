import asyncio
import contextvars
import json
import os
from collections.abc import Awaitable, Callable
from typing import Any

import jwt
import uvicorn
from jwt import PyJWKClient
from jwt.exceptions import (
    InvalidAlgorithmError,
    InvalidTokenError,
)
from mcp.server.fastmcp import FastMCP
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
        raise PermissionError("A bearer token is required.")

    token = authorization.removeprefix("Bearer ").strip()
    if not token or len(token) > 8192:
        raise PermissionError("The bearer token is invalid.")

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
        try:
            claims = await validated_claims(headers.get("authorization", ""))
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
            del error
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
