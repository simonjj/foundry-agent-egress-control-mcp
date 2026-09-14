import argparse
import asyncio
import json
import re
import sys
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlsplit

import requests
from azure.identity import DefaultAzureCredential
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client


PLAYWRIGHT_SCOPE = "https://playwright.microsoft.com/.default"
FOUNDRY_SCOPE = "https://ai.azure.com/.default"
MANAGEMENT_SCOPE = "https://management.azure.com/.default"
TOOLBOX_NAME = "playwright-browser-automation"
SAFE_TOOLS = {
    "browser_click",
    "browser_close",
    "browser_close_session",
    "browser_create_session",
    "browser_find",
    "browser_fill_form",
    "browser_hover",
    "browser_navigate",
    "browser_navigate_back",
    "browser_press_key",
    "browser_select_option",
    "browser_snapshot",
    "browser_tabs",
    "browser_take_screenshot",
    "browser_type",
    "browser_wait_for",
    "close_browser_session",
    "close_session",
    "create_browser_session",
    "create_session",
}
REQUIRED_TOOL_GROUPS = [
    {"browser_navigate"},
    {"browser_snapshot"},
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Configure the shared Playwright Workspace remote MCP Toolbox."
    )
    parser.add_argument("--project-resource-id", required=True)
    parser.add_argument("--project-endpoint", required=True)
    parser.add_argument("--workspace-id", required=True)
    parser.add_argument("--dataplane-uri", required=True)
    parser.add_argument("--mcp-url", required=True)
    parser.add_argument("--token-days", type=int, default=30)
    parser.add_argument("--toolbox-name", default=TOOLBOX_NAME)
    parser.add_argument("--evidence-file")
    parser.add_argument("--promote", action="store_true")
    return parser.parse_args()


def validate_args(args: argparse.Namespace) -> None:
    if not re.fullmatch(r"[0-9a-fA-F-]{36}", args.workspace_id):
        raise ValueError("workspace-id must be a GUID.")
    if not 1 <= args.token_days <= 90:
        raise ValueError("token-days must be between 1 and 90.")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{2,32}", args.toolbox_name):
        raise ValueError("toolbox-name contains unsupported characters.")

    dataplane = urlsplit(args.dataplane_uri)
    if (
        dataplane.scheme != "https"
        or not dataplane.hostname
        or not dataplane.hostname.endswith(".api.playwright.microsoft.com")
    ):
        raise ValueError("dataplane-uri must be an Azure Playwright API endpoint.")

    mcp = urlsplit(args.mcp_url)
    if (
        mcp.scheme != "https"
        or not mcp.hostname
        or not mcp.hostname.endswith(".mcp.playwright.microsoft.com")
        or not mcp.path.endswith(f"/playwrightworkspaces/{args.workspace_id}/mcp")
    ):
        raise ValueError("mcp-url does not match the Playwright workspace.")

    project = urlsplit(args.project_endpoint)
    if (
        project.scheme != "https"
        or not project.hostname
        or not project.hostname.endswith(".services.ai.azure.com")
        or "/api/projects/" not in project.path
    ):
        raise ValueError("project-endpoint must be a Microsoft Foundry project URL.")

    expected_project_id = re.compile(
        r"^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/"
        r"Microsoft\.CognitiveServices/accounts/[^/]+/projects/[^/]+$",
        re.IGNORECASE,
    )
    if not expected_project_id.fullmatch(args.project_resource_id):
        raise ValueError("project-resource-id is not a Foundry project ARM ID.")


def request_json(
    method: str,
    url: str,
    *,
    bearer_token: str,
    body: dict | None = None,
    expected: set[int],
) -> dict:
    response = requests.request(
        method,
        url,
        headers={
            "Authorization": f"Bearer {bearer_token}",
            "Accept": "application/json",
            **({"Content-Type": "application/json"} if body is not None else {}),
        },
        json=body,
        timeout=60,
    )
    if response.status_code not in expected:
        raise RuntimeError(
            f"{method} {urlsplit(url).path} failed with HTTP "
            f"{response.status_code} {response.reason}."
        )
    if not response.content:
        return {}
    return response.json()


async def list_mcp_tools(url: str, headers: dict[str, str]) -> list[str]:
    async with streamablehttp_client(url, headers=headers) as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.list_tools()
            return sorted(tool.name for tool in result.tools)


def select_allowed_tools(inventory: list[str]) -> list[str]:
    allowed = sorted(set(inventory).intersection(SAFE_TOOLS))
    for required_group in REQUIRED_TOOL_GROUPS:
        if not required_group.intersection(allowed):
            names = ", ".join(sorted(required_group))
            raise RuntimeError(
                f"Playwright MCP inventory is missing required safe tool: {names}."
            )
    return allowed


def write_evidence(
    path: str | None,
    *,
    inventory: list[str],
    allowed: list[str],
    toolbox_name: str,
    toolbox_version: str,
) -> None:
    if not path:
        return
    evidence_path = Path(path)
    evidence_path.parent.mkdir(parents=True, exist_ok=True)
    evidence_path.write_text(
        json.dumps(
            {
                "discovered_at": datetime.now(timezone.utc).isoformat(),
                "toolbox_name": toolbox_name,
                "toolbox_version": toolbox_version,
                "inventory": inventory,
                "allowed_tools": allowed,
                "denied_tools": sorted(set(inventory) - set(allowed)),
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )


async def configure(args: argparse.Namespace) -> dict[str, object]:
    validate_args(args)
    credential = DefaultAzureCredential()
    token_id = str(uuid.uuid4())
    rotation = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
    token_name = f"foundry-{rotation}"[:24]
    connection_name = f"playwright-mcp-{rotation}"[:33]
    token_url = (
        f"{args.dataplane_uri.rstrip('/')}/playwrightworkspaces/"
        f"{args.workspace_id}/access-tokens/{token_id}?api-version=2025-09-01"
    )
    connection_url = (
        "https://management.azure.com"
        f"{args.project_resource_id}/connections/{connection_name}"
        "?api-version=2025-06-01"
    )
    access_token = None
    playwright_bearer = None
    management_bearer = None
    connection_created = False
    completed = False

    try:
        playwright_bearer = credential.get_token(PLAYWRIGHT_SCOPE).token
        expiry = datetime.now(timezone.utc) + timedelta(days=args.token_days)
        token_result = request_json(
            "PUT",
            token_url,
            bearer_token=playwright_bearer,
            body={
                "name": token_name,
                "expiryAt": expiry.isoformat().replace("+00:00", "Z"),
            },
            expected={200, 201},
        )
        access_token = token_result.pop("jwtToken", None)
        if not access_token:
            raise RuntimeError("Playwright token creation returned no jwtToken.")

        inventory = await list_mcp_tools(
            args.mcp_url,
            {"x-api-key": access_token},
        )
        allowed_tools = select_allowed_tools(inventory)

        management_bearer = credential.get_token(MANAGEMENT_SCOPE).token
        connection_result = request_json(
            "PUT",
            connection_url,
            bearer_token=management_bearer,
            body={
                "properties": {
                    "authType": "CustomKeys",
                    "category": "RemoteTool",
                    "credentials": {"keys": {"x-api-key": access_token}},
                    "isSharedToAll": False,
                    "metadata": {"type": "generic_mcp"},
                    "target": args.mcp_url,
                }
            },
            expected={200, 201},
        )
        connection_created = True
        if access_token in json.dumps(connection_result):
            raise RuntimeError("Foundry connection response exposed credentials.")
        connection_id = connection_result.get("id")
        if not connection_id:
            raise RuntimeError("Foundry connection creation returned no resource ID.")

        foundry_bearer = credential.get_token(FOUNDRY_SCOPE).token
        toolbox_url = (
            f"{args.project_endpoint.rstrip('/')}/toolboxes/"
            f"{args.toolbox_name}/versions?api-version=v1"
        )
        toolbox = request_json(
            "POST",
            toolbox_url,
            bearer_token=foundry_bearer,
            body={
                "description": (
                    "Curated shared Playwright Workspace remote MCP tools."
                ),
                "tools": [
                    {
                        "type": "mcp",
                        "server_label": "playwright",
                        "server_url": args.mcp_url,
                        "project_connection_id": connection_id,
                        "allowed_tools": allowed_tools,
                        "require_approval": "always",
                    }
                ],
            },
            expected={200, 201},
        )
        version = str(toolbox.get("version") or "")
        if not version:
            raise RuntimeError("Toolbox creation returned no version.")

        canary_url = (
            f"{args.project_endpoint.rstrip('/')}/toolboxes/{args.toolbox_name}"
            f"/versions/{version}/mcp?api-version=v1"
        )
        canary_tools = await list_mcp_tools(
            canary_url,
            {"Authorization": f"Bearer {foundry_bearer}"},
        )
        expected_suffixes = {f"playwright___{name}" for name in allowed_tools}
        if not expected_suffixes.issubset(set(canary_tools)):
            missing = sorted(expected_suffixes - set(canary_tools))
            raise RuntimeError(
                "Toolbox canary is missing expected tools: " + ", ".join(missing)
            )

        if args.promote:
            request_json(
                "PATCH",
                (
                    f"{args.project_endpoint.rstrip('/')}/toolboxes/"
                    f"{args.toolbox_name}?api-version=v1"
                ),
                bearer_token=foundry_bearer,
                body={"default_version": version},
                expected={200},
            )

        write_evidence(
            args.evidence_file,
            inventory=inventory,
            allowed=allowed_tools,
            toolbox_name=args.toolbox_name,
            toolbox_version=version,
        )
        completed = True
        return {
            "connection_name": connection_name,
            "connection_id": connection_id,
            "toolbox_name": args.toolbox_name,
            "toolbox_version": version,
            "toolbox_endpoint": (
                f"{args.project_endpoint.rstrip('/')}/toolboxes/"
                f"{args.toolbox_name}/mcp?api-version=v1"
            ),
            "canary_endpoint": canary_url,
            "allowed_tools": [
                f"playwright___{name}" for name in allowed_tools
            ],
            "promoted": args.promote,
        }
    except Exception:
        cleanup_errors: list[str] = []
        if connection_created and management_bearer:
            try:
                request_json(
                    "DELETE",
                    connection_url,
                    bearer_token=management_bearer,
                    expected={200, 202, 204},
                )
            except Exception as error:
                cleanup_errors.append(f"connection cleanup failed: {error}")
        if playwright_bearer:
            try:
                request_json(
                    "DELETE",
                    token_url,
                    bearer_token=playwright_bearer,
                    expected={200, 202, 204},
                )
            except Exception as error:
                cleanup_errors.append(f"token cleanup failed: {error}")
        if cleanup_errors:
            print("; ".join(cleanup_errors), file=sys.stderr)
        raise
    finally:
        if completed:
            playwright_bearer = None
            management_bearer = None
        access_token = None
        credential.close()


def main() -> None:
    result = asyncio.run(configure(parse_args()))
    print(json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    main()
