using System.Net;
using System.Text;
using System.Text.Json;
using JwtIssuer.Models;
using JwtIssuer.Services;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace JwtIssuer.Functions;

public sealed class IssueTokenFunction(
    IJwtSigningService jwtSigningService,
    IConfiguration configuration,
    ILogger<IssueTokenFunction> logger)
{
    // ── Optional overrides read once at construction ───────────────────────

    /// <summary>
    /// When non-null, the audience supplied in the request body is ignored and this
    /// value is used instead.  The incoming (Easy-Auth-validated) JWT must carry this
    /// same value in its <c>aud</c> claim, providing an additional audience check.
    /// </summary>
    private readonly string? _forcedAudience =
        configuration["TokenAudience"] is { Length: > 0 } a ? a : null;

    /// <summary>
    /// When <c>true</c>, the subject supplied in the request body is ignored and the
    /// <c>sub</c> claim from the incoming Easy-Auth-validated JWT is used instead.
    /// </summary>
    private readonly bool _useJwtSubject =
        bool.TryParse(configuration["UseJwtSubject"], out var b) && b;

    // ── HTTP trigger ───────────────────────────────────────────────────────

    [Function(nameof(IssueTokenFunction))]
    public async Task<HttpResponseData> RunAsync(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "token")] HttpRequestData req,
        CancellationToken cancellationToken)
    {
        // Read the body as text first so we can distinguish "empty" from "bad JSON".
        // An empty (or whitespace-only) body is treated as {} — perfectly valid when
        // TokenAudience and UseJwtSubject are both configured.
        var bodyText = await new StreamReader(req.Body).ReadToEndAsync(cancellationToken);

        IssueTokenRequest tokenRequest;
        if (string.IsNullOrWhiteSpace(bodyText))
        {
            tokenRequest = new IssueTokenRequest();
        }
        else
        {
            try
            {
                tokenRequest = JsonSerializer.Deserialize<IssueTokenRequest>(
                    bodyText,
                    new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
                    ?? new IssueTokenRequest();
            }
            catch (JsonException ex)
            {
                logger.LogWarning(ex, "Invalid JSON in token request body.");
                return await BadRequestAsync(req, "Request body must be valid JSON.", cancellationToken);
            }
        }

        // ── Audience ──────────────────────────────────────────────────────

        string audience;

        if (_forcedAudience is not null)
        {
            // TokenAudience is configured: verify the incoming JWT carries that audience,
            // then use it.  The 'audience' field in the request body is ignored entirely.
            var incomingAud = GetIncomingClaims(req, "aud");
            if (!incomingAud.Contains(_forcedAudience, StringComparer.Ordinal))
            {
                logger.LogWarning(
                    "Token request rejected: incoming JWT aud [{IncomingAud}] does not contain required audience '{Required}'.",
                    string.Join(", ", incomingAud), _forcedAudience);
                var forbidden = req.CreateResponse(HttpStatusCode.Forbidden);
                await forbidden.WriteStringAsync("Audience mismatch.", cancellationToken);
                return forbidden;
            }

            audience = _forcedAudience;
        }
        else
        {
            if (string.IsNullOrWhiteSpace(tokenRequest.Audience))
                return await BadRequestAsync(req,
                    "Request body must include a non-empty 'audience' field " +
                    "(or configure the TokenAudience app setting).",
                    cancellationToken);

            audience = tokenRequest.Audience;
        }

        // ── Subject ───────────────────────────────────────────────────────

        string subject;

        if (_useJwtSubject)
        {
            // UseJwtSubject is enabled: extract sub from the Easy-Auth-validated JWT.
            // The 'subject' field in the request body is ignored entirely.
            var incomingSub = GetIncomingClaim(req, "sub");
            if (string.IsNullOrWhiteSpace(incomingSub))
            {
                logger.LogWarning("UseJwtSubject is enabled but the incoming JWT contains no sub claim.");
                return await BadRequestAsync(req,
                    "Incoming JWT does not contain a sub claim.",
                    cancellationToken);
            }

            subject = incomingSub;
        }
        else
        {
            if (string.IsNullOrWhiteSpace(tokenRequest.Subject))
                return await BadRequestAsync(req,
                    "Request body must include a non-empty 'subject' field " +
                    "(or set UseJwtSubject to true).",
                    cancellationToken);

            subject = tokenRequest.Subject;
        }

        // ── Issue token ───────────────────────────────────────────────────

        string jwt;
        try
        {
            jwt = await jwtSigningService.IssueTokenAsync(audience, subject, cancellationToken);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Failed to issue JWT token.");
            var error = req.CreateResponse(HttpStatusCode.InternalServerError);
            await error.WriteStringAsync("Token issuance failed.", cancellationToken);
            return error;
        }

        var response = req.CreateResponse(HttpStatusCode.OK);
        response.Headers.Add("Content-Type", "application/json");
        await response.WriteStringAsync(
            JsonSerializer.Serialize(new { access_token = jwt, token_type = "Bearer" }),
            cancellationToken);
        return response;
    }

    // ── Claim helpers ──────────────────────────────────────────────────────

    /// <summary>
    /// Easy Auth rewrites standard JWT claim names to their .NET WS-Fed long-form URI
    /// equivalents before injecting <c>X-MS-CLIENT-PRINCIPAL</c>.  This map lets us find
    /// claims by their short JWT name regardless of which form Easy Auth chose.
    /// </summary>
    private static readonly Dictionary<string, string> ClaimTypeUriMap = new(StringComparer.Ordinal)
    {
        ["sub"]   = "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/nameidentifier",
        ["name"]  = "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name",
        ["email"] = "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress",
        ["roles"] = "http://schemas.microsoft.com/ws/2008/06/identity/claims/role",
        ["oid"]   = "http://schemas.microsoft.com/identity/claims/objectidentifier",
        ["tid"]   = "http://schemas.microsoft.com/identity/claims/tenantid",
    };

    /// <summary>
    /// Returns all values for <paramref name="claimType"/> from the Easy-Auth-injected
    /// <c>X-MS-CLIENT-PRINCIPAL</c> header.  Accepts both the short JWT claim name (e.g.
    /// <c>sub</c>) and its long-form .NET WS-Fed URI equivalent (e.g.
    /// <c>http://schemas.xmlsoap.org/…/nameidentifier</c>).
    /// </summary>
    private static IReadOnlyList<string> GetIncomingClaims(HttpRequestData req, string claimType)
    {
        if (!req.Headers.TryGetValues("X-MS-CLIENT-PRINCIPAL", out var headerValues))
            return [];

        var encoded = headerValues.FirstOrDefault();
        if (string.IsNullOrEmpty(encoded))
            return [];

        try
        {
            var json = Encoding.UTF8.GetString(Convert.FromBase64String(encoded));
            using var doc = JsonDocument.Parse(json);
            if (!doc.RootElement.TryGetProperty("claims", out var claims))
                return [];

            // Also accept the long-form URI that Easy Auth injects for v1 AAD tokens
            ClaimTypeUriMap.TryGetValue(claimType, out var uriForm);

            var result = new List<string>();
            foreach (var claim in claims.EnumerateArray())
            {
                if (claim.TryGetProperty("typ", out var typ) &&
                    claim.TryGetProperty("val", out var val))
                {
                    var typStr = typ.GetString();
                    if (typStr == claimType || (uriForm is not null && typStr == uriForm))
                    {
                        if (val.GetString() is { } v)
                            result.Add(v);
                    }
                }
            }
            return result;
        }
        catch
        {
            return [];
        }
    }

    /// <summary>Returns the first value for <paramref name="claimType"/>, or <c>null</c>.</summary>
    private static string? GetIncomingClaim(HttpRequestData req, string claimType) =>
        GetIncomingClaims(req, claimType).FirstOrDefault();

    private static async Task<HttpResponseData> BadRequestAsync(
        HttpRequestData req, string message, CancellationToken ct)
    {
        var r = req.CreateResponse(HttpStatusCode.BadRequest);
        await r.WriteStringAsync(message, ct);
        return r;
    }
}
