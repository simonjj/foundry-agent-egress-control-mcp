import hashlib
import json
import os
import re
from dataclasses import dataclass, field
from typing import Any, Mapping
from urllib.parse import urlsplit


IDENTITY_KEY_PATTERN = re.compile(r"^[0-9a-f]{64}$")
CUSTOMER_ID_PATTERN = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")
HOST_PATTERN = re.compile(
    r"^(?:\*\.)?(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+"
    r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"
)
SITE_PATTERN = re.compile(r"^[a-z0-9-]{1,40}$")


class CustomerRoutingConfigurationError(RuntimeError):
    pass


@dataclass(frozen=True)
class CustomerRoute:
    customer_id: str
    python_mcp_url: str
    python_token: str = field(repr=False)
    allowed_hosts: tuple[str, ...]


def identity_key(tenant_id: str, object_id: str) -> str:
    if not tenant_id or not object_id:
        raise PermissionError(
            "The delegated identity is missing tenant or object identifiers."
        )
    return hashlib.sha256(f"{tenant_id}:{object_id}".encode()).hexdigest()


def _json_object(value: str, name: str) -> dict[str, Any]:
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as error:
        raise CustomerRoutingConfigurationError(
            f"{name} must contain valid JSON."
        ) from error
    if not isinstance(parsed, dict):
        raise CustomerRoutingConfigurationError(
            f"{name} must contain a JSON object."
        )
    return parsed


def _https_mcp_url(value: Any, name: str) -> str:
    if not isinstance(value, str):
        raise CustomerRoutingConfigurationError(f"{name} must be a string.")
    parsed = urlsplit(value)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
        or parsed.path.rstrip("/") != "/mcp"
    ):
        raise CustomerRoutingConfigurationError(
            f"{name} must be an absolute HTTPS MCP endpoint."
        )
    return value.rstrip("/")


def _allowed_hosts(value: Any, name: str) -> tuple[str, ...]:
    if not isinstance(value, list) or not value:
        raise CustomerRoutingConfigurationError(
            f"{name} must be a non-empty JSON array."
        )

    hosts: list[str] = []
    for item in value:
        if not isinstance(item, str):
            raise CustomerRoutingConfigurationError(
                f"{name} entries must be strings."
            )
        host = item.rstrip(".").lower()
        if not HOST_PATTERN.fullmatch(host):
            raise CustomerRoutingConfigurationError(
                f"{name} contains an invalid host pattern."
            )
        hosts.append(host)
    return tuple(dict.fromkeys(hosts))


def host_is_allowed(host: str, allowed_hosts: tuple[str, ...]) -> bool:
    normalized = host.rstrip(".").lower()
    for allowed in allowed_hosts:
        if allowed.startswith("*."):
            suffix = allowed[1:]
            if normalized.endswith(suffix) and normalized != suffix[1:]:
                return True
        elif normalized == allowed:
            return True
    return False


def require_allowed_https_url(url: str, allowed_hosts: tuple[str, ...]) -> str:
    parsed = urlsplit(url)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username
        or parsed.password
        or parsed.port not in {None, 443}
    ):
        raise ValueError("url must be an absolute HTTPS URL without credentials.")
    if not host_is_allowed(parsed.hostname, allowed_hosts):
        raise PermissionError("The requested host is not allowed for this customer.")
    return url


def require_allowed_craigslist_site(
    site: str,
    allowed_hosts: tuple[str, ...],
) -> str:
    normalized = site.strip().lower()
    if not SITE_PATTERN.fullmatch(normalized):
        raise ValueError(
            "site must be a Craigslist subdomain such as 'seattle'."
        )
    host = f"{normalized}.craigslist.org"
    if not host_is_allowed(host, allowed_hosts):
        raise PermissionError(
            "The requested Craigslist site is not allowed for this customer."
        )
    return normalized


class CustomerRouter:
    def __init__(
        self,
        entitlements: Mapping[str, str],
        routes: Mapping[str, CustomerRoute],
    ) -> None:
        self._entitlements = dict(entitlements)
        self._routes = dict(routes)

    @classmethod
    def from_environment(cls) -> "CustomerRouter":
        entitlements_raw = _json_object(
            os.getenv("CUSTOMER_ENTITLEMENTS_JSON", "{}"),
            "CUSTOMER_ENTITLEMENTS_JSON",
        )
        routes_raw = _json_object(
            os.getenv("CUSTOMER_ROUTES_JSON", "{}"),
            "CUSTOMER_ROUTES_JSON",
        )

        entitlements: dict[str, str] = {}
        for key, customer_id in entitlements_raw.items():
            if (
                not isinstance(key, str)
                or not IDENTITY_KEY_PATTERN.fullmatch(key)
                or not isinstance(customer_id, str)
                or not CUSTOMER_ID_PATTERN.fullmatch(customer_id)
            ):
                raise CustomerRoutingConfigurationError(
                    "Customer entitlements contain an invalid identity key or "
                    "customer ID."
                )
            entitlements[key] = customer_id

        routes: dict[str, CustomerRoute] = {}
        for customer_id, route_raw in routes_raw.items():
            if (
                not isinstance(customer_id, str)
                or not CUSTOMER_ID_PATTERN.fullmatch(customer_id)
                or not isinstance(route_raw, dict)
            ):
                raise CustomerRoutingConfigurationError(
                    "Customer routes contain an invalid customer entry."
                )

            python_token_env = route_raw.get("python_token_env")
            if not isinstance(python_token_env, str) or not python_token_env:
                raise CustomerRoutingConfigurationError(
                    "python_token_env must name an environment variable."
                )
            python_token = os.getenv(python_token_env)
            if not python_token:
                raise CustomerRoutingConfigurationError(
                    f"Sandbox credentials are missing for customer {customer_id}."
                )

            routes[customer_id] = CustomerRoute(
                customer_id=customer_id,
                python_mcp_url=_https_mcp_url(
                    route_raw.get("python_mcp_url"),
                    "python_mcp_url",
                ),
                python_token=python_token,
                allowed_hosts=_allowed_hosts(
                    route_raw.get("allowed_hosts"),
                    "allowed_hosts",
                ),
            )

        missing_routes = set(entitlements.values()) - set(routes)
        if missing_routes:
            raise CustomerRoutingConfigurationError(
                "Every entitled customer must have a configured route."
            )
        return cls(entitlements, routes)

    def resolve(self, claims: Mapping[str, Any]) -> CustomerRoute:
        key = identity_key(
            str(claims.get("tid", "")),
            str(claims.get("oid", "")),
        )
        customer_id = self._entitlements.get(key)
        if customer_id is None:
            raise PermissionError(
                "The authenticated user is not entitled to a customer tool route."
            )
        route = self._routes.get(customer_id)
        if route is None:
            raise CustomerRoutingConfigurationError(
                "The entitled customer route is not configured."
            )
        return route
