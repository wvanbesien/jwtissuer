namespace JwtIssuer.Models;

public sealed class IssueTokenRequest
{
    public string Audience { get; set; } = string.Empty;
    public string Subject { get; set; } = string.Empty;
}
