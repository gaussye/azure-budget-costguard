@echo off
setlocal EnableDelayedExpansion

REM ===========================================================================
REM  setup-budget-costguard-rg.cmd   (RESOURCE-GROUP scoped variant)
REM
REM  USAGE:
REM     setup-budget-costguard-rg.cmd <resource-group> [budget-amount] [threshold-percent] [alert-email]
REM
REM     <resource-group>     name of the resource group to guard (required)
REM     [budget-amount]      monthly budget, e.g. 50   (optional, default below)
REM     [threshold-percent]  TIER 1 email-only alert threshold %, e.g. 90
REM                          (optional, default below; must be < 100)
REM     [alert-email]        email(s) to receive the budget notifications.
REM                          Multiple emails: comma-separate them AND quote the
REM                          value, e.g. "a@x.com,b@y.com"  (optional)
REM
REM  Two-tier alerting on the RG's monthly cost:
REM     TIER 1  at [threshold-percent]  -> EMAIL ONLY (a heads-up, no enforcement)
REM     TIER 2  at 100%% (hard-wired)    -> EMAIL + Action Group that runs the
REM                                        runbook to disable key auth on every
REM                                        foundry account in the RG.
REM
REM  Unlike the resource-scoped script, this version watches the WHOLE resource
REM  group's monthly cost. When the budget threshold is crossed it wires up:
REM
REM     Budget alert (RG scope) -> Action Group (webhook) -> Automation Runbook
REM                  -> runbook lists EVERY foundry resource in the RG
REM                     (Microsoft.CognitiveServices/accounts, kind = AIServices)
REM                     and disables local (key) auth on each one.
REM
REM  The disable step is the equivalent of, for each foundry account found:
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
set "COG_API_VERSION=2026-05-01"

set "BUDGET_AMOUNT=50"
set "BUDGET_THRESHOLD=90"
set "ALERT_EMAIL=you@example.com"
REM (BUDGET_AMOUNT / BUDGET_THRESHOLD / ALERT_EMAIL above are defaults;
REM  override via args 2, 3 and 4 respectively.)
REM Two-tier alerting:
REM   Tier 1 = BUDGET_THRESHOLD (user-set, arg 3): EMAIL ONLY, no enforcement.
REM   Tier 2 = ENFORCE_THRESHOLD (hard-wired 100): EMAIL + Action Group that
REM            disables key auth. Do NOT change this; enforcement fires at 100%%.
set "ENFORCE_THRESHOLD=100"
REM Name prefixes; the target resource group name is appended automatically so
REM every guarded RG gets its own clearly-named set.
set "AUTOMATION_PREFIX=aa-cg"
set "RUNBOOK_PREFIX=DisableLocalAuth"
set "ACTION_GROUP_PREFIX=ag-cg"

REM Foundry accounts are Microsoft.CognitiveServices/accounts with this kind.
set "FOUNDRY_KIND=AIServices"

REM true  = disable key auth ("disable the key");  false = (re)enable key auth
set "SET_DISABLE_LOCAL_AUTH=true"
REM --------------------------------------------------------------------------

set "TARGET_RG=%~1"
if "%TARGET_RG%"=="" (
  echo Usage: %~nx0 ^<resource-group^> [budget-amount] [threshold-percent] [alert-email]
  exit /b 1
)
if not "%~2"=="" set "BUDGET_AMOUNT=%~2"
if not "%~3"=="" set "BUDGET_THRESHOLD=%~3"
if not "%~4"=="" set "ALERT_EMAIL=%~4"
REM The email-only tier must be strictly below the 100%% enforcement tier so the
REM two notifications are distinct and the email fires before key auth is cut.
if %BUDGET_THRESHOLD% GEQ %ENFORCE_THRESHOLD% (
  echo ERROR: threshold-percent must be less than %ENFORCE_THRESHOLD% ^(the email tier fires before the 100%% enforcement tier^).
  exit /b 1
)
REM Support multiple, comma-separated emails. Strip spaces, then turn the list
REM into a JSON array: "a@x.com,b@y.com" -> ["a@x.com","b@y.com"].
REM NOTE: because cmd treats commas as argument separators, a multi-email value
REM MUST be passed quoted, e.g. "a@x.com,b@y.com".
set "ALERT_EMAIL=%ALERT_EMAIL: =%"
set "ALERT_EMAILS_JSON=["%ALERT_EMAIL:,=","%"]"
echo Tier 1 email-only  : %BUDGET_THRESHOLD%%%   (email: %ALERT_EMAIL%)
echo Tier 2 enforce+key : %ENFORCE_THRESHOLD%%%   (email + disable key auth)
echo Budget amount: %BUDGET_AMOUNT%

echo.
echo === [0/9] Selecting subscription ===
if not "%SUBSCRIPTION%"=="" call az account set --subscription "%SUBSCRIPTION%" || goto :error
for /f "usebackq delims=" %%i in (`az account show --query id -o tsv`) do set "SUBSCRIPTION=%%i"
echo Subscription: %SUBSCRIPTION%

echo.
echo === [1/9] Resolving the target resource group ===
for /f "usebackq delims=" %%i in (`az group show --name "%TARGET_RG%" --query name -o tsv 2^>nul`) do set "RG_FOUND=%%i"
if "%RG_FOUND%"=="" (
  echo Could not find a resource group named "%TARGET_RG%".
  goto :error
)
set "TARGET_RG_ID=/subscriptions/%SUBSCRIPTION%/resourceGroups/%TARGET_RG%"
echo Resource group : %TARGET_RG%
echo Scope id       : %TARGET_RG_ID%

echo Foundry (kind=%FOUNDRY_KIND%) accounts currently in this RG:
call az cognitiveservices account list --resource-group "%TARGET_RG%" --query "[?kind=='%FOUNDRY_KIND%'].name" -o tsv

REM --- Deriving per-RG names (append the RG name so each set is unique) ---
REM Azure resource names (e.g. Automation Account) allow only letters, numbers
REM and hyphens, so replace any underscores in the RG name with hyphens.
set "RG_SAFE=%TARGET_RG:_=-%"
set "AUTOMATION_ACCOUNT=%AUTOMATION_PREFIX%-%RG_SAFE%"
set "RUNBOOK_NAME=%RUNBOOK_PREFIX%-%RG_SAFE%"
set "ACTION_GROUP=%ACTION_GROUP_PREFIX%-%RG_SAFE%"
REM Action Group short name is capped at 12 chars and must be alphanumeric:
REM strip both underscores and dashes from the RG name, then take 12 chars.
set "AG_SHORT_RAW=%TARGET_RG:_=%"
set "AG_SHORT_RAW=%AG_SHORT_RAW:-=%"
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
ping -n 21 127.0.0.1 >nul
for /f "usebackq delims=" %%i in (`az rest --method get --url "https://management.azure.com%AA_RESOURCE_ID%?api-version=2023-11-01" --query "identity.principalId" -o tsv`) do set "PRINCIPAL_ID=%%i"
if "%PRINCIPAL_ID%"=="" goto :error
echo Identity principalId: %PRINCIPAL_ID%

echo.
echo === [3/9] Granting the identity rights on the WHOLE resource group (idempotent) ===
set "EXISTING_RA="
for /f "usebackq delims=" %%i in (`az role assignment list --assignee "%PRINCIPAL_ID%" --role "Cognitive Services Contributor" --scope "%TARGET_RG_ID%" --query "[0].id" -o tsv 2^>nul`) do set "EXISTING_RA=%%i"
if defined EXISTING_RA (
  echo Role assignment already exists, skipping.
) else (
  call az role assignment create --assignee-object-id "%PRINCIPAL_ID%" --assignee-principal-type ServicePrincipal --role "Cognitive Services Contributor" --scope "%TARGET_RG_ID%" -o none || goto :error
  echo Role assignment created.
)

echo.
echo === [4/9] Generating the runbook (enumerates foundry accounts in the RG) ===
set "RB=%TEMP%\%RUNBOOK_NAME%.ps1"
> "%RB%" echo param([Parameter(Mandatory=$false)][object]$WebhookData)
>>"%RB%" echo $ErrorActionPreference='Stop'
>>"%RB%" echo $sub='%SUBSCRIPTION%'
>>"%RB%" echo $rg='%TARGET_RG%'
>>"%RB%" echo $api='%COG_API_VERSION%'
>>"%RB%" echo $kind='%FOUNDRY_KIND%'
>>"%RB%" echo $disable=$%SET_DISABLE_LOCAL_AUTH%
>>"%RB%" echo $tokenUri=$env:IDENTITY_ENDPOINT + '?resource=https://management.azure.com/^&api-version=2019-08-01'
>>"%RB%" echo $tok=(Invoke-RestMethod -Method Get -Uri $tokenUri -Headers @{'X-IDENTITY-HEADER'=$env:IDENTITY_HEADER}).access_token
>>"%RB%" echo $headers=@{Authorization=('Bearer ' + $tok)}
>>"%RB%" echo $listUri=('https://management.azure.com/subscriptions/' + $sub + '/resourceGroups/' + $rg + '/providers/Microsoft.CognitiveServices/accounts?api-version=' + $api)
>>"%RB%" echo $accounts=(Invoke-RestMethod -Method Get -Uri $listUri -Headers $headers).value
>>"%RB%" echo $foundry=$accounts ^| Where-Object { $_.kind -eq $kind }
>>"%RB%" echo if (-not $foundry) { Write-Output ('No ' + $kind + ' (foundry) accounts found in ' + $rg); return }
>>"%RB%" echo foreach ($a in $foundry) {
>>"%RB%" echo $body='{"properties":{"disableLocalAuth":' + $disable.ToString().ToLower() + '}}'
>>"%RB%" echo $uri=('https://management.azure.com' + $a.id + '?api-version=' + $api)
>>"%RB%" echo $r=Invoke-RestMethod -Method Patch -Uri $uri -Headers $headers -Body $body -ContentType 'application/json'
>>"%RB%" echo Write-Output ($a.name + ': disableLocalAuth is now ' + $r.properties.disableLocalAuth)
>>"%RB%" echo }

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
echo === [8/9] Building the budget definition (scoped to the WHOLE resource group) ===
for /f %%i in ('powershell -NoProfile -Command "(Get-Date).ToString('yyyy-MM-01')"') do set "START_DATE=%%i"
for /f %%i in ('powershell -NoProfile -Command "(Get-Date).AddYears(5).ToString('yyyy-MM-01')"') do set "END_DATE=%%i"
set "BUDGET_NAME=costguard-%TARGET_RG%"
set "BUDGET_JSON=%TEMP%\budget.json"
REM Two-tier notifications:
REM   Tier 1 (user threshold %BUDGET_THRESHOLD%%%): EMAIL ONLY  -> no action group.
REM   Tier 2 (hard-wired %ENFORCE_THRESHOLD%%%):    EMAIL + ACTION GROUP -> disables key auth.
> "%BUDGET_JSON%" echo {"properties":{"category":"Cost","amount":%BUDGET_AMOUNT%,"timeGrain":"Monthly","timePeriod":{"startDate":"%START_DATE%T00:00:00Z","endDate":"%END_DATE%T00:00:00Z"},"notifications":{"Actual_Email_%BUDGET_THRESHOLD%":{"enabled":true,"operator":"GreaterThanOrEqualTo","threshold":%BUDGET_THRESHOLD%,"thresholdType":"Actual","contactEmails":%ALERT_EMAILS_JSON%},"Actual_Enforce_%ENFORCE_THRESHOLD%":{"enabled":true,"operator":"GreaterThanOrEqualTo","threshold":%ENFORCE_THRESHOLD%,"thresholdType":"Actual","contactEmails":%ALERT_EMAILS_JSON%,"contactGroups":["%AG_ID%"]}}}}

echo.
echo === [9/9] Creating the Budget (at resource-group scope) ===
call az rest --method put --url "https://management.azure.com/subscriptions/%SUBSCRIPTION%/resourceGroups/%TARGET_RG%/providers/Microsoft.Consumption/budgets/%BUDGET_NAME%?api-version=2023-11-01" --body "@%BUDGET_JSON%" -o none || goto :error

echo.
echo ===========================================================================
echo  DONE.
echo    Resource grp : %TARGET_RG%
echo    Budget       : %BUDGET_NAME%  amount=%BUDGET_AMOUNT%  (RG scope)
echo    Tier 1       : at %BUDGET_THRESHOLD%%%  -^>  EMAIL ONLY to %ALERT_EMAIL%
echo    Tier 2       : at %ENFORCE_THRESHOLD%%%  -^>  EMAIL + Action Group %ACTION_GROUP%
echo    On tier 2    : runbook %RUNBOOK_NAME% disables key auth on EVERY kind=%FOUNDRY_KIND% account in the RG
echo.
echo  Test the cost-guard now (without waiting for the budget):
echo    curl -X POST "%WEBHOOK_URI%"
echo ===========================================================================
goto :eof

:error
echo.
echo *** ERROR: a step failed (exit code %errorlevel%). Review the output above. ***
exit /b 1
