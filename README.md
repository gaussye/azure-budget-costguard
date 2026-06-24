# Azure Budget Cost-Guard

A one-shot, **idempotent** Windows CMD script that wires an automatic **cost
kill-switch** for an Azure **Cognitive / AI Services** account.

When the account's monthly spend crosses a budget threshold, Azure automatically
disables the resource's **local (key) authentication**
(`properties.disableLocalAuth = true`), stopping further key-based usage and
runaway cost.

```
Budget alert (threshold reached)
      │
      ▼
Action Group  (Automation Runbook receiver)
      │   └─ internally triggered via the runbook's webhook URL (serviceUri)
      ▼
Automation Runbook  "DisableLocalAuth-<resource>"
      │   └─ uses the Automation Account's system-assigned managed identity
      ▼
ARM PATCH  →  properties.disableLocalAuth = true
```

## Why a Runbook (and a webhook)?

An Action Group **cannot run a CLI command directly** — it can only deliver the
event to a receiver. To actually execute `disableLocalAuth`, the event is routed
to an **Azure Automation Runbook**, which runs PowerShell using a managed
identity.

The Runbook is triggered through its **webhook URL**. Even when the Action Group
uses the *Automation Runbook* receiver type, that receiver still calls the
runbook's webhook under the hood (`serviceUri`), so the webhook is a required
component — not an alternative to the runbook.

> Note: the Azure Automation sandbox does **not** ship the `az` CLI, so the
> runbook performs the equivalent ARM PATCH directly instead of calling
> `az resource update`.

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) installed and signed in:
  ```cmd
  az login
  ```
- Permission to create resources and assign roles (Owner / User Access
  Administrator on the target scope).
- The target **Cognitive / AI Services** account must already exist.

## Usage

```cmd
setup-budget-costguard.cmd <resource> [budget-amount] [threshold-percent]
```

| Argument            | Required | Description                                         | Default |
|---------------------|----------|-----------------------------------------------------|---------|
| `<resource>`        | yes      | Cognitive account **name** OR full **resource id**  | —       |
| `[budget-amount]`   | no       | Monthly budget amount                               | `50`    |
| `[threshold-percent]` | no     | Alert threshold (% of budget)                       | `90`    |

### Examples

```cmd
:: defaults (budget 50, alert at 90%)
setup-budget-costguard.cmd admin-3283-resource

:: budget 100
setup-budget-costguard.cmd admin-3283-resource 100

:: budget 100, alert at 80%
setup-budget-costguard.cmd admin-3283-resource 100 80

:: by full resource id
setup-budget-costguard.cmd /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<name> 100 80
```

The resource group is resolved automatically from the resource — you only pass
the resource.

## Configuration

Edit the variable block near the top of `setup-budget-costguard.cmd`:

| Variable                 | Purpose                                              |
|--------------------------|------------------------------------------------------|
| `SUBSCRIPTION`           | Target subscription (blank = current `az` context)   |
| `INFRA_RG`               | Resource group that holds the Automation Account     |
| `LOCATION`               | Region for the infra resources                       |
| `COG_API_VERSION`        | API version used to PATCH the Cognitive account      |
| `BUDGET_AMOUNT` / `BUDGET_THRESHOLD` | Defaults (overridable via args 2 & 3)    |
| `ALERT_EMAIL`            | Email also notified by the budget                    |
| `AUTOMATION_PREFIX` / `ACTION_GROUP_PREFIX` / `RUNBOOK_PREFIX` | Name prefixes |
| `SET_DISABLE_LOCAL_AUTH` | `true` = disable keys (default); `false` = enable     |

> ⚠️ **`disableLocalAuth=true` disables the keys.** Set
> `SET_DISABLE_LOCAL_AUTH=false` only if you want the opposite behaviour.

## Created resources

For a resource named `admin-3283-resource`, the script creates:

| Resource            | Name                                    | Location          |
|---------------------|-----------------------------------------|-------------------|
| Automation Account  | `aa-cg-admin-3283-resource`             | `INFRA_RG`        |
| Runbook             | `DisableLocalAuth-admin-3283-resource`  | `INFRA_RG`        |
| Webhook             | `DisableLocalAuth-admin-3283-resource-wh` | `INFRA_RG`      |
| Action Group        | `ag-cg-admin-3283-resource`             | `INFRA_RG`        |
| Budget              | `costguard-admin-3283-resource`         | target RG (scoped to the resource) |
| Role assignment     | *Cognitive Services Contributor* for the Automation Account's managed identity | on the target resource |

## Idempotency

The script is safe to re-run:

- **Role assignment** — checked first; skipped if it already exists.
- **Runbook** — created only if missing; content is always replaced & published.
- **Webhook** — deleted and recreated (a webhook URI is *write-once*).
- **Action Group / Budget / identity** — PUT/PATCH overwrite (naturally idempotent).

> Because a webhook URI cannot be updated, **each run rotates the webhook URL**.
> The script automatically syncs the new URL into the Action Group, so the alert
> path always stays valid — but any previously saved test URL becomes invalid.

## Testing the cost-guard

Cost data has normal Azure latency (hours), so real budget firing isn't instant.
To test the wiring immediately, POST to the webhook URL printed at the end of a
run:

```cmd
curl -X POST "<WEBHOOK_URI>"
```

Then verify:

```cmd
:: check the runbook job history in the portal:
::   Automation Account -> Runbooks -> DisableLocalAuth-<resource> -> Jobs

:: or check the resource state directly:
az resource show --ids <resource-id> --query "properties.disableLocalAuth"
```

A successful run outputs `disableLocalAuth is now True`.

## Where to view the Runbook

```
Azure Portal -> Automation Accounts -> aa-cg-<resource>
  -> Process Automation -> Runbooks -> DisableLocalAuth-<resource>
       - Edit : view the PowerShell source
       - Jobs : execution history & output
       - Webhooks : the bound webhook
```

## Cleanup

To remove everything the script created for a given resource:

```cmd
:: delete budget
az rest --method delete --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/<cog-rg>/providers/Microsoft.Consumption/budgets/costguard-<resource>?api-version=2023-11-01"

:: delete action group
az monitor action-group delete --name ag-cg-<resource> --resource-group <infra-rg>

:: delete role assignment (use the Automation Account's managed identity principalId)
az role assignment delete --assignee <principalId> --role "Cognitive Services Contributor" --scope <resource-id>

:: delete automation account (removes runbook + webhook)
az automation account delete --name aa-cg-<resource> --resource-group <infra-rg> --yes
```

## Notes & limitations

- Targets **`Microsoft.CognitiveServices/accounts`** resources.
- The resource id baked into the runbook is **static** — one runbook per
  resource. Re-run the script per resource to protect multiple accounts.
- Some accounts may be pinned to `disableLocalAuth=true` by an Azure Policy; in
  that case there is simply nothing to flip.

## License

MIT
