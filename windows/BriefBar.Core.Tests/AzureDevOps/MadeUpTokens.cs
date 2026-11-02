using System.Buffers.Text;
using System.Text;
using System.Text.Json.Nodes;

namespace BriefBar.Core.Tests.AzureDevOps;

/// Made-up Microsoft Entra tokens, unsigned: only what BriefBar reads from them, the directory (`tid`), whom it's for
/// (`oid`), and, for a guest, where its account is from (`idp`): another directory, or an identity provider such as
/// live.com. As the Swift tests' `madeUpToken`.
internal static class MadeUpTokens
{
    public static string For(string tenant, string objectId = "robin", string? guestFrom = null)
    {
        var claims = new JsonObject { ["tid"] = tenant, ["oid"] = objectId };
        if (guestFrom is not null)
        {
            claims["idp"] = Guid.TryParse(input: guestFrom, result: out _) ? "https://sts.windows.net/" + guestFrom + "/" : guestFrom;
        }
        return Encoded(json: """{"alg":"none"}""") + "." + Encoded(json: claims.ToJsonString()) + ".c2ln";
    }

    static string Encoded(string json) => Base64Url.EncodeToString(source: Encoding.UTF8.GetBytes(s: json));
}
