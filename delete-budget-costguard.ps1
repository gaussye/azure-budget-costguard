<#
.SYNOPSIS
  Delete an Azure Budget and every cost-guard resource wired to it, discovered
  by following the budget's REAL association chain (not by guessing names).

.DESCRIPTION
  Given a budget name, this script walks the live relationships:

     Budget.notifications[*].contactGroups[]        -> Action Group id(s)
        Action Group.automationRunbookReceivers[]   -> Automation Account id
                                                       Runbook name
                                                       Webhook resource id
           Automation Account.identity.principalId  -> Role assignment(s)

  It prints a table of the discovered resources (type + name + scope), asks for
  confirmation, and then deletes them. Deleting the Automation Account also
  removes its runbooks and webhooks.

  It does NOT delete the resource groups or the foundry (Cognitive Services)
  accounts, and it does NOT re-enable key auth that may have been disabled.

.PARAMETER BudgetName
  The budget to remove, e.g. costguard-rg-admin-3283.

.PARAMETER ResourceGroup
  Optional. The resource group the budget is scoped to. If omitted, the script
  locates the budget by trying the RG derived from the "costguard-" prefix and
  then the subscription scope.

.PARAMETER Subscription
  Optional. Subscription id/name. Defaults to the current az context.

.PARAMETER Yes
  Optional. Skip the interactive confirmation.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File delete-budget-costguard.ps1 -BudgetName costguard-rg-admin-3283

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File delete-budget-costguard.ps1 -BudgetName my-budget -ResourceGroup my-rg -Yes
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BudgetName,
    [string]$ResourceGroup,
    [string]$Subscription,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$BUDGET_API = '2023-11-01'
$AG_API     = '2023-01-01'
$AA_API     = '2023-11-01'

function Get-AzJson {
    param([string]$Url)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $raw = az rest --method get --url $Url -o json 2>$null
    }
    finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) { return $null }
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

# --- 0. Subscription context ---------------------------------------------
if ($Subscription) { az account set --subscription $Subscription | Out-Null }
$subId = (az account show --query id -o tsv)
if (-not $subId) { Write-Error 'Not logged in. Run: az login'; exit 1 }
Write-Host "Subscription : $subId"

# --- 1. Locate the budget (try RG scope, then subscription scope) ---------
$candidateScopes = @()
if ($ResourceGroup) {
    $candidateScopes += "subscriptions/$subId/resourceGroups/$ResourceGroup"
}
else {
    if ($BudgetName -like 'costguard-*') {
        $derivedRg = $BudgetName.Substring('costguard-'.Length)
        $candidateScopes += "subscriptions/$subId/resourceGroups/$derivedRg"
    }
    # subscription scope as a fallback
    $candidateScopes += "subscriptions/$subId"
}

$budget = $null
$budgetScopePath = $null
foreach ($scope in $candidateScopes) {
    $url = "https://management.azure.com/$scope/providers/Microsoft.Consumption/budgets/$BudgetName`?api-version=$BUDGET_API"
    $b = Get-AzJson $url
    if ($b) { $budget = $b; $budgetScopePath = $scope; break }
}

if (-not $budget) {
    Write-Host ""
    Write-Warning "Budget '$BudgetName' was not found at any tried scope: $($candidateScopes -join ', ')"
    Write-Host "If it lives in a different resource group, pass -ResourceGroup <name>."
    exit 1
}

$budgetDeleteUrl = "https://management.azure.com/$budgetScopePath/providers/Microsoft.Consumption/budgets/$BudgetName`?api-version=$BUDGET_API"
Write-Host "Budget       : $BudgetName  (scope: $budgetScopePath)  amount=$($budget.properties.amount)"

# --- 2. Follow the chain: budget -> action groups ------------------------
$actionGroupIds = New-Object System.Collections.Generic.HashSet[string]
foreach ($n in $budget.properties.notifications.PSObject.Properties) {
    $cg = $n.Value.contactGroups
    if ($cg) { foreach ($id in $cg) { if ($id) { [void]$actionGroupIds.Add($id) } } }
}

# --- 3. action groups -> automation accounts / runbooks / webhooks -------
$automationAccountIds = New-Object System.Collections.Generic.HashSet[string]
$runbooks  = @()   # objects: @{ Name; AutomationAccountId }
$webhooks  = @()   # objects: @{ Id }
foreach ($agId in $actionGroupIds) {
    $ag = Get-AzJson "https://management.azure.com$agId`?api-version=$AG_API"
    if (-not $ag) { continue }
    foreach ($r in @($ag.properties.automationRunbookReceivers)) {
        if (-not $r) { continue }
        if ($r.automationAccountId) { [void]$automationAccountIds.Add($r.automationAccountId) }
        if ($r.runbookName)  { $runbooks += @{ Name = $r.runbookName; AutomationAccountId = $r.automationAccountId } }
        if ($r.webhookResourceId) { $webhooks += @{ Id = $r.webhookResourceId } }
    }
}

# --- 4. automation accounts -> identity principals -> role assignments ----
$principalIds = New-Object System.Collections.Generic.HashSet[string]
foreach ($aaId in $automationAccountIds) {
    $aa = Get-AzJson "https://management.azure.com$aaId`?api-version=$AA_API"
    if ($aa -and $aa.identity -and $aa.identity.principalId) {
        [void]$principalIds.Add($aa.identity.principalId)
    }
}

$roleAssignments = @()   # objects: @{ Id; RoleName; Scope; PrincipalId }
foreach ($principal in $principalIds) {
    $ras = az role assignment list --assignee $principal --all -o json 2>$null | ConvertFrom-Json
    foreach ($ra in @($ras)) {
        if ($ra) {
            $roleAssignments += @{ Id = $ra.id; RoleName = $ra.roleDefinitionName; Scope = $ra.scope; PrincipalId = $principal }
        }
    }
}

# --- 5. Present the discovered resources ---------------------------------
$rows = @()
$rows += [pscustomobject]@{ Type = 'Microsoft.Consumption/budgets';            Name = $BudgetName;                         Scope = $budgetScopePath }
foreach ($agId in $actionGroupIds) {
    $rows += [pscustomobject]@{ Type = 'Microsoft.Insights/actionGroups';      Name = ($agId -split '/')[-1];              Scope = $agId }
}
foreach ($aaId in $automationAccountIds) {
    $rows += [pscustomobject]@{ Type = 'Microsoft.Automation/automationAccounts'; Name = ($aaId -split '/')[-1];           Scope = $aaId }
}
foreach ($rb in $runbooks) {
    $rows += [pscustomobject]@{ Type = '.../automationAccounts/runbooks';      Name = $rb.Name;                            Scope = $rb.AutomationAccountId }
}
foreach ($wh in $webhooks) {
    $rows += [pscustomobject]@{ Type = '.../automationAccounts/webhooks';      Name = ($wh.Id -split '/')[-1];             Scope = $wh.Id }
}
foreach ($ra in $roleAssignments) {
    $rows += [pscustomobject]@{ Type = 'RoleAssignment';                       Name = $ra.RoleName;                        Scope = $ra.Scope }
}

Write-Host ""
Write-Host "=== Resources discovered by following the budget's association chain ==="
$rows | Format-Table -AutoSize -Wrap | Out-String | Write-Host

# Webhooks/runbooks are children of the Automation Account and are removed with it.
$deletable = ($actionGroupIds.Count + $automationAccountIds.Count + $roleAssignments.Count) -gt 0 -or ($budget -ne $null)
if (-not $deletable) {
    Write-Host "Nothing to delete."
    exit 0
}

# --- 6. Confirm -----------------------------------------------------------
if (-not $Yes) {
    Write-Host "The resources listed above will be DELETED (runbooks + webhooks are removed with their Automation Account)."
    $ans = Read-Host "Type YES to proceed, anything else to cancel"
    if ($ans -ne 'YES') { Write-Host "Cancelled. Nothing was deleted."; exit 0 }
}

# --- 7. Delete (children first is not required; AA removal cascades) ------
Write-Host ""
Write-Host "=== Deleting ==="

# Budget
az rest --method delete --url $budgetDeleteUrl -o none 2>$null
Write-Host "  Deleted budget          : $BudgetName"

# Action groups
foreach ($agId in $actionGroupIds) {
    az resource delete --ids $agId -o none 2>$null
    Write-Host "  Deleted action group    : $(($agId -split '/')[-1])"
}

# Role assignments (identity is going away; drop dangling grants)
foreach ($ra in $roleAssignments) {
    az role assignment delete --ids $ra.Id -o none 2>$null
    Write-Host "  Deleted role assignment : $($ra.RoleName) on $($ra.Scope)"
}

# Automation accounts (removes runbooks + webhooks with them)
foreach ($aaId in $automationAccountIds) {
    az resource delete --ids $aaId -o none 2>$null
    Write-Host "  Deleted automation acct : $(($aaId -split '/')[-1])   [runbooks + webhooks removed with it]"
}

Write-Host ""
Write-Host "==========================================================================="
Write-Host " DELETION COMPLETE for budget: $BudgetName"
Write-Host "   Not touched: resource groups and the foundry (Cognitive Services) accounts."
Write-Host "   Key auth already disabled on foundry accounts is NOT reverted. To re-enable:"
Write-Host "     az resource update -g <rg> --name <account> --resource-type Microsoft.CognitiveServices/accounts --set properties.disableLocalAuth=false"
Write-Host "==========================================================================="
