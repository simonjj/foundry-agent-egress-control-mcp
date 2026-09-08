import asyncio
import logging
import os

from agent_framework import Agent, MCPStreamableHTTPTool
from agent_framework.foundry import FoundryChatClient
from agent_framework.observability import enable_instrumentation, get_tracer
from agent_framework_foundry_hosting import FoundryToolbox, ResponsesHostServer
from azure.identity import DefaultAzureCredential
from dotenv import load_dotenv

load_dotenv()
logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
logger = logging.getLogger(__name__)


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

    toolbox_endpoint = os.getenv("TOOLBOX_ENDPOINT")
    if toolbox_endpoint:
        tools = FoundryToolbox(
            credential,
            url=toolbox_endpoint,
            name=os.getenv("TOOLBOX_NAME") or "tenant_broker",
            allowed_tools=["who_am_i"],
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
Python calculations, and structured analysis. When a who_am_i tool is
available, use it to demonstrate the calling user's delegated identity without
exposing raw access tokens.

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
