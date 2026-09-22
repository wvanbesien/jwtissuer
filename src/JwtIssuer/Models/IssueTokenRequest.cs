namespace JwtIssuer.Models;

/// <summary>
/// Request body for the POST /token endpoint.
/// </summary>
/// <remarks>
/// Both fields are optional when the corresponding app-setting override is active:
/// <list type="bullet">
///   <item><description><c>Audience</c> may be omitted when <c>TokenAudience</c> is set.</description></item>
///   <item><description><c>Subject</c> may be omitted when <c>UseJwtSubject</c> is <c>true</c>.</description></item>
/// </list>
/// </remarks>
public sealed class IssueTokenRequest
{
    public string? Audience { get; set; }
    public string? Subject  { get; set; }
}
