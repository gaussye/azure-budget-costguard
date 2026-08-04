@echo off
setlocal EnableDelayedExpansion

REM ===========================================================================
REM  delete-budget-costguard-rg.cmd   (budget-name driven, interactive)
REM
REM  USAGE:
REM     delete-budget-costguard-rg.cmd <budget-name> [resource-group]
REM
REM     <budget-name>      the budget to remove, e.g. costguard-rg-admin-3283
REM                        (as shown in Cost Management -^> Budgets)
REM     [resource-group]   OPTIONAL. The guarded RG the budget is scoped to.
REM                        If omitted, it is derived from the budget name by
REM                        stripping the leading "costguard-" prefix.
REM
REM  What it does:
REM     1. Resolves the budget and every cost-guard resource created for it by
REM        setup-budget-costguard-rg.cmd.
REM     2. Prints a table of RESOURCE TYPE + NAME + STATUS (found / not found).
REM     3. Asks for confirmation.
REM     4. On YES, deletes them: Budget, Action Group, role assignment and the
REM        Automation Account (which also removes its runbook + webhook).
REM
REM  It does NOT delete the shared infra RG, the target RG, or the foundry
REM  accounts, and it does NOT re-enable key auth that was disabled.
REM
REM  Prereq:  az login   (and the right subscription selected / set below)
REM ===========================================================================

REM ----------------------------- EDIT THESE ---------------------------------
set "SUBSCRIPTION="
set "INFRA_RG=rg-budget-costguard"

REM Name prefixes; MUST match setup-budget-costguard-rg.cmd.
set "BUDGET_PREFIX=costguard-"
set "AUTOMATION_PREFIX=aa-cg"
set "RUNBOOK_PREFIX=DisableLocalAuth"
set "ACTION_GROUP_PREFIX=ag-cg"
REM --------------------------------------------------------------------------

set "BUDGET_NAME=%~1"
if "%BUDGET_NAME%"=="" (
  echo Usage: %~nx0 ^<budget-name^> [resource-group]
  echo Example: %~nx0 costguard-rg-admin-3283
  exit /b 1
)

REM Target RG: use arg 2 if given, else strip the "costguard-" prefix.
set "TARGET_RG=%~2"
if "%TARGET_RG%"=="" set "TARGET_RG=%BUDGET_NAME:costguard-=%"

echo.
echo === [0] Selecting subscription ===
if not "%SUBSCRIPTION%"=="" call az account set --subscription "%SUBSCRIPTION%" || goto :error
for /f "usebackq delims=" %%i in (`az account show --query id -o tsv`) do set "SUBSCRIPTION=%%i"
echo Subscription : %SUBSCRIPTION%

set "TARGET_RG_ID=/subscriptions/%SUBSCRIPTION%/resourceGroups/%TARGET_RG%"

REM --- Derive per-RG names (must match setup: underscores become hyphens) ---
set "RG_SAFE=%TARGET_RG:_=-%"
set "AUTOMATION_ACCOUNT=%AUTOMATION_PREFIX%-%RG_SAFE%"
set "RUNBOOK_NAME=%RUNBOOK_PREFIX%-%RG_SAFE%"
set "ACTION_GROUP=%ACTION_GROUP_PREFIX%-%RG_SAFE%"
set "AA_RESOURCE_ID=/subscriptions/%SUBSCRIPTION%/resourceGroups/%INFRA_RG%/providers/Microsoft.Automation/automationAccounts/%AUTOMATION_ACCOUNT%"
set "BUDGET_URL=https://management.azure.com/subscriptions/%SUBSCRIPTION%/resourceGroups/%TARGET_RG%/providers/Microsoft.Consumption/budgets/%BUDGET_NAME%?api-version=2023-11-01"

echo.
echo === [1] Discovering associated resources ===
echo Budget name  : %BUDGET_NAME%
echo Target RG    : %TARGET_RG%
echo Infra RG     : %INFRA_RG%
echo.

REM --- Budget ---
set "B_FOUND="
set "B_AMOUNT="
for /f "usebackq delims=" %%i in (`az rest --method get --url "%BUDGET_URL%" --query "properties.amount" -o tsv 2^>nul`) do set "B_AMOUNT=%%i"
if defined B_AMOUNT set "B_FOUND=1"

REM --- Action Group ---
set "AG_FOUND="
for /f "usebackq delims=" %%i in (`az monitor action-group show --name "%ACTION_GROUP%" --resource-group "%INFRA_RG%" --query "name" -o tsv 2^>nul`) do set "AG_FOUND=%%i"

REM --- Automation Account + its identity principal ---
set "AA_FOUND="
set "PRINCIPAL_ID="
for /f "usebackq delims=" %%i in (`az automation account show --resource-group "%INFRA_RG%" --name "%AUTOMATION_ACCOUNT%" --query "name" -o tsv 2^>nul`) do set "AA_FOUND=%%i"
if defined AA_FOUND (
  for /f "usebackq delims=" %%i in (`az rest --method get --url "https://management.azure.com%AA_RESOURCE_ID%?api-version=2023-11-01" --query "identity.principalId" -o tsv 2^>nul`) do set "PRINCIPAL_ID=%%i"
)

REM --- Runbook (only meaningful if AA exists) ---
set "RB_FOUND="
if defined AA_FOUND (
  for /f "usebackq delims=" %%i in (`az automation runbook show --resource-group "%INFRA_RG%" --automation-account-name "%AUTOMATION_ACCOUNT%" --name "%RUNBOOK_NAME%" --query "name" -o tsv 2^>nul`) do set "RB_FOUND=%%i"
)

REM --- Role assignment on the target RG ---
set "RA_FOUND="
if defined PRINCIPAL_ID (
  for /f "usebackq delims=" %%i in (`az role assignment list --assignee "%PRINCIPAL_ID%" --role "Cognitive Services Contributor" --scope "%TARGET_RG_ID%" --query "[0].id" -o tsv 2^>nul`) do set "RA_FOUND=%%i"
)

REM --- Resolve human-friendly status strings ---
set "B_ST=not found"
if defined B_FOUND set "B_ST=FOUND  amount=%B_AMOUNT%"
set "AG_ST=not found"
if defined AG_FOUND set "AG_ST=FOUND"
set "AA_ST=not found"
if defined AA_FOUND set "AA_ST=FOUND"
set "RB_ST=not found"
if defined RB_FOUND set "RB_ST=FOUND"
set "RA_ST=not found"
if defined RA_FOUND set "RA_ST=FOUND"

echo   RESOURCE TYPE                          NAME                                     STATUS
echo   -------------------------------------  ---------------------------------------  ------------------------
echo   Microsoft.Consumption/budgets          %BUDGET_NAME%   [%TARGET_RG%]   %B_ST%
echo   Microsoft.Insights/actionGroups        %ACTION_GROUP%   [%INFRA_RG%]   %AG_ST%
echo   Microsoft.Automation/automationAccounts %AUTOMATION_ACCOUNT%   [%INFRA_RG%]   %AA_ST%
echo   .../automationAccounts/runbooks        %RUNBOOK_NAME%   [%INFRA_RG%]   %RB_ST%
echo   RoleAssignment CognitiveSvc Contributor identity of %AUTOMATION_ACCOUNT% on %TARGET_RG%   %RA_ST%
echo.

if not defined B_FOUND if not defined AG_FOUND if not defined AA_FOUND if not defined RA_FOUND (
  echo Nothing to delete: no cost-guard resources were found for this budget.
  goto :eof
)

echo === [2] Confirmation ===
echo The resources marked FOUND above will be DELETED.
set "CONFIRM="
set /p "CONFIRM=Type YES to proceed, anything else to cancel: "
if /I not "%CONFIRM%"=="YES" (
  echo Cancelled. Nothing was deleted.
  goto :eof
)

echo.
echo === [3] Deleting ===

if defined B_FOUND (
  call az rest --method delete --url "%BUDGET_URL%" -o none 2>nul
  echo   Deleted budget           : %BUDGET_NAME%
)
if defined AG_FOUND (
  call az monitor action-group delete --name "%ACTION_GROUP%" --resource-group "%INFRA_RG%" -o none 2>nul
  echo   Deleted action group     : %ACTION_GROUP%
)
if defined RA_FOUND (
  call az role assignment delete --assignee "%PRINCIPAL_ID%" --role "Cognitive Services Contributor" --scope "%TARGET_RG_ID%" -o none 2>nul
  echo   Deleted role assignment  : identity of %AUTOMATION_ACCOUNT% on %TARGET_RG%
)
if defined AA_FOUND (
  call az automation account delete --name "%AUTOMATION_ACCOUNT%" --resource-group "%INFRA_RG%" --yes -o none 2>nul
  echo   Deleted automation acct  : %AUTOMATION_ACCOUNT%   [runbook + webhook removed with it]
)

echo.
echo === [4] Done ===
echo ===========================================================================
echo  DELETION COMPLETE for budget: %BUDGET_NAME%
echo    NOT touched: infra RG %INFRA_RG%, the target RG %TARGET_RG%, and foundry accounts.
echo    Key auth already disabled on foundry accounts is NOT reverted. To re-enable:
echo      az resource update -g %TARGET_RG% --name ^<account^> --resource-type Microsoft.CognitiveServices/accounts --set properties.disableLocalAuth=false
echo ===========================================================================
goto :eof

:error
echo.
echo *** ERROR: a step failed (exit code 1). Review the output above. ***
exit /b 1
