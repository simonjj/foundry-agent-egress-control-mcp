import asyncio
import os
import sys
import unittest
from pathlib import Path

INTERPRETER_SOURCE = Path(__file__).resolve().parents[1] / "src" / "interpreter"
sys.path.insert(0, str(INTERPRETER_SOURCE))

from executor import execute_python  # noqa: E402


class ExecutePythonTests(unittest.TestCase):
    def test_returns_stdout(self) -> None:
        result = asyncio.run(execute_python("print(sum([2, 3, 5]))", 5))

        self.assertEqual(result["exit_code"], 0)
        self.assertEqual(result["stdout"], "10\n")
        self.assertEqual(result["stderr"], "")
        self.assertFalse(result["timed_out"])

    def test_removes_mcp_token_from_child_environment(self) -> None:
        previous = os.environ.get("MCP_AUTH_TOKEN")
        os.environ["MCP_AUTH_TOKEN"] = "must-not-leak"
        try:
            result = asyncio.run(
                execute_python(
                    "import os; print(os.getenv('MCP_AUTH_TOKEN', 'missing'))",
                    5,
                )
            )
        finally:
            if previous is None:
                os.environ.pop("MCP_AUTH_TOKEN", None)
            else:
                os.environ["MCP_AUTH_TOKEN"] = previous

        self.assertEqual(result["stdout"], "missing\n")

    def test_times_out_long_running_code(self) -> None:
        result = asyncio.run(
            execute_python("import time; time.sleep(5)", timeout_seconds=1)
        )

        self.assertTrue(result["timed_out"])
        self.assertNotEqual(result["exit_code"], 0)

    def test_rejects_empty_code(self) -> None:
        with self.assertRaises(ValueError):
            asyncio.run(execute_python("  ", 5))


if __name__ == "__main__":
    unittest.main()

