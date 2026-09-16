using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Azure.Security.KeyVault.Certificates;
using JwtIssuer.Models;
using Microsoft.Extensions.Configuration;

namespace JwtIssuer.Services;

public interface IKeyVaultCertificateService
{
    /// <summary>
    /// Returns the current (latest enabled) certificate version for signing.
    /// </summary>
    Task<KeyVaultCertificateWithPolicy> GetCurrentCertificateAsync(CancellationToken cancellationToken = default);

    /// <summary>
    /// Returns a JWKS document containing public keys for all currently valid certificate versions.
    /// </summary>
    Task<JwksDocument> GetJwksAsync(CancellationToken cancellationToken = default);
}

public sealed class KeyVaultCertificateService(
    CertificateClient certificateClient,
    IConfiguration configuration) : IKeyVaultCertificateService
{
    private readonly string _certificateName = configuration["CertificateName"]
        ?? throw new InvalidOperationException("CertificateName app setting is required.");

    public async Task<KeyVaultCertificateWithPolicy> GetCurrentCertificateAsync(CancellationToken cancellationToken = default)
    {
        return (await certificateClient.GetCertificateAsync(_certificateName, cancellationToken)).Value;
    }

    public async Task<JwksDocument> GetJwksAsync(CancellationToken cancellationToken = default)
    {
        var keys = new List<JwksKey>();
        var now = DateTimeOffset.UtcNow;

        await foreach (var properties in certificateClient.GetPropertiesOfCertificateVersionsAsync(
            _certificateName, cancellationToken))
        {
            // Skip disabled versions or versions that have already expired.
            if (properties.Enabled != true)
                continue;
            if (properties.ExpiresOn.HasValue && properties.ExpiresOn.Value <= now)
                continue;

            var cert = await certificateClient.GetCertificateVersionAsync(
                _certificateName, properties.Version, cancellationToken);

            if (cert.Value.Cer is not { Length: > 0 } derBytes)
                continue;

            var jwksKey = BuildJwksKey(derBytes);
            if (jwksKey is not null)
                keys.Add(jwksKey);
        }

        return new JwksDocument { Keys = keys };
    }

    private static JwksKey? BuildJwksKey(byte[] derBytes)
    {
        using var x509 = X509CertificateLoader.LoadCertificate(derBytes);

        using var rsa = x509.GetRSAPublicKey();
        if (rsa is null)
            return null;

        var rsaParams = rsa.ExportParameters(includePrivateParameters: false);
        if (rsaParams.Modulus is null || rsaParams.Exponent is null)
            return null;

        var sha1Thumbprint = Base64UrlEncode(x509.GetCertHash(HashAlgorithmName.SHA1));
        var sha256Thumbprint = Base64UrlEncode(x509.GetCertHash(HashAlgorithmName.SHA256));

        return new JwksKey
        {
            KeyId = sha1Thumbprint,
            Modulus = Base64UrlEncode(rsaParams.Modulus),
            Exponent = Base64UrlEncode(rsaParams.Exponent),
            Sha1Thumbprint = sha1Thumbprint,
            Sha256Thumbprint = sha256Thumbprint,
            CertificateChain = [Convert.ToBase64String(derBytes)]
        };
    }

    private static string Base64UrlEncode(byte[] bytes) =>
        Convert.ToBase64String(bytes)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');
}
