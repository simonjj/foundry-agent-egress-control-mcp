import asyncio
import logging
import os
import socket
import urllib.error
import urllib.request
from urllib.parse import urlparse

from agent_framework import Agent, MCPStreamableHTTPTool, tool
from agent_framework.foundry import FoundryChatClient
from agent_framework.observability import enable_instrumentation, get_tracer
from agent_framework_foundry_hosting import FoundryToolbox, ResponsesHostServer
from azure.identity import DefaultAzureCredential
from dotenv import load_dotenv

load_dotenv()
logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
logger = logging.getLogger(__name__)


class LoggedFoundryToolbox(FoundryToolbox):
    async def connect(self, *, reset: bool = False) -> None:
        await super().connect(reset=reset)
        exposed_tools = ",".join(function.name for function in self.functions)
        logger.info(
            "Foundry Toolbox exposed tools=%s",
            exposed_tools or "(none)",
        )


def required_environment(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise RuntimeError(f"Required environment variable {name} is not set.")
    return value


def environment_enabled(name: str, default: bool) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.lower() in {"1", "true", "yes"}


def configured_toolbox_tools(
    variable_name: str,
    default: str | None = None,
) -> list[str] | None:
    configured = os.getenv(variable_name, default)
    if configured is None:
        return None
    configured = configured.strip()
    if configured == "*":
        return None
    return [name.strip() for name in configured.split(",") if name.strip()]


@tool(approval_mode="never_require")
async def diagnose_broker_network() -> dict[str, object]:
    """Resolve and call the configured private broker health endpoint."""

    endpoint = required_environment("BROKER_NETWORK_DIAGNOSTIC_URL")
    parsed = urlparse(endpoint)
    if parsed.scheme != "https" or not parsed.hostname:
        raise RuntimeError(
            "BROKER_NETWORK_DIAGNOSTIC_URL must be an absolute HTTPS URL."
        )

    port = parsed.port or 443
    try:
        address_info = await asyncio.to_thread(
            socket.getaddrinfo,
            parsed.hostname,
            port,
            type=socket.SOCK_STREAM,
        )
    except socket.gaierror as exc:
        return {
            "endpoint": endpoint,
            "hostname": parsed.hostname,
            "stage": "dns",
            "error": str(exc),
        }

    addresses = sorted({entry[4][0] for entry in address_info})
    request = urllib.request.Request(
        endpoint,
        headers={"User-Agent": "foundry-agent-network-diagnostic/1.0"},
    )
    try:
        response = await asyncio.to_thread(
            urllib.request.urlopen,
            request,
            None,
            20,
        )
        with response:
            body = response.read(512).decode("utf-8", errors="replace")
            return {
                "endpoint": endpoint,
                "hostname": parsed.hostname,
                "resolved_addresses": addresses,
                "http_status": response.status,
                "body": body,
                "stage": "complete",
            }
    except urllib.error.HTTPError as exc:
        body = exc.read(512).decode("utf-8", errors="replace")
        return {
            "endpoint": endpoint,
            "hostname": parsed.hostname,
            "resolved_addresses": addresses,
            "http_status": exc.code,
            "body": body,
            "stage": "http",
        }
    except (urllib.error.URLError, TimeoutError) as exc:
        return {
            "endpoint": endpoint,
            "hostname": parsed.hostname,
            "resolved_addresses": addresses,
            "stage": "https",
            "error": str(exc),
        }


def build_direct_tools():
    mcp_token = required_environment("MCP_AUTH_TOKEN")
    allowed_python_tools = ["run_python"]
    if environment_enabled("ENABLE_SANDBOX_SEARCH", False):
        allowed_python_tools.append("search_craigslist")

    mcp_tool = MCPStreamableHTTPTool(
        name="sandbox_python",
        description=(
            "An isolated Python 3.12 interpreter and optional Craigslist search "
            "service with network access restricted by ACA Sandbox policy."
        ),
        url=required_environment("MCP_SERVER_URL"),
        header_provider=lambda _kwargs: {
            "Authorization": f"Bearer {mcp_token}"
        },
        allowed_tools=allowed_python_tools,
        approval_mode="never_require",
        load_prompts=False,
        request_timeout=90,
        sse_read_timeout=120,
    )

    tools = [
        mcp_tool,
        FoundryChatClient.get_browser_automation_tool(
            connection_id=required_environment("PLAYWRIGHT_CONNECTION_ID")
        ).as_dict(),
    ]

    if environment_enabled("ENABLE_FOUNDRY_WEB_SEARCH", True):
        tools.append(
            FoundryChatClient.get_web_search_tool(search_context_size="medium")
        )

    return tools, "playwright-workspace"


async def main() -> None:
    sensitive_data_enabled = environment_enabled("ENABLE_SENSITIVE_DATA", False)
    enable_instrumentation(enable_sensitive_data=sensitive_data_enabled)

    credential = DefaultAzureCredential()
    model_name = os.getenv("AZURE_AI_MODEL_DEPLOYMENT_NAME") or os.getenv(
        "FOUNDRY_MODEL_NAME"
    )
    if not model_name:
        raise RuntimeError(
            "Set AZURE_AI_MODEL_DEPLOYMENT_NAME or FOUNDRY_MODEL_NAME."
        )

    project_endpoint = (
        os.getenv("PRIVATE_FOUNDRY_GATEWAY_ENDPOINT")
        or os.getenv("FOUNDRY_GATEWAY_ENDPOINT")
        or required_environment("APIM_FOUNDRY_PROJECT_ENDPOINT")
    )
    client_options = {
        "project_endpoint": project_endpoint,
        "model": model_name,
        "credential": credential,
        "allow_preview": True,
    }
    gateway_key = os.getenv("APIM_SUBSCRIPTION_KEY")
    if gateway_key:
        client_options["default_headers"] = {
            "Ocp-Apim-Subscription-Key": gateway_key
        }
    client = FoundryChatClient(**client_options)

    diagnostic_endpoint = os.getenv("BROKER_NETWORK_DIAGNOSTIC_URL")
    tenant_toolbox_endpoint = (
        os.getenv("TENANT_BROKER_TOOLBOX_ENDPOINT")
        or os.getenv("TOOLBOX_ENDPOINT")
    )
    playwright_toolbox_endpoint = os.getenv("PLAYWRIGHT_TOOLBOX_ENDPOINT")
    if diagnostic_endpoint:
        tools = [diagnose_broker_network]
        browser_mode = "broker-network-diagnostic"
        primary_tool_name = "diagnose_broker_network"
    elif tenant_toolbox_endpoint or playwright_toolbox_endpoint:
        tools = []
        toolbox_modes = []
        if tenant_toolbox_endpoint:
            tools.append(
                LoggedFoundryToolbox(
                    credential,
                    url=tenant_toolbox_endpoint,
                    name=os.getenv("TOOLBOX_NAME") or "tenant_broker",
                    allowed_tools=configured_toolbox_tools(
                        "TENANT_BROKER_TOOLBOX_ALLOWED_TOOLS",
                        os.getenv("TOOLBOX_ALLOWED_TOOLS", "who_am_i"),
                    ),
                    approval_mode="never_require",
                    load_prompts=False,
                    request_timeout=120,
                    sse_read_timeout=180,
                )
            )
            toolbox_modes.append("tenant-broker")
        if playwright_toolbox_endpoint:
            playwright_allowed_tools = configured_toolbox_tools(
                "PLAYWRIGHT_TOOLBOX_ALLOWED_TOOLS"
            )
            if not playwright_allowed_tools:
                raise RuntimeError(
                    "PLAYWRIGHT_TOOLBOX_ALLOWED_TOOLS must contain the exact "
                    "curated Playwright Toolbox tool names."
                )
            tools.append(
                LoggedFoundryToolbox(
                    credential,
                    url=playwright_toolbox_endpoint,
                    name="playwright_browser",
                    allowed_tools=playwright_allowed_tools,
                    approval_mode="always_require",
                    load_prompts=False,
                    request_timeout=120,
                    sse_read_timeout=180,
                )
            )
            toolbox_modes.append("playwright-workspace")
        browser_mode = "+".join(toolbox_modes) + "-toolbox"
        primary_tool_name = "+".join(toolbox_modes)
    else:
        tools, browser_mode = build_direct_tools()
        primary_tool_name = "sandbox_python"

    instructions = """\
You demonstrate a governed enterprise agent architecture by helping users find,
inspect, and compare current Craigslist listings.

Use the available governed tools for public-web discovery, browser inspection,
Python calculations, and structured analysis. When customer_context is
available, call it before customer tools and use only the customer-approved
hosts it returns. When a who_am_i tool is available, use it only for explicit
identity diagnostics and never repeat raw object or subject identifiers. When
diagnose_broker_network is available, call it immediately and report its exact
DNS addresses, HTTP status, and diagnostic stage.

Use tenant broker tools for customer context, Python, and Craigslist search.
Use Playwright Workspace tools only for browser rendering and interaction.
Create a new browser session before browser operations and close it when the
browser task is complete. Never reuse a browser session across requests or
conversations. Every Playwright tool call requires explicit user approval;
never bypass, batch, or infer approval. Report session cleanup failures.

Always include the URLs of listings used in the answer. Clearly distinguish
search or listing claims from your own calculations. Browser automation is
read-only: never sign in, enter credentials, contact a seller, submit a form,
book, bid, or make a purchase. Never invent a listing. If a site blocks access
or there are too few results, explain that limitation rather than fabricating
data.
"""

    with get_tracer().start_as_current_span("configure_craigslist_agent") as span:
        span.set_attribute("gen_ai.agent.name", "craigslist-agent")
        span.set_attribute("agent.tool.name", primary_tool_name)
        span.set_attribute(
            "agent.gateway",
            (
                "nginx-private"
                if os.getenv("PRIVATE_FOUNDRY_GATEWAY_ENDPOINT")
                or os.getenv("FOUNDRY_GATEWAY_ENDPOINT")
                else "apim"
            ),
        )
        span.set_attribute("agent.browser.mode", browser_mode)
        span.set_attribute("agent.sensitive_telemetry_enabled", sensitive_data_enabled)
        agent = Agent(
            client=client,
            name="craigslist-agent",
            instructions=instructions,
            tools=tools,
            default_options={"store": False},
        )

    logger.info(
        "Starting hosted agent with OpenTelemetry instrumentation; "
        "sensitive telemetry enabled=%s",
        sensitive_data_enabled,
    )
    server = ResponsesHostServer(agent)
    await server.run_async()


if __name__ == "__main__":
    asyncio.run(main())
