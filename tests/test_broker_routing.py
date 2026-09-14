import json
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch


BROKER_SOURCE = Path(__file__).resolve().parents[1] / "src" / "broker"
sys.path.insert(0, str(BROKER_SOURCE))

from routing import (  # noqa: E402
    CustomerRouter,
    CustomerRoutingConfigurationError,
    identity_key,
    require_allowed_craigslist_site,
)


class CustomerRoutingTests(unittest.TestCase):
    def _environment(self) -> dict[str, str]:
        key = identity_key("tenant-id", "object-id")
        return {
            "CUSTOMER_ENTITLEMENTS_JSON": json.dumps(
                {key: "customer-personal"}
            ),
            "CUSTOMER_ROUTES_JSON": json.dumps(
                {
                    "customer-personal": {
                        "python_mcp_url": "https://python.example.test/mcp",
                        "python_token_env": "PYTHON_TOKEN",
                        "allowed_hosts": [
                            "seattle.craigslist.org",
                            "www.craigslist.org",
                        ],
                    }
                }
            ),
            "PYTHON_TOKEN": "python-secret",
        }

    def test_resolves_validated_identity_to_customer_route(self) -> None:
        with patch.dict(os.environ, self._environment(), clear=True):
            route = CustomerRouter.from_environment().resolve(
                {"tid": "tenant-id", "oid": "object-id"}
            )

        self.assertEqual(route.customer_id, "customer-personal")
        self.assertEqual(
            route.allowed_hosts,
            ("seattle.craigslist.org", "www.craigslist.org"),
        )
        self.assertNotIn("python-secret", repr(route))

    def test_rejects_unentitled_identity(self) -> None:
        with patch.dict(os.environ, self._environment(), clear=True):
            router = CustomerRouter.from_environment()
            with self.assertRaises(PermissionError):
                router.resolve({"tid": "tenant-id", "oid": "different-user"})

    def test_rejects_entitlement_without_route(self) -> None:
        environment = self._environment()
        environment["CUSTOMER_ROUTES_JSON"] = "{}"
        with patch.dict(os.environ, environment, clear=True):
            with self.assertRaises(CustomerRoutingConfigurationError):
                CustomerRouter.from_environment()

    def test_enforces_customer_host_allowlist(self) -> None:
        allowed_hosts = (
            "seattle.craigslist.org",
            "www.craigslist.org",
        )

        self.assertEqual(
            require_allowed_craigslist_site("Seattle", allowed_hosts),
            "seattle",
        )
        with self.assertRaises(PermissionError):
            require_allowed_craigslist_site("houston", allowed_hosts)


if __name__ == "__main__":
    unittest.main()
