@echo off
setlocal EnableDelayedExpansion

REM ===========================================================================
REM  teardown-budget-costguard-rg.cmd   (RESOURCE-GROUP scoped variant)
REM
REM  USAGE:
REM     teardown-budget-costguard-rg.cmd <resource-group>
REM
REM     <resource-group>   name of the guarded resource group whose cost-guard
REM                        resources should be removed (required)
REM
REM  Reverses setup-budget-costguard-rg.cmd. It deletes, for the given RG:
REM     - the Budget            (costguard-<rg>, at the RG scope)
REM     - the Action Group      (ag-cg-<rg>, in the infra RG)
REM     - the role assignment   (Cognitive Services Contributor granted to the
REM                              Automation Account identity on the target RG)
REM     - the Automation Account (aa-cg-<rg>, in the infra RG) which also removes
REM                              its Runbook and Webhook
REM
REM  It does NOT delete the shared infra resource group (%INFRA_RG%) because it
REM  may host cost-guard resources for other guarded RGs. It also does NOT touch
REM  the target resource group or the foundry accounts themselves.
REM
REM  Prereq:  az login   (and the right subscription selected / set below)
REM ===========================================================================

REM ----------------------------- EDIT THESE ---------------------------------
set "SUBSCRIPTION="
set "INFRA_RG=rg-budget-costguard"

REM Name prefixes; MUST match setup-budget-costguard-rg.cmd.
set "AUTOMATION_PREFIX=aa-cg"
set "RUNBOOK_PREFIX=DisableLocalAuth"
set "ACTION_GROUP_PREFIX=ag-cg"
REM --------------------------------------------------------------------------

set "TARGET_RG=%~1"
if "%TARGET_RG%"=="" (
  echo Usage: %~nx0 ^<resource-group^>
  exit /b 1
)

echo.
echo === [0/5] Selecting subscription ===
if not "%SUBSCRIPTION%"=="" call az account set --subscription "%SUBSCRIPTION%" || goto :error
for /f "usebackq delims=" %%i in (`az account show --query id -o tsv`) do set "SUBSCRIPTION=%%i"
echo Subscription: %SUBSCRIPTION%

set "TARGET_RG_ID=/subscriptions/%SUBSCRIPTION%/resourceGroups/%TARGET_RG%"

REM --- Deriving per-RG names (must match setup: replace underscores with hyphens) ---
set "RG_SAFE=%TARGET_RG:_=-%"
set "AUTOMATION_ACCOUNT=%AUTOMATION_PREFIX%-%RG_SAFE%"
set "RUNBOOK_NAME=%RUNBOOK_PREFIX%-%RG_SAFE%"
set "ACTION_GROUP=%ACTION_GROUP_PREFIX%-%RG_SAFE%"
set "BUDGET_NAME=costguard-%TARGET_RG%"
set "AA_RESOURCE_ID=/subscriptions/%SUBSCRIPTION%/resourceGroups/%INFRA_RG%/providers/Microsoft.Automation/automationAccounts/%AUTOMATION_ACCOUNT%"
echo Names    : AA=%AUTOMATION_ACCOUNT%  RB=%RUNBOOK_NAME%  AG=%ACTION_GROUP%  BUDGET=%BUDGET_NAME%

echo.
echo === [1/5] Deleting the Budget (RG scope) ===
call az rest --method delete --url "https://management.azure.com/subscriptions/%SUBSCRIPTION%/resourceGroups/%TARGET_RG%/providers/Microsoft.Consumption/budgets/%BUDGET_NAME%?api-version=2023-11-01" -o none 2>nul
echo Budget %BUDGET_NAME% removed (if it existed).

echo.
echo === [2/5] Deleting the Action Group ===
call az monitor action-group delete --name "%ACTION_GROUP%" --resource-group "%INFRA_RG%" -o none 2>nul
echo Action Group %ACTION_GROUP% removed (if it existed).

echo.
echo === [3/5] Removing the role assignment on the target RG ===
set "PRINCIPAL_ID="
for /f "usebackq delims=" %%i in (`az rest --method get --url "https://management.azure.com%AA_RESOURCE_ID%?api-version=2023-11-01" --query "identity.principalId" -o tsv 2^>nul`) do set "PRINCIPAL_ID=%%i"
if defined PRINCIPAL_ID (
  call az role assignment delete --assignee "%PRINCIPAL_ID%" --role "Cognitive Services Contributor" --scope "%TARGET_RG_ID%" -o none 2>nul
  echo Role assignment for identity %PRINCIPAL_ID% removed if present.
) else (
  echo No Automation Account identity found; skipping role assignment cleanup.
)

echo.
echo === [4/5] Deleting the Automation Account (removes its Runbook + Webhook) ===
call az automation account delete --name "%AUTOMATION_ACCOUNT%" --resource-group "%INFRA_RG%" --yes -o none 2>nul
echo Automation Account %AUTOMATION_ACCOUNT% removed (if it existed).

echo.
echo === [5/5] Done ===
echo ===========================================================================
echo  TEARDOWN COMPLETE for resource group: %TARGET_RG%
echo    Deleted (if present):
echo      Budget          : %BUDGET_NAME%
echo      Action Group    : %ACTION_GROUP%
echo      Role assignment : Cognitive Services Contributor on %TARGET_RG%
echo      Automation Acct : %AUTOMATION_ACCOUNT%  (+ runbook %RUNBOOK_NAME% + webhook)
echo.
echo    NOT touched: infra RG %INFRA_RG%, the target RG, and the foundry accounts.
echo    Note: disabling of local (key) auth already applied to foundry accounts is
echo          NOT reverted by this script. To re-enable a key, run:
echo      az resource update -g %TARGET_RG% --name ^<account^> --resource-type Microsoft.CognitiveServices/accounts --set properties.disableLocalAuth=false
echo ===========================================================================
goto :eof

:error
echo.
echo *** ERROR: a step failed (exit code 1). Review the output above. ***
exit /b 1
