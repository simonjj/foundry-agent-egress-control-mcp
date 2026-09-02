# ACA Terraform Sandbox Migration Plan

## Purpose

Move reusable Azure Container Apps (ACA) Sandbox infrastructure and deployment
logic from this repository into a clean checkout of the
`Azure/terraform-provider-aca` module repository.

This is a migration plan, not an implementation. No ACA Terraform module files
were changed for the current State Street deployment.

The migration must:

- preserve the deployed Sandbox Group, interpreter Sandbox, browser fallback
  Sandbox, disks, endpoints, and identities;
- retain create-or-reuse behavior;
- never delete a Sandbox, disk, snapshot, volume, or Sandbox Group implicitly;
- separate ARM control-plane ownership from ACA data-plane orchestration; and
- leave the State Street repository responsible only for workload-specific
  source, configuration, deployment composition, and acceptance tests.

## Agreed design

Implement two deliberately separate surfaces:

1. **Stable `modules/sandbox_groups`** for ARM control-plane resources.
2. **Quarantined `experimental/sandbox_workload`** for Terraform-driven ACA
   data-plane orchestration.

The stable module can be consumed without accepting scripts or local-exec
behavior. The experimental package must state clearly that it invokes the ACA
data plane and does not make Sandboxes into Terraform-managed ARM resources.

## Platform boundary

| Plane | Resources and operations | Ownership |
|---|---|---|
| ARM control plane | `Microsoft.App/sandboxGroups`, managed identity, tags, VNet connections, RBAC, management locks | Declarative Terraform through AzAPI/AzureRM |
| ACA data plane | Sandboxes, disks, images, snapshots, files, volumes, secrets, ports, egress, lifecycle operations | `aca` CLI, SDK, or REST invoked by an experimental workflow |

The stable module must not model a Sandbox instance as an `azapi_resource`.
Individual Sandbox operations are not ARM CRUD operations.

## Current State Street ownership

| Concern | Current implementation |
|---|---|
| Sandbox Group | `azapi_resource.sandbox_group` in `infrastructure/terraform/main.tf` |
| Operator RBAC | `azurerm_role_assignment.sandbox_operator` |
| ACR pull RBAC | `azurerm_role_assignment.sandbox_acr_pull` |
| Interpreter workflow | `terraform_data.interpreter_sandbox` |
| Browser fallback workflow | `terraform_data.browser_sandbox` |
| Endpoint discovery | `data.external.interpreter_sandbox` and `data.external.browser_sandbox` |
| Image build/import and Sandbox apply | `scripts/deploy-sandbox.ps1` |
| Endpoint lookup | `scripts/get-sandbox-output.ps1` |
| Egress inspection | `scripts/show-egress.ps1` |

Required behavior to preserve:

- immutable image references derived once from source content;
- idempotent image, disk, and Sandbox creation;
- managed-identity image import attempted before any token fallback;
- stable selector labels;
- replacement on image, authentication, or configuration changes;
- old Sandboxes retained after replacement;
- auto-delete disabled;
- default-deny network egress;
- deterministic endpoint lookup by configured port;
- sensitive Terraform values marked sensitive; and
- no data-plane delete operation on Terraform destroy.

## Target repository layout

```text
terraform-provider-aca/
|-- modules/
|   `-- sandbox_groups/
|       |-- main.tf
|       |-- rbac.tf
|       |-- variables.tf
|       |-- outputs.tf
|       |-- versions.tf
|       `-- README.md
|-- experimental/
|   `-- sandbox_workload/
|       |-- main.tf
|       |-- variables.tf
|       |-- outputs.tf
|       |-- versions.tf
|       |-- README.md
|       `-- scripts/
|           |-- Invoke-AcaSandboxWorkload.ps1
|           `-- Get-AcaSandboxWorkload.ps1
`-- tests/
```

Root-module wiring is deferred to a follow-up change. The first consumer should
call `modules/sandbox_groups` directly. The experimental workload package must
never be enabled implicitly by the root module.

## Stable module: `modules/sandbox_groups`

### Responsibilities

- Create `Microsoft.App/sandboxGroups@2026-02-01-preview`.
- Use the AzAPI resource's native `identity {}` block.
- Support system-assigned, user-assigned, and combined identity forms.
- Preserve nullable service properties rather than injecting module defaults.
- Support tags and optional VNet connection child resources.
- Create deterministic, statically keyed role assignments.
- Export group and identity information required by consumers.
- Provide a strong, documented destruction guard.

The first release must remain pinned to `2026-02-01-preview`, the API version
that currently manages the State Street group. Any API-version upgrade is a
separate change after migration and zero-drift confirmation.

### Identity representation

Upstream PR #7 currently places identity under `body.identity`. The deployed
State Street resource uses the native AzAPI identity block. The module must use:

```hcl
resource "azapi_resource" "this" {
  type      = "Microsoft.App/sandboxGroups@2026-02-01-preview"
  name      = var.name
  parent_id = var.resource_group_id
  location  = var.location
  tags      = var.tags

  identity {
    type         = var.identity.type
    identity_ids = var.identity.identity_ids
  }

  body = {
    properties = {
      for key, value in {
        defaultCpu             = var.default_cpu
        defaultMemory          = var.default_memory
        defaultDisk            = var.default_disk
        maxSandboxCount        = var.max_sandbox_count
        defaultTimeoutSeconds  = var.default_timeout_seconds
      } : key => value if value != null
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}
```

Using `body.identity` unchanged could produce identity drift or replacement
during the state move and is therefore a migration blocker.

### Inputs

Use typed, nullable inputs. Do not use `lifecycle` as an input name because it
is reserved Terraform syntax. Use `lifecycle_policy` for data-plane Sandbox
configuration in the experimental package.

The control-plane interface should include:

```hcl
name              = string
resource_group_id = string
location          = string
tags              = optional(map(string), {})

identity = optional(object({
  type         = optional(string, "SystemAssigned")
  identity_ids = optional(set(string), [])
}), {})

default_cpu             = optional(string)
default_memory          = optional(string)
default_disk            = optional(string)
max_sandbox_count       = optional(number)
default_timeout_seconds = optional(number)

data_plane_operators = optional(map(object({
  principal_id                     = string
  principal_type                   = optional(string, "ServicePrincipal")
  skip_service_principal_aad_check = optional(bool, true)
})), {})

acr_pull_assignments = optional(map(object({
  scope = string
})), {})
```

Maps must use caller-defined stable keys such as `current_user` and `primary`.
Do not derive `for_each` keys from principal IDs, resource IDs, or values that
can be unknown during planning.

### RBAC

Use these built-in role IDs:

```text
Container Apps SandboxGroup Data Owner: c24cf47c-5077-412d-a19c-45202126392c
AcrPull:                                7f951dda-4ed3-4680-a7ca-43fe172d538d
```

The ACR assignment must use the Sandbox Group managed-identity principal and
must depend on the group resource so the principal exists before assignment.

### Networking

Reuse only the `modules/sandbox_groups/**` portion of upstream PR #7 after
review. For a `vnetConnections` child:

- omit `location` unless the child resource schema explicitly supports it;
- omit null gateway/network properties;
- validate subnet IDs and supported delegation requirements; and
- avoid adopting unrelated Express or root-module changes from the PR.

### Outputs

Expose:

```text
id
name
location
principal_id
tenant_id
identity
management_endpoint
provisioning_state
vnet_connection_ids
```

AzAPI `response_export_values` and output-only service fields may produce
expected state-only differences during migration. They must be reviewed but
must not be mistaken automatically for remote resource changes.

### Provider compatibility

The ACA module currently constrains AzureRM below 5.0, while State Street uses
AzureRM 5.2.0. Before publishing Sandbox support:

1. audit the module for AzureRM 5.x breaking changes;
2. test the module against its supported 4.x baseline and 5.2.0;
3. widen the constraint only after tests pass, for example to `< 6.0.0`; and
4. pin State Street to a commit or release whose constraints accept 5.2.0.

Do not work around the conflict by downgrading the deployed State Street
configuration during migration.

### Protection semantics

A `CanNotDelete` management lock managed in the same Terraform state is not
sufficient: a single `terraform destroy` can remove the lock and then delete
the group. The State Street path therefore requires both:

1. a static `prevent_destroy = true` lifecycle guard on the Sandbox Group
   resource; and
2. a `CanNotDelete` lock managed from a separate protection configuration/state
   or another independently controlled platform stack.

Cleanup requires an explicit reviewed code change to remove `prevent_destroy`,
an independently approved lock removal, explicit data-plane cleanup, and only
then Sandbox Group deletion. The module must not expose a misleading
conditional lifecycle input.

## Experimental package: `experimental/sandbox_workload`

### Responsibilities

- Accept an already published immutable image reference.
- Import or reuse a Sandbox disk.
- Prefer managed-identity import.
- Create or reuse a Sandbox by stable labels.
- Serialize resources, entrypoint, environment, `lifecycle_policy`, egress, and
  ports into a manifest.
- Validate and apply the manifest.
- Resolve the configured port deterministically.
- Return Sandbox, disk, MCP, and health endpoint information.
- Preserve all data-plane resources when Terraform state is removed/destroyed.

The package must not:

- build images;
- run `az login` or `aca auth login`;
- delete Sandboxes or related data-plane resources;
- accept caller-computed script hashes or arbitrary replacement maps; or
- present itself as stable declarative infrastructure.

### Authentication prerequisites

Before Terraform runs, the operator or CI job must already be authenticated:

```powershell
az account show
aca auth status
```

If either command fails, stop with an actionable error. Interactive login from
Terraform provisioners is prohibited.

### Proposed consumer interface

```hcl
module "interpreter_sandbox" {
  source = "...//experimental/sandbox_workload"

  subscription_id     = var.subscription_id
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  sandbox_group_id    = module.sandbox_group.id
  sandbox_group_name  = module.sandbox_group.name

  image = {
    reference = local.interpreter_image_reference
    disk_name = "python-code-${local.interpreter_image_tag}"
  }

  selector_labels = {
    application       = "state-street-day3"
    component         = "code-interpreter"
    version           = local.interpreter_image_tag
    token_fingerprint = local.mcp_token_fingerprint
    config_fingerprint = local.interpreter_config_fingerprint
  }

  resources = {
    cpu    = "2000m"
    memory = "4096Mi"
  }

  entrypoint = ["python", "/app/server.py"]

  environment = {
    MCP_AUTH_TOKEN = random_password.mcp_auth_token.result
    MCP_HOST       = "0.0.0.0"
    MCP_PORT       = "8080"
  }

  lifecycle_policy = {
    auto_suspend_enabled = false
    auto_delete_enabled  = false
  }

  egress = {
    default_action = "Deny"
    host_rules = [
      { pattern = "craigslist.org", action = "Allow" },
      { pattern = "*.craigslist.org", action = "Allow" },
    ]
  }

  ports = {
    mcp = {
      port      = 8080
      anonymous = true
    }
  }

  primary_port_name = "mcp"
  mcp_path          = "/mcp"
  health_path       = "/health"

  depends_on = [module.sandbox_group]
}
```

### Internal replacement triggers

The package must derive its own replacement trigger from normalized inputs and
the packaged script content:

```hcl
locals {
  normalized_workload = {
    sandbox_group_id = var.sandbox_group_id
    image            = var.image
    selector_labels  = var.selector_labels
    resources        = var.resources
    entrypoint       = var.entrypoint
    environment      = nonsensitive(var.environment)
    lifecycle_policy = var.lifecycle_policy
    egress           = var.egress
    ports            = var.ports
  }

  config_fingerprint = sha256(jsonencode(local.normalized_workload))
  workflow_fingerprint = sha256(join("", [
    filesha256("${path.module}/scripts/Invoke-AcaSandboxWorkload.ps1"),
    filesha256("${path.module}/scripts/Get-AcaSandboxWorkload.ps1"),
  ]))
}
```

`terraform_data.triggers_replace` must include the immutable image reference,
Sandbox Group identity, configuration fingerprint, and workflow fingerprint.
The caller must not compute the same tag/hash independently in HCL and
PowerShell.

Add `config_fingerprint` to the Sandbox selector labels. This prevents changed
ports, egress, lifecycle, resources, or entrypoints from silently reusing a
Sandbox configured under an older manifest.

### Endpoint outputs

Return:

```text
sandbox_id
disk_id
disk_name
port_urls
mcp_url
health_url
selector_labels
config_fingerprint
```

`port_urls` must be a map keyed by caller-supplied port name. Never use the
first member of an unordered ports array. Fail if `primary_port_name` is absent.

`data.external` can return only `map(string)`. Any list, map, or object result
must be JSON encoded by the script and decoded in HCL:

```hcl
port_urls = jsondecode(data.external.workload.result.port_urls_json)
```

### Secret handling

Required work:

1. Investigate whether Sandbox Group secrets can be referenced from manifest
   environment entries.
2. Prefer secret references when the service supports them.
3. Otherwise create a uniquely named temporary manifest, pass sensitive values
   only in memory, and remove the file in `finally`.
4. Mark environment inputs and token-bearing outputs sensitive.
5. Never put tokens in labels, outputs, logs, Terraform command arguments, or
   persistent files.
6. Investigate replacing the current ACR `--token` command argument with a
   supported stdin, environment, or protected-file mechanism.

The current `--token` fallback exposes a short-lived registry token in process
arguments. Until a safer supported transport is verified, this remains a
documented residual risk and the fallback must be opt-in. Terraform state still
contains sensitive values supplied as inputs; remote state encryption and
access control are mandatory.

### Preservation

The package must have no destroy provisioner. Removing its Terraform state must
leave Sandboxes, disks, snapshots, files, and volumes untouched. Cleanup belongs
to a separately invoked, explicit operator workflow with resource previews and
confirmation.

## Delivery workflow

Use three ordered stages:

1. **Platform:** resource group, ACR, Sandbox Group, identities, RBAC, and
   protection.
2. **Image publish:** compute each source fingerprint once, build the image,
   publish it, and emit the immutable image digest/reference.
3. **Workload and application:** invoke the experimental workload package using
   that exact image reference, then deploy the Hosted Agent and run validation.

The image-publish stage owns tag computation. HCL and PowerShell must consume
one emitted tag/reference rather than recomputing it independently.

## State migration prerequisites

The current Terraform state is local, ignored by Git, unlocked, stored under a
OneDrive-synchronized directory, and unsuitable for high-risk state surgery.
Before migration:

1. Stop concurrent Terraform/deployment activity.
2. Copy the complete state and `.terraform` metadata to a timestamped,
   access-controlled backup outside OneDrive.
3. Record current Sandbox Group, role-assignment, Sandbox, disk, and endpoint
   IDs.
4. Prefer migrating to an Azure Storage backend with locking and versioning.
5. Run `terraform state pull` and retain the exported JSON securely.
6. Confirm a normal refresh-only plan before changing addresses.

Do not continue if the backup cannot be restored or the backend is being used
concurrently.

## Exact control-plane state moves

Choose these resource names as part of the module contract:

```hcl
moved {
  from = azapi_resource.sandbox_group
  to   = module.sandbox_group.azapi_resource.this
}

moved {
  from = azurerm_role_assignment.sandbox_operator
  to   = module.sandbox_group.azurerm_role_assignment.data_plane_operator["current_user"]
}

moved {
  from = azurerm_role_assignment.sandbox_acr_pull
  to   = module.sandbox_group.azurerm_role_assignment.acr_pull["primary"]
}
```

If final implementation addresses differ, update this document and review the
exact `terraform state mv` commands before execution. Do not guess addresses.

Do **not** move `terraform_data.interpreter_sandbox` or
`terraform_data.browser_sandbox`. The new internally derived triggers and
script hashes intentionally differ. Let each new workflow run once and prove
that it finds and reuses the existing disk and Sandbox by selector labels.
`data.external` sources do not require state migration.

## Migration plan gate

The first post-move plan may contain:

- moved resource addresses;
- AzAPI `response_export_values` normalization;
- output-only `provisioningState`, endpoint, or identity values;
- new experimental workflow state that resolves existing data-plane objects;
  and
- output rewiring with unchanged values.

It must not contain:

- Sandbox Group delete, replacement, or identity removal;
- role-assignment replacement caused by unstable keys;
- a different remote group body;
- data-plane delete commands;
- new duplicate Sandboxes/disks for unchanged configuration; or
- secret values in command lines or logs.

Approve apply only after correlating every planned change with the deployed
resource and saved pre-migration IDs.

After apply:

1. Compare Sandbox Group, principal, RBAC, Sandbox, disk, and endpoint IDs.
2. Run the full State Street tool tests.
3. Run an immediate zero-drift plan.
4. Re-export **all** Terraform outputs to the selected `azd` environment.
5. Confirm `show-egress.ps1` reads live Terraform outputs.

## Testing

### Terraform tests

Add plan tests for:

- minimal group body with null properties omitted;
- native system/user-assigned identity;
- VNet child schema;
- statically keyed operator and ACR assignments;
- provider compatibility;
- stable outputs; and
- deletion-protection contract documentation.

### Script contract tests

Use a fake `aca` executable or captured fixtures for:

- pre-authentication failures;
- mixed informational output and JSON;
- empty arrays;
- image/disk/Sandbox reuse;
- deterministic named-port selection;
- JSON encoding for `data.external`;
- managed-identity import and explicit token fallback;
- retry exhaustion;
- temporary-file cleanup; and
- actionable errors.

The assertion that no data-plane destroy command exists belongs in static
repository checks over the scripts, not in `.tftest.hcl`.

### Azure integration tests

In a manually approved test environment:

1. create a protected Sandbox Group;
2. assign operator and ACR roles;
3. publish/import one immutable image;
4. create a Sandbox and validate health;
5. reapply and prove reuse;
6. change the configuration fingerprint and prove a new Sandbox is created
   while the previous Sandbox remains;
7. verify default-deny egress; and
8. clean up only through an explicit separate workflow.

### State Street regression

Run:

```powershell
python -m unittest discover -s tests -v
pwsh .\scripts\smoke-test.ps1
pwsh .\scripts\test-agent-streaming.ps1
pwsh .\scripts\test-agent-tools.ps1
pwsh .\scripts\query-observability.ps1 -LookbackMinutes 30
```

Confirm both Sandbox IDs and URLs, APIM routing, active Playwright Workspace
use, telemetry, and a final zero-drift Terraform plan.

## Upstream/worktree strategy

The existing ACA module checkout contains unrelated Express work. Do not edit,
revert, stash, or mix it.

1. Fetch `origin`.
2. Create a clean worktree from `origin/main`.
3. Fetch upstream PR #7 into a review branch.
4. take only `modules/sandbox_groups/**` as a baseline;
5. do not take overlapping Express, provider-root, or root-module changes;
6. correct identity, null-property, networking, provider, RBAC, protection,
   tests, and documentation behavior in focused commits;
7. submit stable control-plane support independently; and
8. submit `experimental/sandbox_workload` separately.

If maintainers reject Terraform-shaped imperative orchestration, keep the
generic workflow under `tools/sandbox` in the ACA repository and consume it as
a versioned companion tool. Do not return generic scripts to State Street.

## State Street changes after module publication

1. Pin the reviewed ACA module commit/release.
2. Replace the local Sandbox Group and RBAC with `module.sandbox_group`.
3. Move only control-plane state using reviewed exact addresses.
4. Split deployment into platform, image publish, and workload/application
   stages.
5. Replace both local `terraform_data` and `data.external` pairs with
   experimental package calls.
6. Supply workload-specific entrypoint, environment, egress, ports, and labels.
7. Rewire existing outputs without changing their names or values.
8. Re-export all Terraform outputs to `azd`.
9. Remove local generic Sandbox scripts only after parity and zero drift.
10. Retain workload source, Hosted Agent configuration, and end-to-end tests.

## Phased delivery

| Phase | Work | Exit criterion |
|---|---|---|
| 0 | Clean worktree, provider audit, state backup/backend, deployed-ID inventory | Recoverable baseline and no unrelated changes |
| 1 | Correct and land `modules/sandbox_groups` | Module represents State Street group without remote changes |
| 2 | Publish images through a single tag/digest owner | Immutable references available to Terraform |
| 3 | Build `experimental/sandbox_workload` | Existing Sandbox can be resolved/reused without consumer scripts |
| 4 | Move State Street control-plane state and rewire workloads | IDs and endpoints unchanged; no implicit delete |
| 5 | Run regression, telemetry, and drift checks | All checks pass and plan is zero drift |
| 6 | Release and pin reviewed versions | Consumer no longer depends on unreviewed local code |

## Definition of done

- Stable Sandbox Group and RBAC support is published by the ACA module.
- The native AzAPI identity representation and deployed API version are
  preserved.
- AzureRM 5.2.0 compatibility is tested and supported.
- Generic data-plane orchestration lives in a quarantined ACA companion package.
- Image tags are calculated once and immutable image references are consumed.
- Replacement triggers and selector fingerprints are derived internally.
- Existing interpreter and browser fallback Sandboxes, disks, and endpoints
  remain intact.
- No data-plane destroy behavior exists.
- Sandbox Group deletion requires explicit multi-step approval.
- Terraform state is backed up and preferably remotely locked/versioned.
- All Terraform outputs are re-exported to `azd`.
- State Street tests, observability checks, and final zero-drift plan pass.

## References

- [Azure/terraform-provider-aca PR #7](https://github.com/Azure/terraform-provider-aca/pull/7)
- [ACA Sandboxes overview](https://learn.microsoft.com/azure/container-apps/sandboxes-overview)
- [ACA Sandboxes getting started](https://learn.microsoft.com/azure/container-apps/sandboxes-get-started)
- [ACA Sandboxes Bicep quickstart](https://learn.microsoft.com/azure/container-apps/sandboxes-quickstart-bicep)
- [ACA Sandbox egress policies](https://learn.microsoft.com/azure/container-apps/sandboxes-egress-policies)
- [ACA Sandbox snapshots and state](https://learn.microsoft.com/azure/container-apps/sandboxes-snapshots-state-management)
- [Official ACA Sandbox CLI skill](https://github.com/microsoft/azure-container-apps/blob/main/plugin/skills/aca-sandboxes/SKILL.md)
