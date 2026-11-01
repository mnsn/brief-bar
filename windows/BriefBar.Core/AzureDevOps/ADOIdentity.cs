using System.Text.Json;

namespace BriefBar.Core.AzureDevOps;

/// Someone, or a group or a service, as Azure DevOps names them.
public sealed record ADOIdentity(string Id, string? DisplayName = null, string? UniqueName = null, bool? IsContainer = null)
{
    internal static ADOIdentity? Read(JsonElement element) =>
        ADOJson.Text(element: element, name: "id") is { } id
            ? new ADOIdentity(
                Id: id,
                DisplayName: ADOJson.Text(element: element, name: "displayName"),
                UniqueName: ADOJson.Text(element: element, name: "uniqueName"),
                IsContainer: ADOJson.Flag(element: element, name: "isContainer"))
            : null;
}
