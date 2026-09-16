using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using Azure.Security.KeyVault.Keys.Cryptography;
using Microsoft.Extensions.Configuration;

namespace JwtIssuer.Services;

public interface IJwtSigningService
{
    Task<string> IssueTokenAsync(
        string audience,
        string subject,
        CancellationToken cancellationToken = default);
}

public sealed class JwtSigningService(
    IKeyVaultCertificateService certificateService,
    CryptographyClientFactory cryptographyClientFactory,
    IConfiguration configuration) : IJwtSigningService
{
    private readonly string _issuer = configuration["JwtIssuer"]
        ?? throw new InvalidOperationException("JwtIssuer app setting is required.");

    private readonly int _lifetimeMinutes = int.TryParse(
        configuration["TokenLifetimeMinutes"], out var minutes) && minutes > 0
        ? minutes
        : 30;

    public async Task<string> IssueTokenAsync(
        string audience,
        string subject,
        CancellationToken cancellationToken = default)
    {
        var cert = await certificateService.GetCurrentCertificateAsync(cancellationToken);

        if (cert.KeyId is not { } keyId)
            throw new InvalidOperationException("Certificate has no associated key in Key Vault.");

        // kid = base64url(SHA-1 thumbprint of DER certificate), matching what the JWKS endpoint publishes.
        using var x509 = X509CertificateLoader.LoadCertificate(cert.Cer);
        var kid = Base64UrlEncode(x509.GetCertHash(System.Security.Cryptography.HashAlgorithmName.SHA1));

        var now = DateTimeOffset.UtcNow;
        var iat = now.ToUnixTimeSeconds();
        var exp = now.AddMinutes(_lifetimeMinutes).ToUnixTimeSeconds();

        // RFC 7515 §3: header must be compact JSON, then base64url-encoded.
        var headerJson = JsonSerializer.Serialize(new
        {
            alg = "RS256",
            typ = "JWT",
            kid
        });

        // RFC 7519 §4: aud MUST be an array (or single StringOrURI).
        // Using an array avoids strict-mode rejections by some validators.
        var payloadJson = JsonSerializer.Serialize(new
        {
            iss = _issuer,
            sub = subject,
            aud = new[] { audience },
            iat,
            nbf = iat,
            exp,
            jti = Guid.NewGuid().ToString()
        });

        var signingInput =
            $"{Base64UrlEncode(Encoding.UTF8.GetBytes(headerJson))}.{Base64UrlEncode(Encoding.UTF8.GetBytes(payloadJson))}";

        // SignDataAsync hashes the data with SHA-256 internally before sending to Key Vault,
        // which is the correct RS256 flow (vs. SignAsync which takes a pre-computed digest).
        var cryptoClient = cryptographyClientFactory.CreateForKeyId(keyId);
        var signResult = await cryptoClient.SignDataAsync(
            SignatureAlgorithm.RS256,
            Encoding.UTF8.GetBytes(signingInput),
            cancellationToken);

        return $"{signingInput}.{Base64UrlEncode(signResult.Signature)}";
    }

    private static string Base64UrlEncode(byte[] bytes) =>
        Convert.ToBase64String(bytes)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');
}

/// <summary>
/// Thin factory to allow test substitution of <see cref="CryptographyClient"/>.
/// </summary>
public class CryptographyClientFactory(Azure.Core.TokenCredential credential)
{
    public virtual CryptographyClient CreateForKeyId(Uri keyId) =>
        new(keyId, credential);
}
