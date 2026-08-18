import asyncio
import os
import signal
import subprocess
import sys
import tempfile
from collections.abc import Mapping
from pathlib import Path
from typing import Any

MAX_CODE_BYTES = 100_000
MAX_OUTPUT_BYTES = 64_000
MAX_TIMEOUT_SECONDS = 60

_INHERITED_ENVIRONMENT = {
    "LANG",
    "LC_ALL",
    "PATH",
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "NO_PROXY",
    "REQUESTS_CA_BUNDLE",
    "SSL_CERT_FILE",
}


def _execution_environment(
    working_directory: Path,
    source: Mapping[str, str] | None = None,
) -> dict[str, str]:
    source = source or os.environ
    environment = {
        key: value for key, value in source.items() if key in _INHERITED_ENVIRONMENT
    }
    environment.update(
        {
            "HOME": str(working_directory),
            "TMPDIR": str(working_directory),
            "PYTHONUNBUFFERED": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
        }
    )
    return environment


def _set_resource_limits(timeout_seconds: int) -> None:
    import resource

    memory_bytes = 2 * 1024 * 1024 * 1024
    resource.setrlimit(resource.RLIMIT_AS, (memory_bytes, memory_bytes))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_CPU, (timeout_seconds + 1, timeout_seconds + 1))
    resource.setrlimit(resource.RLIMIT_FSIZE, (50 * 1024 * 1024, 50 * 1024 * 1024))
    resource.setrlimit(resource.RLIMIT_NOFILE, (128, 128))
    if hasattr(resource, "RLIMIT_NPROC"):
        resource.setrlimit(resource.RLIMIT_NPROC, (64, 64))


def _truncate(value: str) -> tuple[str, bool]:
    encoded = value.encode("utf-8", errors="replace")
    if len(encoded) <= MAX_OUTPUT_BYTES:
        return value, False
    truncated = encoded[:MAX_OUTPUT_BYTES].decode("utf-8", errors="ignore")
    return f"{truncated}\n...[output truncated]", True


def _execute(code: str, timeout_seconds: int) -> dict[str, Any]:
    if not code.strip():
        raise ValueError("code must not be empty")
    if len(code.encode("utf-8")) > MAX_CODE_BYTES:
        raise ValueError(f"code must be at most {MAX_CODE_BYTES} bytes")
    if not 1 <= timeout_seconds <= MAX_TIMEOUT_SECONDS:
        raise ValueError(
            f"timeout_seconds must be between 1 and {MAX_TIMEOUT_SECONDS}"
        )

    with tempfile.TemporaryDirectory(prefix="python-exec-") as temp_directory:
        workdir = Path(temp_directory)
        script_path = workdir / "main.py"
        script_path.write_text(code, encoding="utf-8")

        process_args: dict[str, Any] = {
            "args": [sys.executable, "-I", "-u", str(script_path)],
            "cwd": workdir,
            "env": _execution_environment(workdir),
            "stdout": subprocess.PIPE,
            "stderr": subprocess.PIPE,
            "text": True,
            "start_new_session": True,
        }
        if os.name == "posix":
            process_args["preexec_fn"] = lambda: _set_resource_limits(timeout_seconds)

        process = subprocess.Popen(**process_args)
        timed_out = False
        try:
            stdout, stderr = process.communicate(timeout=timeout_seconds)
        except subprocess.TimeoutExpired:
            timed_out = True
            if os.name == "posix":
                os.killpg(process.pid, signal.SIGKILL)
            else:
                process.kill()
            stdout, stderr = process.communicate()

        stdout, stdout_truncated = _truncate(stdout)
        stderr, stderr_truncated = _truncate(stderr)
        return {
            "exit_code": process.returncode,
            "timed_out": timed_out,
            "stdout": stdout,
            "stderr": stderr,
            "output_truncated": stdout_truncated or stderr_truncated,
        }


async def execute_python(code: str, timeout_seconds: int = 30) -> dict[str, Any]:
    return await asyncio.to_thread(_execute, code, timeout_seconds)

