using System.Buffers;
using System.Buffers.Text;
using System.Text.Json;

namespace BriefBar.Core.AzureDevOps;

/// A bearer token for Azure DevOps, kept in memory only, until when it's good; whose sign-in it is (`Account`), when the
/// token says: another means someone else signed in; the directory it's for (`Tenant`, a Microsoft Entra tenant's ID),
/// as Azure DevOps reads an organization only with a token from the organization's own directory; and the directory the
/// account itself is from (`AccountTenant`): for a guest from another directory, that one, or for one from elsewhere,
/// such as a personal Microsoft account, its identity provider; otherwise the token's own. The Mac's `AccessToken`.
public sealed record AccessToken(string Value, DateTimeOffset ExpiresOn, string? Account = null, string? Tenant = null, string? AccountTenant = null)
{
    /// Good for at least `margin` more, five minutes unless said.
    public bool IsValid(DateTimeOffset at, TimeSpan? margin = null) => ExpiresOn - at > (margin ?? TimeSpan.FromMinutes(value: 5));

    /// The tenant and object ID in a Microsoft Entra token, a JWT, read without checking its signature, as `tenant/object`,
    /// lowercased: it only tells one sign-in from another. Null for a token that isn't a JWT.
    public static string? AccountInJwt(string token)
    {
        ArgumentNullException.ThrowIfNull(argument: token);
        if (Claims(token: token) is not { } claims)
        {
            return null;
        }
        var subject = LenientJson.Text(element: claims, name: "oid") ?? LenientJson.Text(element: claims, name: "sub");
        return subject is null ? null : ((LenientJson.Text(element: claims, name: "tid") ?? string.Empty) + "/" + subject).ToLowerInvariant();
    }

    /// The directory a Microsoft Entra token, a JWT, is for, its `tid`, read without checking its signature: a GUID,
    /// lowercased (`TenantId`). Null when it doesn't say.
    public static string? TenantInJwt(string token)
    {
        ArgumentNullException.ThrowIfNull(argument: token);
        return Claims(token: token) is { } claims ? TenantId.From(text: LenientJson.Text(element: claims, name: "tid")) : null;
    }

    /// The directory a Microsoft Entra token's account is from, lowercased: for a guest from another directory, the one its
    /// `idp` names, such as `https://sts.windows.net/<tenant>/`; for one from elsewhere, such as a personal Microsoft
    /// account, its identity provider (`live.com`); otherwise the token's own. Null when it doesn't say.
    public static string? AccountTenantInJwt(string token)
    {
        ArgumentNullException.ThrowIfNull(argument: token);
        if (Claims(token: token) is not { } claims)
        {
            return null;
        }
        if (LenientJson.Text(element: claims, name: "idp") is not { Length: > 0 } identityProvider)
        {
            return TenantId.From(text: LenientJson.Text(element: claims, name: "tid"));
        }
        var directory = identityProvider.Split(separator: '/').Select(selector: part => TenantId.From(text: part)).FirstOrDefault(predicate: part => part is not null);
        return directory ?? identityProvider.ToLowerInvariant();
    }

    /// The directory in an account, as `AccountInJwt` writes it, before its `/`. Null when it doesn't say.
    public static string? TenantOfAccount(string account)
    {
        ArgumentNullException.ThrowIfNull(argument: account);
        var slash = account.IndexOf(value: '/', comparisonType: StringComparison.Ordinal);
        return slash > 0 ? TenantId.From(text: account[..slash]) : null;
    }

    /// Never the token itself.
    public override string ToString() => "AccessToken until " + ExpiresOn.ToString(format: "O", formatProvider: System.Globalization.CultureInfo.InvariantCulture);

    /// A JWT's claims, read without checking its signature; null for a token that isn't one.
    static JsonElement? Claims(string token)
    {
        var parts = token.Split(separator: '.');
        if (parts.Length != 3)
        {
            return null;
        }
        var payload = parts[1];
        var bytes = new byte[Base64Url.GetMaxDecodedLength(base64Length: payload.Length)];
        if (Base64Url.DecodeFromChars(source: payload, destination: bytes, charsConsumed: out _, bytesWritten: out var written) != OperationStatus.Done)
        {
            return null;
        }
        try
        {
            using var claims = JsonDocument.Parse(utf8Json: bytes.AsMemory(start: 0, length: written));
            return claims.RootElement.ValueKind == JsonValueKind.Object ? claims.RootElement.Clone() : null;
        }
        catch (JsonException)
        {
            // Not JSON: not a JWT.
            return null;
        }
    }
}
