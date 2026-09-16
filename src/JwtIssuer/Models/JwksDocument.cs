using System.Text.Json.Serialization;

namespace JwtIssuer.Models;

public sealed class JwksDocument
{
    [JsonPropertyName("keys")]
    public List<JwksKey> Keys { get; set; } = [];
}

public sealed class JwksKey
{
    [JsonPropertyName("kty")]
    public string KeyType { get; set; } = "RSA";

    [JsonPropertyName("use")]
    public string Use { get; set; } = "sig";

    [JsonPropertyName("alg")]
    public string Algorithm { get; set; } = "RS256";

    [JsonPropertyName("kid")]
    public string KeyId { get; set; } = string.Empty;

    [JsonPropertyName("n")]
    public string Modulus { get; set; } = string.Empty;

    [JsonPropertyName("e")]
    public string Exponent { get; set; } = string.Empty;

    [JsonPropertyName("x5t")]
    public string Sha1Thumbprint { get; set; } = string.Empty;

    [JsonPropertyName("x5t#S256")]
    public string Sha256Thumbprint { get; set; } = string.Empty;

    [JsonPropertyName("x5c")]
    public List<string> CertificateChain { get; set; } = [];
}
