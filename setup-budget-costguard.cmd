@echo off
setlocal EnableDelayedExpansion

REM ===========================================================================
REM  setup-budget-costguard.cmd
REM
REM  USAGE:
REM     setup-budget-costguard.cmd <resource> [budget-amount] [threshold-percent]
REM
REM     <resource>           cognitive-account name OR full resource id (required)
REM     [budget-amount]      monthly budget, e.g. 50   (optional, default below)
REM     [threshold-percent]  alert threshold %, e.g. 90 (optional, default below)
REM
REM  The resource group is resolved automatically, then wires up:
REM
REM     Budget alert -> Action Group (webhook) -> Automation Runbook webhook
REM                  -> runbook disables the resource's local (key) auth.
REM
REM  The disable step is the equivalent of:
REM     az resource update --resource-group <rg> --name <name> ^
REM        --resource-type Microsoft.CognitiveServices/accounts ^
REM        --set properties.disableLocalAuth=true
REM  (The runbook performs the same PATCH via the managed identity, because the
REM   Azure Automation sandbox does not ship the az CLI.)
REM
REM  Prereq:  az login   (and the right subscription selected / set below)
REM ===========================================================================

REM ----------------------------- EDIT THESE ---------------------------------
set "SUBSCRIPTION="
set "INFRA_RG=rg-budget-costguard"
set "LOCATION=eastus"
set "COG_API_VERSION=2023-05-01"

set "BUDGET_AMOUNT=50"
set "BUDGET_THRESHOLD=90"
set "ALERT_EMAIL=you@example.com"
REM (BUDGET_AMOUNT / BUDGET_THRESHOLD above are defaults; override via args 2 and 3)
REM Name prefixes; the target resource name is appended automatically so every
REM resource gets its own clearly-named set (see "Deriving names" below).
set "AUTOMATION_PREFIX=aa-cg"
set "RUNBOOK_PREFIX=DisableLocalAuth"
set "ACTION_GROUP_PREFIX=ag-cg"

REM true  = disable key auth ("disable the key");  false = (re)enable key auth
set "SET_DISABLE_LOCAL_AUTH=true"
REM --------------------------------------------------------------------------

set "RESOURCE_INPUT=%~1"
if "%RESOURCE_INPUT%"=="" (
  echo Usage: %~nx0 ^<resource^> [budget-amount] [threshold-percent]
  exit /b 1
)
if not "%~2"=="" set "BUDGET_AMOUNT=%~2"
if not "%~3"=="" set "BUDGET_THRESHOLD=%~3"
echo Budget amount: %BUDGET_AMOUNT%   Threshold: %BUDGET_THRESHOLD%%%

echo.
echo === [0/9] Selecting subscription ===
if not "%SUBSCRIPTION%"=="" call az account set --subscription "%SUBSCRIPTION%" || goto :error
for /f "usebackq delims=" %%i in (`az account show --query id -o tsv`) do set "SUBSCRIPTION=%%i"
echo Subscription: %SUBSCRIPTION%

echo.
echo === [1/9] Resolving the target resource and its resource group ===
echo %RESOURCE_INPUT% | findstr /b /c:"/subscriptions/" >nul
if errorlevel 1 (
  for /f "usebackq delims=" %%i in (`az resource list --name "%RESOURCE_INPUT%" --resource-type Microsoft.CognitiveServices/accounts --query "[0].id" -o tsv`) do set "COG_RESOURCE_ID=%%i"
) else (
  set "COG_RESOURCE_ID=%RESOURCE_INPUT%"
)
if "%COG_RESOURCE_ID%"=="" (
  echo Could not find a Microsoft.CognitiveServices/accounts resource named "%RESOURCE_INPUT%".
  goto :error
)
for /f "usebackq delims=" %%i in (`az resource show --ids "%COG_RESOURCE_ID%" --query resourceGroup -o tsv`) do set "COG_RG=%%i"
for /f "usebackq delims=" %%i in (`az resource show --ids "%COG_RESOURCE_ID%" --query name -o tsv`) do set "COG_NAME=%%i"
echo Resource : %COG_NAME%
echo Group    : %COG_RG%
echo Id       : %COG_RESOURCE_ID%

REM --- Deriving per-resource names (append the resource name so each set is unique) ---
set "AUTOMATION_ACCOUNT=%AUTOMATION_PREFIX%-%COG_NAME%"
set "RUNBOOK_NAME=%RUNBOOK_PREFIX%-%COG_NAME%"
set "ACTION_GROUP=%ACTION_GROUP_PREFIX%-%COG_NAME%"
REM Action Group short name is capped at 12 chars: strip dashes from the resource
REM name and take the first 12 characters.
set "AG_SHORT_RAW=%COG_NAME:-=%"
set "ACTION_GROUP_SHORT=%AG_SHORT_RAW:~0,12%"
echo Names    : AA=%AUTOMATION_ACCOUNT%  RB=%RUNBOOK_NAME%  AG=%ACTION_GROUP%  short=%ACTION_GROUP_SHORT%

set "AA_RESOURCE_ID=/subscriptions/%SUBSCRIPTION%/resourceGroups/%INFRA_RG%/providers/Microsoft.Automation/automationAccounts/%AUTOMATION_ACCOUNT%"

echo.
echo === [2/9] Creating infra resource group + Automation Account (+ identity) ===
call az group create --name "%INFRA_RG%" --location "%LOCATION%" -o none || goto :error
call az extension add --name automation --upgrade -y -o none
call az automation account create --name "%AUTOMATION_ACCOUNT%" --resource-group "%INFRA_RG%" --location "%LOCATION%" -o none || goto :error
call az rest --method patch --url "https://management.azure.com%AA_RESOURCE_ID%?api-version=2023-11-01" --body "{\"identity\":{\"type\":\"SystemAssigned\"}}" -o none || goto :error

echo Waiting for the managed identity to propagate...
timeout /t 20 /nobreak >nul
for /f "usebackq delims=" %%i in (`az rest --method get --url "https://management.azure.com%AA_RESOURCE_ID%?api-version=2023-11-01" --query "identity.principalId" -o tsv`) do set "PRINCIPAL_ID=%%i"
if "%PRINCIPAL_ID%"=="" goto :error
echo Identity principalId: %PRINCIPAL_ID%

echo.
echo === [3/9] Granting the identity rights on the target resource (idempotent) ===
set "EXISTING_RA="
for /f "usebackq delims=" %%i in (`az role assignment list --assignee "%PRINCIPAL_ID%" --role "Cognitive Services Contributor" --scope "%COG_RESOURCE_ID%" --query "[0].id" -o tsv 2^>nul`) do set "EXISTING_RA=%%i"
if defined EXISTING_RA (
  echo Role assignment already exists, skipping.
) else (
  call az role assignment create --assignee-object-id "%PRINCIPAL_ID%" --assignee-principal-type ServicePrincipal --role "Cognitive Services Contributor" --scope "%COG_RESOURCE_ID%" -o none || goto :error
  echo Role assignment created.
)

echo.
echo === [4/9] Generating the runbook (disable logic embedded, written to TEMP) ===
set "RB=%TEMP%\%RUNBOOK_NAME%.ps1"
> "%RB%" echo param([Parameter(Mandatory=$false)][object]$WebhookData)
>>"%RB%" echo $ErrorActionPreference='Stop'
>>"%RB%" echo $rid='%COG_RESOURCE_ID%'
>>"%RB%" echo $api='%COG_API_VERSION%'
>>"%RB%" echo $disable=$%SET_DISABLE_LOCAL_AUTH%
>>"%RB%" echo # Equivalent of: az resource update -g %COG_RG% -n %COG_NAME% --resource-type Microsoft.CognitiveServices/accounts --set properties.disableLocalAuth=%SET_DISABLE_LOCAL_AUTH%
>>"%RB%" echo $tokenUri=$env:IDENTITY_ENDPOINT + '?resource=https://management.azure.com/^&api-version=2019-08-01'
>>"%RB%" echo $tok=(Invoke-RestMethod -Method Get -Uri $tokenUri -Headers @{'X-IDENTITY-HEADER'=$env:IDENTITY_HEADER}).access_token
>>"%RB%" echo $headers=@{Authorization=('Bearer ' + $tok)}
>>"%RB%" echo $body='{"properties":{"disableLocalAuth":' + $disable.ToString().ToLower() + '}}'
>>"%RB%" echo $uri=('https://management.azure.com' + $rid + '?api-version=' + $api)
>>"%RB%" echo $r=Invoke-RestMethod -Method Patch -Uri $uri -Headers $headers -Body $body -ContentType 'application/json'
>>"%RB%" echo Write-Output ('disableLocalAuth is now ' + $r.properties.disableLocalAuth)

echo.
echo === [5/9] Importing and publishing the runbook (idempotent) ===
set "RB_EXISTS="
for /f "usebackq delims=" %%i in (`az automation runbook show --resource-group "%INFRA_RG%" --automation-account-name "%AUTOMATION_ACCOUNT%" --name "%RUNBOOK_NAME%" --query "name" -o tsv 2^>nul`) do set "RB_EXISTS=%%i"
if defined RB_EXISTS (
  echo Runbook already exists, will replace content.
) else (
  call az automation runbook create --resource-group "%INFRA_RG%" --automation-account-name "%AUTOMATION_ACCOUNT%" --name "%RUNBOOK_NAME%" --type "PowerShell" --location "%LOCATION%" -o none || goto :error
)
call az automation runbook replace-content --resource-group "%INFRA_RG%" --automation-account-name "%AUTOMATION_ACCOUNT%" --name "%RUNBOOK_NAME%" --content "@%RB%" -o none || goto :error
call az automation runbook publish --resource-group "%INFRA_RG%" --automation-account-name "%AUTOMATION_ACCOUNT%" --name "%RUNBOOK_NAME%" -o none || goto :error

echo.
echo === [6/9] Creating the runbook webhook URL (idempotent: delete + recreate) ===
echo NOTE: a webhook URI is write-once, so each run rotates the URL.
call az rest --method delete --url "https://management.azure.com%AA_RESOURCE_ID%/webhooks/%RUNBOOK_NAME%-wh?api-version=2015-10-31" -o none 2>nul
for /f "usebackq delims=" %%i in (`az rest --method post --url "https://management.azure.com%AA_RESOURCE_ID%/webhooks/generateUri?api-version=2015-10-31" -o tsv`) do set "WEBHOOK_URI=%%i"
if "%WEBHOOK_URI%"=="" goto :error
REM Write body to a file via echo (NOT inline with call) so that '%' chars in the
REM webhook token (e.g. %2b, %3d) are not double-expanded by cmd's call processor.
set "WH_JSON=%TEMP%\wh.json"
> "%WH_JSON%" echo {"properties":{"isEnabled":true,"uri":"%WEBHOOK_URI%","expiryTime":"2030-01-01T00:00:00Z","runbook":{"name":"%RUNBOOK_NAME%"}}}
call az rest --method put --url "https://management.azure.com%AA_RESOURCE_ID%/webhooks/%RUNBOOK_NAME%-wh?api-version=2015-10-31" --body "@%WH_JSON%" -o none || goto :error
echo Webhook ready.

echo.
echo === [7/9] Creating the Action Group (Automation Runbook receiver) ===
set "AG_JSON=%TEMP%\actiongroup.json"
> "%AG_JSON%" echo {"location":"Global","properties":{"groupShortName":"%ACTION_GROUP_SHORT%","enabled":true,"automationRunbookReceivers":[{"name":"costguard","automationAccountId":"%AA_RESOURCE_ID%","runbookName":"%RUNBOOK_NAME%","webhookResourceId":"%AA_RESOURCE_ID%/webhooks/%RUNBOOK_NAME%-wh","isGlobalRunbook":false,"serviceUri":"%WEBHOOK_URI%","useCommonAlertSchema":true}]}}
call az rest --method put --url "https://management.azure.com/subscriptions/%SUBSCRIPTION%/resourceGroups/%INFRA_RG%/providers/Microsoft.Insights/actionGroups/%ACTION_GROUP%?api-version=2023-01-01" --body "@%AG_JSON%" -o none || goto :error
for /f "usebackq delims=" %%i in (`az monitor action-group show --name "%ACTION_GROUP%" --resource-group "%INFRA_RG%" --query id -o tsv`) do set "AG_ID=%%i"
if "%AG_ID%"=="" goto :error

echo.
echo === [8/9] Building the budget definition (scoped to this resource) ===
for /f %%i in ('powershell -NoProfile -Command "(Get-Date).ToString('yyyy-MM-01')"') do set "START_DATE=%%i"
for /f %%i in ('powershell -NoProfile -Command "(Get-Date).AddYears(5).ToString('yyyy-MM-01')"') do set "END_DATE=%%i"
set "BUDGET_NAME=costguard-%COG_NAME%"
set "BUDGET_JSON=%TEMP%\budget.json"
> "%BUDGET_JSON%" echo {"properties":{"category":"Cost","amount":%BUDGET_AMOUNT%,"timeGrain":"Monthly","timePeriod":{"startDate":"%START_DATE%T00:00:00Z","endDate":"%END_DATE%T00:00:00Z"},"filter":{"dimensions":{"name":"ResourceId","operator":"In","values":["%COG_RESOURCE_ID%"]}},"notifications":{"BudgetExceeded":{"enabled":true,"operator":"GreaterThanOrEqualTo","threshold":%BUDGET_THRESHOLD%,"thresholdType":"Actual","contactEmails":["%ALERT_EMAIL%"],"contactGroups":["%AG_ID%"]}}}}

echo.
echo === [9/9] Creating the Budget ===
call az rest --method put --url "https://management.azure.com/subscriptions/%SUBSCRIPTION%/resourceGroups/%COG_RG%/providers/Microsoft.Consumption/budgets/%BUDGET_NAME%?api-version=2023-11-01" --body "@%BUDGET_JSON%" -o none || goto :error

echo.
echo ===========================================================================
echo  DONE.
echo    Resource     : %COG_NAME%  (rg: %COG_RG%)
echo    Budget       : %BUDGET_NAME%  amount=%BUDGET_AMOUNT%  alert@%BUDGET_THRESHOLD%%%
echo    Action Group : %ACTION_GROUP%  (Automation Runbook receiver)  -^>  runbook %RUNBOOK_NAME%
echo    On trigger   : disableLocalAuth = %SET_DISABLE_LOCAL_AUTH%
echo.
echo  Test the cost-guard now (without waiting for the budget):
echo    curl -X POST "%WEBHOOK_URI%"
echo ===========================================================================
goto :eof

:error
echo.
echo *** ERROR: a step failed (exit code %errorlevel%). Review the output above. ***
exit /b 1
