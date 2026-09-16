#Requires -Version 5.1
<#
.SYNOPSIS
    End-to-end deployment script for the JWT Issuer Azure Function.

.DESCRIPTION
    Checks prerequisites, authenticates to Azure, creates the Entra ID app
    registration, deploys all infrastructure via Bicep, creates the signing
    certificate in Key Vault, and deploys the function code.

    Re-running the script is safe: each step is idempotent.

.PARAMETER ResourceGroup
    Name of the Azure resource group (will be created if it does not exist).

.PARAMETER Location
    Azure region, e.g. 'australiaeast'.

.PARAMETER BaseName
    Short base name for all resource names (max 17 lowercase alphanumeric chars
    and hyphens). Produces: kv-<name>, func-<name>, asp-<name>, etc.

.EXAMPLE
    .\deploy.ps1
    .\deploy.ps1 -ResourceGroup my-rg -Location australiaeast -BaseName jwtissuer-dev
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = '',
    [string]$Location      = '',
    [string]$BaseName      = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir   = $PSScriptRoot
$BicepFile   = Join-Path $ScriptDir 'infra' 'main.bicep'
$BicepParams = Join-Path $ScriptDir 'infra' 'main.bicepparam'
$ProjectDir  = Join-Path $ScriptDir 'src' 'JwtIssuer'
$PublishDir  = Join-Path $ProjectDir 'publish'
$ZipPath     = Join-Path $ProjectDir 'function.zip'

# ── Output helpers ─────────────────────────────────────────────────────────────

function Write-Banner([string]$Text) {
    $line = '═' * ([Math]::Max(60, $Text.Length + 4))
    Write-Host "`n$line"             -ForegroundColor DarkCyan
    Write-Host "  $Text"             -ForegroundColor Cyan
    Write-Host "$line`n"             -ForegroundColor DarkCyan
}

function Write-Step([string]$Text) {
    Write-Host "`n● $Text" -ForegroundColor Cyan
}

function Write-Ok([string]$Text)   { Write-Host "  ✓  $Text" -ForegroundColor Green  }
function Write-Info([string]$Text) { Write-Host "     $Text" -ForegroundColor Gray   }
function Write-Warn([string]$Text) { Write-Host "  ⚠  $Text" -ForegroundColor Yellow }

function Fail([string]$Text) {
    Write-Host "`n  ✗  $Text`n" -ForegroundColor Red
    exit 1
}

function Read-NonEmpty([string]$Prompt, [string]$Default = '') {
    $hint = if ($Default) { " [$Default]" } else { '' }
    $value = (Read-Host "  $Prompt$hint").Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
    if ([string]::IsNullOrWhiteSpace($value)) { Fail "A value is required for '$Prompt'." }
    return $value
}

function Confirm-Action([string]$Question) {
    do { $r = (Read-Host "  $Question [y/n]").Trim().ToLower() } while ($r -notin 'y','n')
    return $r -eq 'y'
}

# Runs an az CLI command and returns parsed JSON.
# $Arguments is an array of tokens (no --output needed; caller adds it if required).
function Invoke-Az([string[]]$Arguments, [switch]$AllowFailure) {
    $result = az @Arguments --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ($AllowFailure) { return $null }
        $msg = ($result | Where-Object { $_ -match '^\s*(ERROR|error)' } | Select-Object -First 1)
        if (-not $msg) { $msg = ($result | Select-Object -Last 3) -join ' ' }
        Fail "az $($Arguments[0]): $msg"
    }
    # az output arrives as a string array (one element per line). Join before parsing so
    # ConvertFrom-Json receives a single JSON string rather than individual fragments.
    # Also filter out ErrorRecord objects that 2>&1 can inject from stderr.
    $jsonText = ($result | Where-Object { $_ -is [string] }) -join "`n"
    try   { return $jsonText | ConvertFrom-Json }
    catch { return $result }
}

# ═══════════════════════════════════════════════════════════════════════════════

Write-Banner 'JWT Issuer — Deployment'

# ── 1. Prerequisites ──────────────────────────────────────────────────────────

Write-Step 'Checking prerequisites'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Fail 'Azure CLI not found. Install it from https://learn.microsoft.com/cli/azure/install-azure-cli'
}
$azVer = (az version --output json | ConvertFrom-Json).'azure-cli'
Write-Ok "Azure CLI $azVer"

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Fail '.NET SDK not found. Install .NET 10 from https://dotnet.microsoft.com/download'
}
$dotnetVer = (dotnet --version).Trim()
$dotnetVerClean = $dotnetVer -replace '-.*$', ''
if ([Version]$dotnetVerClean -lt [Version]'10.0') {
    Fail ".NET 10.0+ required (found $dotnetVer). Download from https://dotnet.microsoft.com/download"
}
Write-Ok ".NET SDK $dotnetVer"

Write-Info 'Updating Bicep CLI...'
az bicep upgrade 2>&1 | Out-Null
$bicepVer = (az bicep version 2>&1) -replace '^Bicep CLI version ', ''
Write-Ok "Bicep $bicepVer"

if (-not (Test-Path $BicepFile))   { Fail "Bicep template not found: $BicepFile" }
if (-not (Test-Path $ProjectDir))  { Fail ".NET project not found: $ProjectDir" }

# ── 2. Azure authentication ────────────────────────────────────────────────────

Write-Step 'Azure authentication'

$azRaw = az account show --output json 2>$null
if ($LASTEXITCODE -ne 0 -or -not $azRaw) {
    Write-Info 'Not signed in. Launching browser login...'
    az login 2>&1 | Out-Null
    $azRaw = az account show --output json 2>&1
    if ($LASTEXITCODE -ne 0) { Fail 'Login failed. Run "az login" manually and retry.' }
}
$account       = $azRaw | ConvertFrom-Json
$tenantId      = $account.tenantId
$subscriptionId = $account.id

Write-Ok "Signed in as  : $($account.user.name)"
Write-Info "Subscription  : $($account.name)  ($subscriptionId)"
Write-Info "Tenant        : $tenantId"

# ── 3. Deployment parameters ──────────────────────────────────────────────────

Write-Step 'Deployment parameters'

if ([string]::IsNullOrWhiteSpace($ResourceGroup)) {
    $ResourceGroup = Read-NonEmpty 'Resource group name' 'ae-jwtissuer-rg'
}
if ([string]::IsNullOrWhiteSpace($Location)) {
    $Location = Read-NonEmpty 'Azure region' 'australiaeast'
}
if ([string]::IsNullOrWhiteSpace($BaseName)) {
    # Suggest a name derived from the resource group
    $suggested = ($ResourceGroup -replace '^[a-z]+-?', '' -replace '-?rg$', '')
    if ($suggested.Length -gt 17) { $suggested = $suggested.Substring(0, 17) }
    $BaseName = Read-NonEmpty 'Base resource name (max 17 chars)' $suggested
}

if ($BaseName.Length -gt 17) { Fail "Base name must be ≤ 17 characters (got $($BaseName.Length))." }
if ($BaseName -notmatch '^[a-z0-9][a-z0-9\-]*$') {
    Fail "Base name must be lowercase alphanumeric with hyphens (got '$BaseName')."
}

# Derived resource names — must match infra/main.bicep
$KvName       = "kv-$BaseName"
$FuncName     = "func-$BaseName"
$PlanName     = "asp-$BaseName"
$StorageName  = "st$($BaseName -replace '-', '')"
$AppRegName   = "$BaseName-auth"
$CertName     = 'jwt-signing-cert'

Write-Host ''
Write-Info "Resource Group    : $ResourceGroup"
Write-Info "Location          : $Location"
Write-Info "Base name         : $BaseName"
Write-Info "Key Vault         : $KvName"
Write-Info "Function App      : $FuncName"
Write-Info "App Registration  : $AppRegName"
Write-Host ''

if (-not (Confirm-Action 'Proceed with these parameters?')) {
    Write-Host '  Aborted.' -ForegroundColor Yellow; exit 0
}

# ── 4. Resource group ─────────────────────────────────────────────────────────

Write-Step 'Resource group'

$rg = Invoke-Az @('group', 'show', '--name', $ResourceGroup) -AllowFailure
if ($rg) {
    Write-Ok "Using existing resource group ($($rg.location))"
} else {
    Write-Info "Creating $ResourceGroup in $Location..."
    Invoke-Az @('group', 'create', '--name', $ResourceGroup, '--location', $Location) | Out-Null
    Write-Ok "Resource group created"
}

# ── 5. Entra ID App Registration ──────────────────────────────────────────────

Write-Step 'Entra ID App Registration'

$existingApps = Invoke-Az @('ad', 'app', 'list', '--display-name', $AppRegName)
$app = if ($existingApps -is [Array]) { $existingApps[0] } else { $existingApps }

if ($app -and $app.appId) {
    Write-Ok "Found existing app registration  (appId: $($app.appId))"
} else {
    Write-Info "Creating app registration '$AppRegName'..."
    $app = Invoke-Az @('ad', 'app', 'create',
        '--display-name', $AppRegName,
        '--sign-in-audience', 'AzureADMyOrg')
    Write-Ok "App registration created  (appId: $($app.appId))"
}
$AppId = $app.appId

# Ensure Token.Request app role exists
$existingRole = $app.appRoles | Where-Object { $_.value -eq 'Token.Request' }
if ($existingRole) {
    Write-Ok 'App role Token.Request already exists'
} else {
    Write-Info 'Adding Token.Request app role...'
    $roleId   = [System.Guid]::NewGuid().ToString()
    $appRoles = @(
        @{
            id                 = $roleId
            displayName        = 'Token Request'
            description        = 'Allows a service principal to request issued JWT tokens'
            value              = 'Token.Request'
            allowedMemberTypes = @('Application')
            isEnabled          = $true
        }
    ) | ConvertTo-Json -Depth 5 -Compress
    Invoke-Az @('ad', 'app', 'update', '--id', $AppId, '--app-roles', $appRoles) | Out-Null
    Write-Ok 'App role Token.Request added'
}

# Ensure the enterprise application (service principal) exists
$sp = Invoke-Az @('ad', 'sp', 'show', '--id', $AppId) -AllowFailure
if ($sp -and $sp.id) {
    Write-Ok 'Enterprise application already exists'
} else {
    Write-Info 'Creating enterprise application...'
    Invoke-Az @('ad', 'sp', 'create', '--id', $AppId) | Out-Null
    Write-Ok 'Enterprise application created'
}

# ── 6. Pre-deployment check: Windows→Linux migration ─────────────────────────

Write-Step 'Pre-deployment checks'

$existingFunc = Invoke-Az @('functionapp', 'show',
    '--resource-group', $ResourceGroup, '--name', $FuncName) -AllowFailure

if ($existingFunc -and $existingFunc.kind -and ($existingFunc.kind -notlike '*linux*')) {
    Write-Warn "Existing Function App '$FuncName' runs on Windows."
    Write-Warn "It must be deleted before deploying as Linux Flex Consumption."
    Write-Warn "Will delete: $FuncName, $PlanName, $StorageName"
    if (-not (Confirm-Action 'Delete the Windows resources and continue?')) {
        Write-Host '  Aborted.' -ForegroundColor Yellow; exit 0
    }
    Write-Info "Deleting Function App $FuncName..."
    az functionapp delete --resource-group $ResourceGroup --name $FuncName 2>&1 | Out-Null
    Write-Info "Deleting App Service Plan $PlanName..."
    az appservice plan delete --resource-group $ResourceGroup --name $PlanName --yes 2>&1 | Out-Null
    Write-Info "Deleting Storage Account $StorageName..."
    az storage account delete --resource-group $ResourceGroup --name $StorageName --yes 2>&1 | Out-Null
    Write-Ok 'Windows resources deleted'
} else {
    Write-Ok 'No conflicting resources found'
}

# ── 7. Bicep deployment ────────────────────────────────────────────────────────

Write-Step 'Infrastructure deployment (Bicep)'

Write-Info 'Deploying resources — this typically takes 3–5 minutes...'

$deployArgs = @(
    'deployment', 'group', 'create'
    '--resource-group', $ResourceGroup
    '--template-file',  $BicepFile
    '--parameters',     $BicepParams
    '--parameters',     "baseName=$BaseName"
    '--parameters',     "location=$Location"
    '--parameters',     "aadTenantId=$tenantId"
    '--parameters',     "aadClientId=$AppId"
)

$deployResult = Invoke-Az $deployArgs
$outputs = $deployResult.properties.outputs

if (-not $outputs) { Fail 'Bicep deployment returned no outputs. Check the Azure portal for details.' }

$FuncUrl      = $outputs.functionAppUrl.value
$TokenUrl     = $outputs.tokenEndpoint.value
$JwksUrl      = $outputs.jwksEndpoint.value
$OidcUrl      = $outputs.oidcDiscoveryEndpoint.value
$AppInsName   = $outputs.appInsightsName.value

Write-Ok "Infrastructure deployed"
Write-Info "Function App URL : $FuncUrl"
Write-Info "App Insights     : $AppInsName"

# ── 8. Signing certificate ─────────────────────────────────────────────────────

Write-Step 'Signing certificate'

# Resolve the deployer's Entra object ID (works for user logins; may fail for SP logins)
$KvId   = (az keyvault show --name $KvName --resource-group $ResourceGroup --query id --output tsv 2>&1)
$MyOid  = (az ad signed-in-user show --query id --output tsv 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $MyOid) {
    Write-Warn 'Could not resolve signed-in user OID (service principal login?).'
    $MyOid = (Read-NonEmpty "Enter your Entra ID object ID for Key Vault cert access")
}

# Check if the certificate already exists
$existingCert = Invoke-Az @('keyvault', 'certificate', 'show',
    '--vault-name', $KvName, '--name', $CertName) -AllowFailure

if ($existingCert -and $existingCert.id) {
    Write-Ok "Certificate '$CertName' already exists — skipping creation"
} else {
    # Grant Key Vault Certificates Officer to the deployer
    Write-Info 'Granting Key Vault Certificates Officer role to deployer...'
    az role assignment create `
        --role 'Key Vault Certificates Officer' `
        --assignee $MyOid `
        --scope $KvId `
        --output none 2>&1 | Out-Null   # Silently ignore if already assigned

    # Role assignments can take up to 5 minutes to propagate through AAD.
    Write-Info 'Waiting for IAM role assignment to propagate (up to 60 s)...'
    for ($s = 60; $s -gt 0; $s -= 5) {
        Write-Host "`r     $s seconds remaining... " -NoNewline
        Start-Sleep -Seconds 5
    }
    Write-Host ''

    $certPolicy = @{
        keyProperties             = @{
            keyType    = 'RSA'; keySize = 2048
            reuseKey   = $false; exportable = $false
        }
        secretProperties          = @{ contentType = 'application/x-pkcs12' }
        x509CertificateProperties = @{
            subject = "CN=$CertName"; validityInMonths = 12
        }
        lifetimeActions = @(
            @{ action = @{ actionType = 'AutoRenew' }; trigger = @{ daysBeforeExpiry = 30 } }
        )
        issuerParameters = @{ name = 'Self' }
    } | ConvertTo-Json -Depth 10 -Compress

    Write-Info 'Creating self-signed certificate (with auto-renew at 30 days before expiry)...'
    $maxAttempts = 5
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $certOut = az keyvault certificate create `
            --vault-name $KvName `
            --name $CertName `
            --policy $certPolicy `
            --output json 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "Certificate created"
            break
        }
        if ($attempt -eq $maxAttempts) {
            Fail "Certificate creation failed after $maxAttempts attempts.`n$certOut"
        }
        Write-Warn "Attempt $attempt failed (role propagation may still be in progress) — retrying in 20 s..."
        Start-Sleep -Seconds 20
    }
}

# ── 9. Build and deploy function code ─────────────────────────────────────────

Write-Step 'Function code deployment'

Write-Info 'Building .NET project...'
$buildOutput = dotnet publish (Join-Path $ProjectDir 'JwtIssuer.csproj') `
    --configuration Release --output $PublishDir --nologo 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host $buildOutput
    Fail 'dotnet publish failed. See output above.'
}
Write-Ok 'Build succeeded'

Write-Info 'Creating deployment package...'
if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
Push-Location $PublishDir
try {
    # Compress-Archive -Path * silently skips hidden items (e.g. .azurefunctions)
    # on macOS/Linux because * does not match dotfiles. Get-ChildItem -Force includes them.
    Get-ChildItem -Force | Compress-Archive -DestinationPath $ZipPath -Force
} finally {
    Pop-Location
}
$sizeMB = [Math]::Round((Get-Item $ZipPath).Length / 1MB, 1)
Write-Ok "Package created ($sizeMB MB)"

# Flex Consumption loads code from the specific blob URL set in
# functionAppConfig.deployment.storage.value (Bicep: deployments/function.zip).
# Upload the zip to that exact path, then trigger a Kudu deployment via the
# ARM extensions/onedeploy API (a plain restart does NOT re-trigger Kudu).
Write-Info 'Uploading deployment package to blob storage...'
$storageKey = (az storage account keys list `
    --resource-group $ResourceGroup `
    --account-name $StorageName `
    --query '[0].value' `
    --output tsv 2>&1)
if ($LASTEXITCODE -ne 0) { Fail "Cannot retrieve storage account key: $storageKey" }

az storage blob upload `
    --account-name $StorageName `
    --account-key $storageKey `
    --container-name 'deployments' `
    --name 'function.zip' `
    --file $ZipPath `
    --overwrite `
    --output none 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Fail 'Failed to upload deployment package to blob storage.' }
Write-Ok "Package uploaded ($sizeMB MB)"

Write-Info 'Generating deployment SAS URL (valid 1 h)...'
$sasExpiry = (Get-Date).AddHours(1).ToUniversalTime().ToString('yyyy-MM-ddTHH:mmZ')
$sasToken = az storage blob generate-sas `
    --account-name $StorageName `
    --account-key $storageKey `
    --container-name 'deployments' `
    --name 'function.zip' `
    --permissions r `
    --expiry $sasExpiry `
    --https-only `
    --output tsv 2>&1
if ($LASTEXITCODE -ne 0) { Fail 'Failed to generate SAS token for deployment package.' }
$blobSasUrl = "https://$StorageName.blob.core.windows.net/deployments/function.zip?$sasToken"

# az functionapp deploy is buggy in CLI 2.89 (HTTP 415 for --src-path; JSONDecodeError
# for --src-url). Call the ARM extensions/onedeploy API directly; --output none means
# az rest never parses the response body, sidestepping both crashes.
Write-Info 'Triggering Kudu deployment via ARM extensions/onedeploy...'
$bodyFile = [System.IO.Path]::GetTempFileName()
try {
    @{ properties = @{ type = 'zip'; packageUri = $blobSasUrl } } |
        ConvertTo-Json -Depth 3 | Set-Content $bodyFile -Encoding UTF8
    $restOut = az rest `
        --method PUT `
        --uri "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$FuncName/extensions/onedeploy?api-version=2023-12-01" `
        --body "@$bodyFile" `
        --output none 2>&1
} finally {
    Remove-Item $bodyFile -ErrorAction SilentlyContinue
}
if ($LASTEXITCODE -ne 0) {
    Write-Host ($restOut -join "`n")
    Fail 'Failed to trigger Kudu deployment.'
}
Write-Info 'Waiting for the function app to start (cold start, up to 5 min)...'
$deadline = (Get-Date).AddMinutes(5)
$alive    = $false
while ((Get-Date) -lt $deadline) {
    try {
        $null = Invoke-WebRequest -Uri $JwksUrl -Method GET `
            -TimeoutSec 8 -UseBasicParsing -ErrorAction Stop
        $alive = $true; break
    } catch { }
    $rem = [int]($deadline - (Get-Date)).TotalSeconds
    Write-Host "`r     Waiting for cold start... ($rem s remaining)  " -NoNewline
    Start-Sleep -Seconds 8
}
Write-Host ''

if ($alive) {
    Write-Ok 'Code deployed and function app is responding'
} else {
    Write-Warn 'JWKS endpoint did not respond within 5 min.'
    Write-Warn "Deployment may still be in progress — check: $JwksUrl"
}

# ── 10. Summary ───────────────────────────────────────────────────────────────

Write-Banner 'Deployment complete'

$col1 = 22
$fmt  = "  {0,-$col1} {1}"
Write-Host ($fmt -f 'Token endpoint',       $TokenUrl)
Write-Host ($fmt -f 'JWKS',                 $JwksUrl)
Write-Host ($fmt -f 'OIDC discovery',       $OidcUrl)
Write-Host ''
Write-Host ($fmt -f 'App Registration',     "$AppRegName  ($AppId)")
Write-Host ($fmt -f 'Tenant',               $tenantId)
Write-Host ($fmt -f 'Application Insights', $AppInsName)
Write-Host ''
Write-Host '  To let a Managed Identity call /token:' -ForegroundColor Gray
Write-Host "    1. Find its service principal object ID in Entra ID." -ForegroundColor Gray
Write-Host "    2. Assign the 'Token.Request' app role on '$AppRegName'." -ForegroundColor Gray
Write-Host "    See README.md for the az rest command." -ForegroundColor Gray
Write-Host ''
