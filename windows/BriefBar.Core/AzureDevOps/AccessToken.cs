using System.Buffers.Text;
using System.Text.Json;

namespace BriefBar.Core.AzureDevOps;

/// A bearer token for Azure DevOps, kept in memory only, until when it's good, and whose sign-in it is (`Account`), when
/// the token says: another means someone else signed in. The Mac's `AccessToken`.
public sealed record AccessToken(string Value, DateTimeOffset ExpiresOn, string? Account = null)
{
    /// Good for at least `margin` more, five minutes unless said.
    public bool IsValid(DateTimeOffset at, TimeSpan? margin = null) => ExpiresOn - at > (margin ?? TimeSpan.FromMinutes(value: 5));

    /// The tenant and object ID in a Microsoft Entra token, a JWT, read without checking its signature, as `tenant/object`,
    /// lowercased: it only tells one sign-in from another. Null for a token that isn't a JWT.
    public static string? AccountInJwt(string token)
    {
        ArgumentNullException.ThrowIfNull(argument: token);
        var parts = token.Split(separator: '.');
        if (parts.Length != 3)
        {
            return null;
        }
        var payload = parts[1];
        var bytes = new byte[Base64Url.GetMaxDecodedLength(base64Length: payload.Length)];
        if (Base64Url.DecodeFromChars(source: payload, destination: bytes, charsConsumed: out _, bytesWritten: out var written) != System.Buffers.OperationStatus.Done)
        {
            return null;
        }
        try
        {
            using var claims = JsonDocument.Parse(utf8Json: bytes.AsMemory(start: 0, length: written));
            if (claims.RootElement.ValueKind != JsonValueKind.Object)
            {
                return null;
            }
            var subject = ADOJson.Text(element: claims.RootElement, name: "oid") ?? ADOJson.Text(element: claims.RootElement, name: "sub");
            return subject is null ? null : ((ADOJson.Text(element: claims.RootElement, name: "tid") ?? string.Empty) + "/" + subject).ToLowerInvariant();
        }
        catch (JsonException)
        {
            // Not JSON: not a JWT.
            return null;
        }
    }

    /// Never the token itself.
    public override string ToString() => "AccessToken until " + ExpiresOn.ToString(format: "O", formatProvider: System.Globalization.CultureInfo.InvariantCulture);
}
