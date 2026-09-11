import sys
import unittest
from pathlib import Path
from unittest.mock import patch

from jwt.exceptions import InvalidAudienceError

BROKER_SOURCE = Path(__file__).resolve().parents[1] / "src" / "broker"
sys.path.insert(0, str(BROKER_SOURCE))

from auth_diagnostics import (  # noqa: E402
    AUTH_LOGGER,
    authentication_failure_code,
    log_authentication_failure,
)


class AuthenticationDiagnosticsTests(unittest.TestCase):
    def test_classifies_invalid_audience(self) -> None:
        self.assertEqual(
            authentication_failure_code(InvalidAudienceError("sensitive")),
            "invalid_audience",
        )

    def test_logs_category_without_logging_token(self) -> None:
        token = "must-not-appear-in-logs"
        with patch.object(AUTH_LOGGER, "warning") as warning:
            log_authentication_failure(
                InvalidAudienceError("sensitive"),
                "POST",
                "/mcp",
                f"Bearer {token}",
            )

        self.assertEqual(warning.call_args.args[1], "invalid_audience")
        self.assertTrue(warning.call_args.args[4])
        self.assertTrue(warning.call_args.args[5])
        self.assertNotIn(token, repr(warning.call_args))


if __name__ == "__main__":
    unittest.main()
