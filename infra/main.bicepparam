using 'main.bicep'

// ── Required — replace before deploying ───────────────────────────────────

// Short, unique suffix for all resource names (lowercase alphanumeric, max 17 chars).
// Example: 'jwtissuer-dev' → resources: kv-jwtissuer-dev, func-jwtissuer-dev, …
param baseName = 'jwtissuer-test'

// Azure AD tenant where the calling applications live.
//param aadTenantId = '0a62775b-54b2-4b1e-abd7-7d4046a3c838'

// Azure AD app registration created for this Function App's Easy Auth.
//param aadClientId = '58d24354-9f21-40dc-912c-49d2ee1ae850'

// ── Optional — override defaults ───────────────────────────────────────────
param tokenLifetimeMinutes = 30

// Optional: hard-code the audience for issued tokens and enforce it on the incoming JWT.
// Leave commented out (or empty) to let callers supply the audience in the request body.
// param tokenAudience = 'api://your-app-id'

// Optional: set to true to use the sub claim from the caller's JWT as the issued token subject.
// param useJwtSubject = false
param certificateName = 'jwt-signing-cert'
param certificateValidityMonths = 3
param renewDaysBeforeExpiry = 30
param location = 'australiaeast'
