using System.Net;
using System.Text.Json;
using JwtIssuer.Models;
using JwtIssuer.Services;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;

namespace JwtIssuer.Functions;

public sealed class IssueTokenFunction(
    IJwtSigningService jwtSigningService,
    ILogger<IssueTokenFunction> logger)
{
    [Function(nameof(IssueTokenFunction))]
    public async Task<HttpResponseData> RunAsync(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "token")] HttpRequestData req,
        CancellationToken cancellationToken)
    {
        IssueTokenRequest? tokenRequest;

        try
        {
            tokenRequest = await JsonSerializer.DeserializeAsync<IssueTokenRequest>(
                req.Body,
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true },
                cancellationToken);
        }
        catch (JsonException ex)
        {
            logger.LogWarning(ex, "Invalid JSON in token request body.");
            var badRequest = req.CreateResponse(HttpStatusCode.BadRequest);
            await badRequest.WriteStringAsync("Request body must be valid JSON.", cancellationToken);
            return badRequest;
        }

        if (tokenRequest is null ||
            string.IsNullOrWhiteSpace(tokenRequest.Audience) ||
            string.IsNullOrWhiteSpace(tokenRequest.Subject))
        {
            var badRequest = req.CreateResponse(HttpStatusCode.BadRequest);
            await badRequest.WriteStringAsync(
                "Request body must include non-empty 'audience' and 'subject' fields.",
                cancellationToken);
            return badRequest;
        }

        string jwt;

        try
        {
            jwt = await jwtSigningService.IssueTokenAsync(
                tokenRequest.Audience,
                tokenRequest.Subject,
                cancellationToken);
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
}
