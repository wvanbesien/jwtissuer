using System.Net;
using System.Text.Json;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Configuration;

namespace JwtIssuer.Functions;

public sealed class OidcDiscoveryFunction(IConfiguration configuration)
{
    [Function(nameof(OidcDiscoveryFunction))]
    public async Task<HttpResponseData> RunAsync(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get",
            Route = ".well-known/openid-configuration")] HttpRequestData req,
        CancellationToken cancellationToken)
    {
        var issuer = configuration["JwtIssuer"]
            ?? throw new InvalidOperationException("JwtIssuer app setting is required.");

        // Minimal OIDC Provider Metadata per RFC 8414 / OpenID Connect Discovery 1.0.
        // Validators use this document to discover jwks_uri without hardcoding it.
        var metadata = new
        {
            issuer,
            jwks_uri = $"{issuer}/jwks",
            id_token_signing_alg_values_supported = new[] { "RS256" },
            subject_types_supported = new[] { "public" }
        };

        var response = req.CreateResponse(HttpStatusCode.OK);
        response.Headers.Add("Content-Type", "application/json");
        response.Headers.Add("Cache-Control", "public, max-age=3600");
        await response.WriteStringAsync(
            JsonSerializer.Serialize(metadata),
            cancellationToken);
        return response;
    }
}
