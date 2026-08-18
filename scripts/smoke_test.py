import json
import os
import urllib.error
import urllib.request
from typing import Any


def rpc_call(method: str, params: dict[str, Any] | None, request_id: int) -> Any:
    payload: dict[str, Any] = {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": method,
    }
    if params is not None:
        payload["params"] = params

    url = os.environ["MCP_SERVER_URL"]
    token = os.environ["MCP_AUTH_TOKEN"]
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            body = response.read().decode("utf-8")
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"MCP request failed with HTTP {error.code}: {detail}") from error

    if body.startswith("event:"):
        data_lines = [
            line.removeprefix("data:").strip()
            for line in body.splitlines()
            if line.startswith("data:")
        ]
        if not data_lines:
            raise RuntimeError(f"MCP SSE response contained no data: {body}")
        body = data_lines[-1]

    message = json.loads(body)
    if "error" in message:
        raise RuntimeError(f"MCP error response: {message['error']}")
    return message["result"]


def main() -> None:
    initialization = rpc_call(
        "initialize",
        {
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": {"name": "deployment-smoke-test", "version": "1.0.0"},
        },
        1,
    )
    if not initialization.get("serverInfo"):
        raise RuntimeError(f"Invalid MCP initialize response: {initialization}")

    tools = rpc_call("tools/list", {}, 2)
    names = {tool["name"] for tool in tools["tools"]}
    if "run_python" not in names:
        raise RuntimeError(f"run_python was not advertised. Tools: {sorted(names)}")

    result = rpc_call(
        "tools/call",
        {
            "name": "run_python",
            "arguments": {"code": "print(sum([2, 3, 5]))", "timeout_seconds": 10},
        },
        3,
    )
    text = "\n".join(
        item["text"] for item in result.get("content", []) if item.get("type") == "text"
    )
    if '"stdout": "10\\n"' not in text:
        raise RuntimeError(f"Unexpected interpreter result: {text}")

    print("MCP smoke test passed.")


if __name__ == "__main__":
    main()
