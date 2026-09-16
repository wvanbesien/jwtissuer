# JWT Issuer — Azure Function

## Problem we're solving

Devices with managed identities in Azure or Azure ARC can request JWT tokens for applications. While normally JWT tokens issued by Entra ID have an expiry of between 60~90mins, for managed identities the expiry is 24h, and this doesn't appear to be something that can be changed. 

Some applications, do not accept tokens that are that long lived. The purpose of this function is to be a sort of intermediary that issues a new JWT to the requester provided they submit a valid Entra ID issued JWT along with the request. 

Please note the issued token isn't a replacement for an Entra ID token. However, we have used them successfully in scenarios using Workload identity federation, where this token is then again exchanged for a new token.

An example of this is using an Arc Managed Identity to request a certificate from a Palo Alto (Venafi) Certificate Manager SaaS instance.

## How it works

```
Caller (with Managed Identity)
  │
  │  Requests token from Entra ID for a specific app registration (associated with the function app). 
  │  Entra ID issues token
  ▼
Azure Function (Easy Auth validates the bearer token)
  │
  │  Request is submitted to function app, usign the Entra ID issued JWT. 
  |  Function creates the payload, submits to Azure Key Vault for signing.
  ▼
Azure Key Vault
  │  Sign payload. Private key never leaves Azure Key Vault
  │  Returns: signature signed JWT to function
  ▼
Function 
  |
  | returns signed JWT 
  |
  ▼
Caller
  | 
  | Caller uses this JWT to request an access token from Certificate Manager SaaS (CMSaaS)
  |
  ▼
CMSaaS
  |
  | validates the signature of the JWT
  | issues new JWT specific for CmSaaS
  ▼
Caller
  | 
  | requests certificate from CMSaas using the CMSaaS issued token

```

The JWKS endpoint (`GET /jwks`) is public and lists the RSA public keys for all
currently-valid certificate versions, so token validators can discover keys without
any authentication.

This flow uses workload identity federation. Within CMSaaS we provide a configuration allowing CMSaaS to trust tokens issues by our Function. The configuration steps for this are listed below.

---

### Project files

This repository contains the source files of the Function (/src) as well as a deploy.ps1 script and bicep templates that can be used to deploy this. You are not required to use this and is provided for convenience. 

Details are listed below on how to use the scripts.

# Deployment steps
The steps listed here can be followed to set up the solution manually. You can use the convenience scripts which will be faster but less flexible.

## Azure Key Vault

The solution requires one Azure Key Vault. This can be either standard or premium, both are supported

Within the key vault, create a certificate.
- For the subject specify: "CN=something". This can be any value and is irrelevant. 
- Set the desired expiry (for example 3 months) and set up the policy to automatically renew the certificate when close to expiry. 
(Recommended to set a validity of 3 months, and renewal when 30 days remain.)

## Azure Function App
A function app requires a storage account, log analytics and Application Insights, they can all be deployed alongside the Function app, so you do not necessarily have to create these manually.

1. in the Azure portal, create a new Function 
1. select **flex consumption** as the type
1. select the same location as the Azure Key Vault, and select
- runtime stack: .NET
- version: 10 LTS
- instance size: 512MB 
4. for most of the settings defaults will work but,
- enable public access
- do not create a durable task scheduler resource

## Set up App Registration

Create a new app registration, just give it a name and click create (no other settings required at this stage).
After the app registration has been created, do the following:

-  go to **Expose an API**. Click the **Add** button next to "application ID URI. Accept the default value. 
-  go to **app roles**. Create an app role with following settings:
  - display name: Token Request
  - Allowed member types: both
  - value: Token.Request

## Configure Function App

### Setup authentication in Function App

1. Go to the function you previously created, and go to **settings - Authentication**
1. Click on **Add Identity provider**
1. Select **Microsoft**
- select **workforce configuration**
- select **pick an existing app registration in this directory** and select the app registration you previoulsy created. 
- **Allow requests from any application**
- **Allow requests from any identity**
- **use default restrictions based on issuer**

### Grant function access to key vault

1. go to the function you previously created, and go to **settings - identity**
1. enable the system assigned identity. 
1. go to the Azure Key Vault and go to **Access control**
1. click **add - Add Role assignment**
1. select **Key vault crypto user** and assign the function app to this role. Also assigned the function app to the **Key vault certificate user**. 

### Configuration Environment variables

The Function App requires several settings to function. 

Go to **Settings - Environment variables - App Settings**
Add the following settings and set the values: 


| Name | Value |
|---|---|
| CertificateName | set name of the certificate |
| JwtIssuer | set to the address of the function app (this is the value set in the token). ex. https://func-jwtissuer.azurewebsites.net |
| KeyVaultUri | set to the ULR of the keyvault ex. https://keyvault.vault.azure.net |
| TokenLifetimeMinutes | set the expiry of the issued token, in minutes. ex. 15 |


## Grant the managed identity access to request a token from the function app. 

Each managed identity needs to be assigned to the app registration with the app role that was previously created. Currently, this cannot be done in UI and must be done using Azure CLI or PowerShell. Below instructions use PowerShell. 

This script requires the **Microsoft.Graph** module to be installed. The user account running this will need application administrator permissions in Entra ID. 

The following must be set: 
- replace "hostname" with the hostname of the server who's managed identity you want to use. 
- replace "app_registration_name" with the name of the app registration you previously created. 
- replace "Token.Request" with the name of the app role you created. If you followed the instructions here, this will already be correct. 

```powershell
connect-MgGraph -scopes "AppRoleAssignment.ReadWrite.All", "Application.Read.All"

# set script variables
$midName = "hostname"  #name of the user managed identity, or the server name for system managed identity
$appReg = "app_registration_name" #name of the FIRST app registration (for the Ansible webhook)
$appRoleName = "Token.Request" 

# get the IDs
$mid = get-MgServicePrincipal -Filter "DisplayName eq '$midName'"
$appRegSp = get-MgServicePrincipal -Filter "DisplayName eq '$appReg'"
$appRole = $appRegSp.AppRoles | Where-Object {$_.Value -eq $appRoleName}

# assign the role
new-mgserviceprincipalAppRoleAssignment `
 -servicePrincipalId $mid.id `
 -principalId $mid.Id  `
 -resourceId $appRegSp.Id `
 -AppRoleId $appRole.Id
```

>Note: managed identities for hosts (whether Azure hosted, or Azure ARC) can be found in Entra ID by going to **Enterprise Applications**, change the filter for **Application Type=Enterprise Application** to **Application Type = managed identities**. This is just for reference, there are no settings that need to be changed here.

## Deploy the function app

You can deploy the function directly from Visual Studio Code. 

1. install the Azure Resources and Azure Functions extensions in Visual Studio Code. Depending on the platform, you also want to ensure you have the dotnet-sdk installed (on MacOs this can be done through HomeBrew).  
1. Connect to Azure. In the Azure section, at the bottom, you will find 'local project' under "workspace". Right click and select **Deploy to Azure**. You'll be requested to select the correct subscription, function app etc. 

# Local testing

> Note: you will need a valid Entra ID issued token to order to request a new token. If you want to test with Bruno or Postman, you should create a separate app registration and grant it the correct permissions to the app registration associated with the function. You then use that app registration (with secret) to request a JWT token.

To request a token, you submit a request to the function address (which is shown in the azure portal): https://<function>azurewebsites.net/token 

Add a header called "Authorization" with a value of "Bearer <the token>"

The body should look like: 

```json
{
  "audience":"test",
  "subject":"a subject"
}
```

The token that is returned can be viewed at https://jwt.ms

You can see the openid metadata at: 
https://<function>.azurewebsites.net/.well-known/openid-configuration

and jwks uri (which is included in the metadata)
http


# Development

This is a very simple function. To make modifications, you need to setup some basic requirements in order to develop functions. It is entirely possible to clone the repo and have an AI agent read the code and make the changes you need. m

## Prerequisites

| Tool | Minimum version | Install |
|------|----------------|---------|
| Azure CLI | 2.61+ | https://learn.microsoft.com/cli/azure/install-azure-cli |
| Bicep CLI | auto-installed by `az bicep upgrade` | `az bicep upgrade` |
| .NET SDK | 10.0 | https://dotnet.microsoft.com/download |
| PowerShell | 7+ (or Windows PowerShell 5.1) | https://github.com/PowerShell/PowerShell |

---

# Deployment using bicep and Azure CLI. 

## Required Permissions

### Azure RBAC

You need **Owner** on the target resource group (or subscription).
`Contributor` alone is not enough because the Bicep template creates role
assignments (Key Vault and Storage RBAC).

```powershell
# Verify your current roles on the resource group
az role assignment list `
  --resource-group <resource-group> `
  --assignee (az ad signed-in-user show --query id -o tsv) `
  --output table
```

### Entra ID

| Action | Required role |
|--------|--------------|
| Create an App Registration | **Application Developer** or **Application Administrator** |
| Add App Roles to the registration | Owner of the application **or** Application Administrator |
| Create the Enterprise Application (service principal) | Same as above |
| Assign an App Role to a Managed Identity | **Application Administrator** or **Cloud Application Administrator** (or owner of the enterprise application) |

> If your tenant requires admin consent for app role assignments you will also need
> a **Privileged Role Administrator** or **Global Administrator** to grant consent.

---

## Deployment Steps

### 1. Sign in to Azure

```powershell
az login
az account set --subscription <subscription-id>
```

### 2. Create the Resource Group

```powershell
az group create --name ae-jwtissuer-rg --location australiaeast
```

### 3. Create the Entra ID App Registration

This registration is used by Easy Auth to validate bearer tokens presented to `/token`.

```powershell
# Create the app registration
$app = az ad app create `
  --display-name "jwt-issuer-auth" `
  --sign-in-audience "AzureADMyOrg" `
  | ConvertFrom-Json

$appId   = $app.appId
$tenantId = (az account show --query tenantId -o tsv)

Write-Host "App ID (aadClientId):  $appId"
Write-Host "Tenant ID (aadTenantId): $tenantId"

# Create the Enterprise Application (service principal) for role assignments
az ad sp create --id $appId
```

#### Add an App Role for callers

Callers must hold the `Token.Request` app role on this registration.

```powershell
$roleId = [System.Guid]::NewGuid().ToString()

$appRoles = @(
  @{
    id               = $roleId
    displayName      = "Token Request"
    description      = "Allows a service principal to request JWT tokens"
    value            = "Token.Request"
    allowedMemberTypes = @("Application")
    isEnabled        = $true
  }
) | ConvertTo-Json -Depth 5 -Compress

az ad app update --id $appId --app-roles $appRoles
```

### 4. Update `infra/main.bicepparam`

Open `infra/main.bicepparam` and set:

```
param aadTenantId = '<tenantId from step 3>'
param aadClientId = '<appId from step 3>'
param baseName    = '<short unique name, e.g. jwtissuer-dev>'
param location    = '<azure region, e.g. australiaeast>'
```

### 5. Deploy Infrastructure

```powershell
az deployment group create `
  --resource-group ae-jwtissuer-rg `
  --template-file infra/main.bicep `
  --parameters infra/main.bicepparam `
  --output table
```

The deployment creates:
- Azure Key Vault (RBAC-enabled, standard tier)
- Storage Account (Standard LRS, used by the Flex Consumption runtime)
- Flex Consumption hosting plan (Linux, FC1)
- Function App with System-Assigned Managed Identity and Easy Auth configured
- RBAC role assignments for the Function App's identity on Key Vault and Storage

> **Note:** The Key Vault certificate is **not** created by Bicep (ARM cannot
> reliably provision data-plane Key Vault resources when RBAC is enabled).
> Create it in the next step.

### 6. Create the Signing Certificate

Grant yourself the Key Vault Certificates Officer role, then create the certificate.

```powershell
$kvName = "kv-jwtissuer-dev"   # kv-<baseName>
$kvId   = (az keyvault show --name $kvName --resource-group ae-jwtissuer-rg --query id -o tsv)
$myId   = (az ad signed-in-user show --query id -o tsv)

az role assignment create `
  --role "Key Vault Certificates Officer" `
  --assignee $myId `
  --scope $kvId

# Role propagation can take up to 5 minutes — wait before continuing
Start-Sleep -Seconds 60

$certPolicy = @{
  keyProperties = @{
    keyType    = "RSA"
    keySize    = 2048
    reuseKey   = $false
    exportable = $false        # private key cannot be exported (HSM-compatible)
  }
  secretProperties = @{ contentType = "application/x-pkcs12" }
  x509CertificateProperties = @{
    subject          = "CN=jwt-signing-cert"
    validityInMonths = 12
  }
  lifetimeActions = @(
    @{
      action  = @{ actionType = "AutoRenew" }
      trigger = @{ daysBeforeExpiry = 30 }
    }
  )
  issuerParameters = @{ name = "Self" }
} | ConvertTo-Json -Depth 10 -Compress

az keyvault certificate create `
  --vault-name $kvName `
  --name jwt-signing-cert `
  --policy $certPolicy
```

### 7. Build and Deploy the Function Code

```powershell
cd src\JwtIssuer
dotnet publish -c Release -o publish

cd publish
Compress-Archive -Path * -DestinationPath ..\function.zip -Force
cd ..

az functionapp deployment source config-zip `
  --resource-group ae-jwtissuer-rg `
  --name func-jwtissuer-dev `
  --src function.zip
```

### 8. Grant Callers the App Role

For each Managed Identity that needs to call `/token`, assign the `Token.Request`
app role.

```powershell
# Object ID of the jwt-issuer-auth enterprise application
$resourceSpId = (az ad sp show --id $appId --query id -o tsv)

# App Role ID
$appRoleId = (az ad app show --id $appId `
  --query "appRoles[?value=='Token.Request'].id" -o tsv)

# Object ID of the calling Managed Identity's service principal
$callerObjectId = "<object-id-of-caller-managed-identity>"

az rest --method POST `
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/$resourceSpId/appRoleAssignedTo" `
  --body "{`"principalId`": `"$callerObjectId`", `"resourceId`": `"$resourceSpId`", `"appRoleId`": `"$appRoleId`"}"
```

---

## API Reference

### `POST /token` — Issue a JWT

Requires a valid bearer token for `api://<aadClientId>` with the `Token.Request`
app role.

**Request**

```http
POST https://func-jwtissuer-dev.azurewebsites.net/token
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "audience": "https://target-service.example.com",
  "subject": "some-identifier"
}
```

**Response `200 OK`**

```json
{
  "access_token": "<signed JWT>",
  "token_type": "Bearer"
}
```

The issued JWT contains: `iss`, `sub`, `aud` (array), `iat`, `nbf`, `exp`, `jti`.

### `GET /.well-known/openid-configuration` — OIDC Discovery

No authentication required.

```http
GET https://func-jwtissuer-dev.azurewebsites.net/.well-known/openid-configuration
```

Returns the OIDC Provider Metadata document (RFC 8414). Validators that discover
the JWKS URI from the issuer address will call this endpoint automatically.

```json
{
  "issuer": "https://func-jwtissuer-dev.azurewebsites.net",
  "jwks_uri": "https://func-jwtissuer-dev.azurewebsites.net/jwks",
  "id_token_signing_alg_values_supported": ["RS256"],
  "subject_types_supported": ["public"]
}
```

### `GET /jwks` — Public Key Set

No authentication required.

```http
GET https://func-jwtissuer-dev.azurewebsites.net/jwks
```

Returns a [JWKS document](https://www.rfc-editor.org/rfc/rfc7517) listing the RSA
public key for every currently-valid certificate version.

**Obtaining a token from a Managed Identity (PowerShell)**

```powershell
# On a machine/VM whose Managed Identity has been granted Token.Request
$resource = "api://58d24354-9f21-40dc-912c-49d2ee1ae850"
$tokenUrl  = "http://169.254.169.254/metadata/identity/oauth2/token" +
             "?api-version=2018-02-01&resource=$resource"
$miToken   = (Invoke-RestMethod -Uri $tokenUrl -Headers @{Metadata="true"}).access_token

$body = @{ audience = "https://target.example.com"; subject = "my-service" } | ConvertTo-Json
$jwt  = (Invoke-RestMethod `
  -Uri    "https://func-jwtissuer-dev.azurewebsites.net/token" `
  -Method POST `
  -Headers @{ Authorization = "Bearer $miToken"; "Content-Type" = "application/json" } `
  -Body   $body).access_token
```

---

## Certificate Rotation

Key Vault auto-renews the certificate 30 days before expiry (configured in step 6).
When it does, a new certificate version is created with a new key pair.

- The JWKS endpoint (`/jwks`) returns public keys for **all** enabled,
  non-expired certificate versions, so tokens signed by the old key remain
  verifiable during the overlap window.
- New tokens are always signed with the **current** (latest enabled) version.

No redeployment or manual intervention is needed.

---

## Redeployment Notes

### Updating app settings or auth configuration

Re-run the Bicep deployment — it is idempotent:

```powershell
az deployment group create `
  --resource-group ae-jwtissuer-rg `
  --template-file infra/main.bicep `
  --parameters infra/main.bicepparam
```

### Changing OS or hosting plan type

Azure does not allow changing a Function App from Windows to Linux (or between
hosting plan types) in place. Delete the Function App, App Service Plan, and
Storage Account first, then redeploy:

```powershell
az functionapp delete --resource-group ae-jwtissuer-rg --name func-jwtissuer-dev
az appservice plan delete --resource-group ae-jwtissuer-rg --name asp-jwtissuer-dev --yes
az storage account delete --resource-group ae-jwtissuer-rg --name stjwtissuerdev --yes

az deployment group create `
  --resource-group ae-jwtissuer-rg `
  --template-file infra/main.bicep `
  --parameters infra/main.bicepparam
```

The Key Vault and its certificate are unaffected and do not need to be recreated.

---

## Project Structure

```
jwtissuer/
├── infra/
│   ├── main.bicep              # Orchestrates all modules
│   ├── main.bicepparam         # Deployment parameters (edit before deploying)
│   └── modules/
│       ├── functionapp.bicep   # Flex Consumption plan, Function App, Storage, Easy Auth
│       └── keyvault.bicep      # Key Vault and RBAC role assignments
└── src/
    └── JwtIssuer/
        ├── Functions/
        │   ├── IssueTokenFunction.cs   # POST /token
        │   └── JwksFunction.cs         # GET /jwks
        ├── Services/
        │   ├── JwtSigningService.cs    # Builds and signs JWTs via Key Vault
        │   └── KeyVaultCertificateService.cs  # Certificate and JWKS retrieval
        └── Models/
            ├── IssueTokenRequest.cs
            └── JwksDocument.cs
```
