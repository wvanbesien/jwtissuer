# JWT Issuer — Azure Function

## The problem we're solving

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

Please check the wiki for details on how to deploy the solution. 


