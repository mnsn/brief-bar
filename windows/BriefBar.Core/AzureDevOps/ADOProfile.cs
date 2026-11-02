using System.Text.Json;

namespace BriefBar.Core.AzureDevOps;

/// `app.vssps.visualstudio.com/_apis/profile/profiles/me`: your profile, to find your organizations with.
public sealed record ADOProfile(string Id, string? PublicAlias)
{
    internal static ADOProfile? Read(JsonElement element) =>
        LenientJson.Text(element: element, name: "id") is { } id ? new ADOProfile(Id: id, PublicAlias: LenientJson.Text(element: element, name: "publicAlias")) : null;
}
