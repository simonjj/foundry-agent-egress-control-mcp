import argparse
import hashlib
import json
import os
import re
import subprocess
import time
from dataclasses import dataclass
from typing import Any

import requests
from azure.containerapps.sandbox import (
    AddPortRequest,
    AutoDeletePolicy,
    AutoSuspendPolicy,
    EgressHostRule,
    EgressPolicy,
    LifecyclePolicy,
    PortAuthConfig,
    SandboxGroupClient,
    endpoint_for_region,
)
from azure.identity import AzureCliCredential, DefaultAzureCredential


@dataclass(frozen=True)
class Profile:
    component: str
    entrypoint: list[str]
    environment: dict[str, str]
    allowed_hosts: list[str]


def craigslist_hosts(site: str) -> list[str]:
    return [
        "craigslist.org",
        f"{site}.craigslist.org",
        "images.craigslist.org",
        "www.craigslist.org",
    ]


def profile_for(name: str, token: str, craigslist_site: str) -> Profile:
    allowed_hosts = craigslist_hosts(craigslist_site)
    return Profile(
        component="code-interpreter",
        entrypoint=["python", "/app/server.py"],
        environment={
            "MCP_AUTH_TOKEN": token,
            "MCP_HOST": "0.0.0.0",
            "MCP_PORT": "8080",
        },
        allowed_hosts=allowed_hosts,
    )


def configuration_fingerprint(
    profile: Profile,
    vnet_connection: str,
    customer_id: str,
) -> str:
    environment = {
        key: "__sensitive__" if key == "MCP_AUTH_TOKEN" else value
        for key, value in profile.environment.items()
    }
    normalized = {
        "component": profile.component,
        "entrypoint": profile.entrypoint,
        "environment": environment,
        "resources": {"cpu": "2000m", "memory": "4096Mi"},
        "allowed_hosts": profile.allowed_hosts,
        "port": 8080,
        "customer_vnet_connection_name": vnet_connection,
        "customer_id": customer_id,
    }
    payload = json.dumps(normalized, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode()).hexdigest()[:16]


def port_urls(sandbox: Any) -> tuple[str, str]:
    for port in sandbox.ports:
        if port.port == 8080 and port.url:
            base_url = port.url
            if not base_url.startswith("http"):
                base_url = f"https://{base_url}"
            base_url = base_url.rstrip("/")
            return f"{base_url}/mcp", f"{base_url}/health"
    raise RuntimeError(f"Sandbox {sandbox.id} does not expose port 8080.")


def create_disk_image(
    client: SandboxGroupClient,
    credential: DefaultAzureCredential,
    endpoint: str,
    image: str,
    name: str,
    managed_identity_client_id: str,
    registry_name: str,
    allow_registry_token_fallback: bool,
) -> Any:
    token = credential.get_token("https://dynamicsessions.io/.default").token
    response = requests.put(
        (
            f"{endpoint}/subscriptions/{client.subscription_id}"
            f"/resourceGroups/{client.resource_group}"
            f"/sandboxGroups/{client.sandbox_group}/diskimages"
        ),
        params={"api-version": "2026-02-01-preview"},
        headers={"Authorization": f"Bearer {token}"},
        json={
            "image": {"base": image},
            "labels": {"name": name},
            "managedIdentityClientId": managed_identity_client_id,
        },
        timeout=60,
    )
    if (
        response.status_code == 401
        and allow_registry_token_fallback
        and "RegistryAuthFailed" in response.text
    ):
        command = [
            "az",
            "acr",
            "login",
            "--name",
            registry_name,
            "--expose-token",
            "--output",
            "json",
        ]
        if os.name == "nt":
            command = [os.environ.get("COMSPEC", "cmd.exe"), "/d", "/c", *command]
        login = subprocess.run(
            command,
            check=True,
            capture_output=True,
            text=True,
        )
        access_token = json.loads(login.stdout).get("accessToken")
        if not access_token:
            raise RuntimeError("Azure CLI did not return an ACR access token.")
        response = requests.put(
            (
                f"{endpoint}/subscriptions/{client.subscription_id}"
                f"/resourceGroups/{client.resource_group}"
                f"/sandboxGroups/{client.sandbox_group}/diskimages"
            ),
            params={"api-version": "2026-02-01-preview"},
            headers={"Authorization": f"Bearer {token}"},
            json={
                "image": {"base": image},
                "labels": {"name": name},
                "registryCredentials": {
                    "username": "00000000-0000-0000-0000-000000000000",
                    "token": access_token,
                },
            },
            timeout=60,
        )

    if not response.ok:
        raise RuntimeError(
            f"Disk image creation failed with HTTP {response.status_code}: "
            f"{response.text}"
        )
    image_id = response.json().get("id")
    if not image_id:
        raise RuntimeError("Disk image creation response did not contain an ID.")

    deadline = time.monotonic() + 600
    while time.monotonic() < deadline:
        disk = client.get_disk_image(image_id)
        state = disk.status.state if disk.status else ""
        if state in {"Ready", "Succeeded"}:
            return disk
        if state == "Failed":
            message = disk.status.message if disk.status else "unknown error"
            raise RuntimeError(f"Disk image {image_id} failed: {message}")
        time.sleep(5)
    raise TimeoutError(f"Disk image {image_id} did not become ready within 600s.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--subscription-id", required=True)
    parser.add_argument("--resource-group", required=True)
    parser.add_argument("--location", required=True)
    parser.add_argument("--sandbox-group", required=True)
    parser.add_argument("--sandbox-group-id", required=True)
    parser.add_argument("--managed-identity-resource-id", required=True)
    parser.add_argument("--managed-identity-client-id", required=True)
    parser.add_argument("--registry-name", required=True)
    parser.add_argument(
        "--registry-auth-mode",
        choices=["managed-identity", "managed-identity-with-token-fallback"],
        default="managed-identity",
    )
    parser.add_argument("--image", required=True)
    parser.add_argument("--image-tag", required=True)
    parser.add_argument("--disk-name", required=True)
    parser.add_argument("--token-fingerprint", required=True)
    parser.add_argument("--vnet-connection", required=True)
    parser.add_argument("--customer-id", required=True)
    parser.add_argument("--craigslist-site", required=True)
    parser.add_argument(
        "--profile",
        choices=["code-interpreter"],
        default="code-interpreter",
    )
    args = parser.parse_args()

    token = os.environ.get("MCP_AUTH_TOKEN")
    if not token:
        raise RuntimeError("MCP_AUTH_TOKEN must be configured.")
    if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", args.customer_id):
        raise ValueError("customer-id must be a lowercase DNS-style label.")
    if not re.fullmatch(r"[a-z0-9-]{1,40}", args.craigslist_site):
        raise ValueError("craigslist-site must be a valid Craigslist subdomain.")

    profile = profile_for(args.profile, token, args.craigslist_site)
    config_fingerprint = configuration_fingerprint(
        profile,
        args.vnet_connection,
        args.customer_id,
    )
    labels = {
        "application": "state-street-vnets",
        "component": profile.component,
        "version": args.image_tag,
        "token_fingerprint": args.token_fingerprint,
        "config_fingerprint": config_fingerprint,
        "customer_id": args.customer_id,
    }

    endpoint = endpoint_for_region(args.location)
    credential = (
        AzureCliCredential()
        if os.getenv("AZURE_CONFIG_DIR")
        else DefaultAzureCredential()
    )
    client = SandboxGroupClient(
        endpoint,
        credential,
        subscription_id=args.subscription_id,
        resource_group=args.resource_group,
        sandbox_group=args.sandbox_group,
    )

    disks = list(client.list_disk_images())
    disk = next(
        (
            item
            for item in disks
            if item.name == args.disk_name
            or item.labels.get("name") == args.disk_name
        ),
        None,
    )
    if disk is None:
        disk = create_disk_image(
            client,
            credential,
            endpoint,
            args.image,
            args.disk_name,
            args.managed_identity_client_id,
            args.registry_name,
            args.registry_auth_mode == "managed-identity-with-token-fallback",
        )

    matches = list(client.list_sandboxes(labels=labels))
    if matches:
        sandbox = client.get_sandbox(matches[0].id)
        mcp_url, health_url = port_urls(sandbox)
        print(
            json.dumps(
                {
                    "sandbox_id": sandbox.id,
                    "mcp_url": mcp_url,
                    "health_url": health_url,
                    "config_fingerprint": config_fingerprint,
                    "reused": True,
                }
            )
        )
        return

    egress_policy = EgressPolicy(
        default_action="Deny",
        host_rules=[
            EgressHostRule(pattern=host, action="Allow")
            for host in profile.allowed_hosts
        ],
    )
    sandbox_client = client.begin_create_sandbox(
        disk=None,
        disk_id=disk.id,
        cpu="2000m",
        memory="4096Mi",
        labels=labels,
        environment=profile.environment,
        egress_policy=egress_policy,
        ports=[AddPortRequest(port=8080, auth=PortAuthConfig(anonymous=True))],
        entrypoint=profile.entrypoint,
        customer_vnet_connection_name=args.vnet_connection,
    ).result()
    sandbox_client.set_lifecycle_policy(
        LifecyclePolicy(
            auto_suspend=AutoSuspendPolicy(enabled=False),
            auto_delete=AutoDeletePolicy(enabled=False),
        )
    )
    sandbox = sandbox_client.get()
    mcp_url, health_url = port_urls(sandbox)
    print(
        json.dumps(
            {
                "sandbox_id": sandbox.id,
                "mcp_url": mcp_url,
                "health_url": health_url,
                "config_fingerprint": config_fingerprint,
                "reused": False,
            }
        )
    )


if __name__ == "__main__":
    main()
