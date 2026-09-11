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


def toolbox_allowed_tools() -> list[str] | None:
    configured = os.getenv("TOOLBOX_ALLOWED_TOOLS", "who_am_i").strip()
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

    tools = [mcp_tool]
    browser_mode = "playwright-workspace"
    browser_mcp_url = os.getenv("BROWSER_MCP_SERVER_URL")
    browser_mcp_token = os.getenv("BROWSER_MCP_AUTH_TOKEN")
    if browser_mcp_url or browser_mcp_token:
        if not browser_mcp_url or not browser_mcp_token:
            raise RuntimeError(
                "BROWSER_MCP_SERVER_URL and BROWSER_MCP_AUTH_TOKEN must be "
                "set together."
            )
        tools.append(
            MCPStreamableHTTPTool(
                name="sandbox_browser",
                description=(
                    "Private Playwright browser automation hosted in ACA Sandbox."
                ),
                url=browser_mcp_url,
                allowed_tools=[
                    "browser_navigate",
                    "browser_snapshot",
                    "browser_tabs",
                ],
                header_provider=lambda _kwargs: {
                    "Authorization": f"Bearer {browser_mcp_token}"
                },
                approval_mode="never_require",
                load_prompts=False,
                request_timeout=120,
                sse_read_timeout=180,
            )
        )
        browser_mode = "aca-sandbox-mcp"
    else:
        tools.append(
            FoundryChatClient.get_browser_automation_tool(
                connection_id=required_environment("PLAYWRIGHT_CONNECTION_ID")
            ).as_dict()
        )

    if environment_enabled("ENABLE_FOUNDRY_WEB_SEARCH", True):
        tools.append(
            FoundryChatClient.get_web_search_tool(search_context_size="medium")
        )

    return tools, browser_mode


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
    toolbox_endpoint = os.getenv("TOOLBOX_ENDPOINT")
    if diagnostic_endpoint:
        tools = [diagnose_broker_network]
        browser_mode = "broker-network-diagnostic"
        primary_tool_name = "diagnose_broker_network"
    elif toolbox_endpoint:
        tools = LoggedFoundryToolbox(
            credential,
            url=toolbox_endpoint,
            name=os.getenv("TOOLBOX_NAME") or "tenant_broker",
            allowed_tools=toolbox_allowed_tools(),
            approval_mode="never_require",
            load_prompts=False,
            request_timeout=120,
            sse_read_timeout=180,
        )
        browser_mode = "tenant-broker-toolbox"
        primary_tool_name = "tenant_broker"
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
