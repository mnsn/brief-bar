using System.Text.Json;

namespace BriefBar.Core.AzureDevOps;

/// Someone, or a group or a service, as Azure DevOps names them.
public sealed record ADOIdentity(string Id, string? DisplayName = null, string? UniqueName = null, bool? IsContainer = null)
{
    internal static ADOIdentity? Read(JsonElement element) =>
        LenientJson.Text(element: element, name: "id") is { } id
            ? new ADOIdentity(
                Id: id,
                DisplayName: LenientJson.Text(element: element, name: "displayName"),
                UniqueName: LenientJson.Text(element: element, name: "uniqueName"),
                IsContainer: LenientJson.Flag(element: element, name: "isContainer"))
            : null;
}
