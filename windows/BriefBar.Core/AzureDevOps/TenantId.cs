namespace BriefBar.Core.AzureDevOps;

/// A directory's ID, a Microsoft Entra tenant's, as BriefBar keeps it and gives it to `az --tenant`: a GUID, lowercased.
/// Nothing else is one: not the empty GUID, and no other text, which `az.cmd`, a batch file, mustn't get. The Mac takes
/// only GUIDs from Azure DevOps' answers too (`ADOClient.resourceTenants`).
internal static class TenantId
{
    /// `text` as a directory's ID, or null when it isn't one.
    public static string? From(string? text) =>
        text is not null && Guid.TryParseExact(input: text.Trim(), format: "D", result: out var id) && id != Guid.Empty
            ? id.ToString(format: "D")
            : null;
}
