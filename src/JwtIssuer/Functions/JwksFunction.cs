using System.Net;
using System.Text.Json;
using JwtIssuer.Services;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;

namespace JwtIssuer.Functions;

public sealed class JwksFunction(
    IKeyVaultCertificateService certificateService,
    ILogger<JwksFunction> logger)
{
    [Function(nameof(JwksFunction))]
    public async Task<HttpResponseData> RunAsync(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "jwks")] HttpRequestData req,
        CancellationToken cancellationToken)
    {
        try
        {
            var jwks = await certificateService.GetJwksAsync(cancellationToken);

            var response = req.CreateResponse(HttpStatusCode.OK);
            response.Headers.Add("Content-Type", "application/json");
            response.Headers.Add("Cache-Control", "public, max-age=3600");
            await response.WriteStringAsync(
                JsonSerializer.Serialize(jwks),
                cancellationToken);
            return response;
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Failed to build JWKS document.");
            var error = req.CreateResponse(HttpStatusCode.InternalServerError);
            await error.WriteStringAsync("Failed to retrieve public keys.", cancellationToken);
            return error;
        }
    }
}
