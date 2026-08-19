import asyncio
import logging
import os

from agent_framework import Agent, MCPStreamableHTTPTool
from agent_framework.foundry import FoundryChatClient
from agent_framework.observability import enable_instrumentation, get_tracer
from agent_framework_foundry_hosting import ResponsesHostServer
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


async def main() -> None:
    sensitive_data_enabled = os.getenv("ENABLE_SENSITIVE_DATA", "false").lower() in {
        "1",
        "true",
        "yes",
    }
    enable_instrumentation(enable_sensitive_data=sensitive_data_enabled)

    credential = DefaultAzureCredential()
    model_name = os.getenv("AZURE_AI_MODEL_DEPLOYMENT_NAME") or os.getenv(
        "FOUNDRY_MODEL_NAME"
    )
    if not model_name:
        raise RuntimeError(
            "Set AZURE_AI_MODEL_DEPLOYMENT_NAME or FOUNDRY_MODEL_NAME."
        )

    mcp_token = required_environment("MCP_AUTH_TOKEN")
    mcp_tool = MCPStreamableHTTPTool(
        name="sandbox_python",
        description=(
            "An isolated Python 3.12 interpreter with network access restricted "
            "by ACA Sandbox egress policy."
        ),
        url=required_environment("MCP_SERVER_URL"),
        header_provider=lambda _kwargs: {"Authorization": f"Bearer {mcp_token}"},
        allowed_tools=["run_python"],
        approval_mode="never_require",
        load_prompts=False,
        request_timeout=90,
        sse_read_timeout=120,
    )

    client = FoundryChatClient(
        project_endpoint=required_environment("FOUNDRY_PROJECT_ENDPOINT"),
        model=model_name,
        credential=credential,
    )

    instructions = """\
You help users find and compare current Craigslist listings.

For any question about current listings, use the run_python tool to retrieve
the relevant craigslist.org pages and analyze the live results. Prefer the
requests and BeautifulSoup libraries. Send a descriptive User-Agent, use
reasonable timeouts, and make only the minimum requests needed.

Always include the URLs of listings used in the answer. Clearly distinguish
listing claims from your own calculations. Never invent a listing, contact a
seller, submit a form, or make a purchase. If Craigslist blocks the request or
there are too few results, explain that limitation rather than fabricating data.
"""

    with get_tracer().start_as_current_span("configure_craigslist_agent") as span:
        span.set_attribute("gen_ai.agent.name", "craigslist-agent")
        span.set_attribute("agent.tool.name", "sandbox_python")
        span.set_attribute("agent.sensitive_telemetry_enabled", sensitive_data_enabled)
        agent = Agent(
            client=client,
            name="craigslist-agent",
            instructions=instructions,
            tools=[mcp_tool],
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
