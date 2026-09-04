import json
import sys

from azure.containerapps.sandbox import SandboxGroupClient, endpoint_for_region
from azure.identity import DefaultAzureCredential


def main() -> None:
    query = json.load(sys.stdin)
    labels = {
        "application": query["application"],
        "component": query["component"],
        "version": query["image_tag"],
        "token_fingerprint": query["token_fingerprint"],
    }
    client = SandboxGroupClient(
        endpoint_for_region(query["location"]),
        DefaultAzureCredential(),
        subscription_id=query["subscription_id"],
        resource_group=query["resource_group"],
        sandbox_group=query["sandbox_group_name"],
    )
    sandboxes = list(client.list_sandboxes(labels=labels))
    if not sandboxes:
        raise RuntimeError(
            f"No {query['component']} Sandbox exists for image {query['image_tag']}."
        )
    sandbox = client.get_sandbox(sandboxes[0].id)
    port = next(
        (item for item in sandbox.ports if item.port == int(query["port"])),
        None,
    )
    if port is None or not port.url:
        raise RuntimeError(
            f"Sandbox {sandbox.id} does not expose port {query['port']}."
        )
    base_url = port.url
    if not base_url.startswith("http"):
        base_url = f"https://{base_url}"
    base_url = base_url.rstrip("/")
    print(
        json.dumps(
            {
                "sandbox_id": str(sandbox.id),
                "mcp_url": f"{base_url}/mcp",
                "health_url": f"{base_url}/health",
                "customer_vnet_connection_name": str(
                    sandbox.customer_vnet_connection_name or ""
                ),
            }
        )
    )


if __name__ == "__main__":
    main()
