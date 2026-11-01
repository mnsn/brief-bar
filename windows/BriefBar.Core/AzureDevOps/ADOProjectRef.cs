using System.Text.Json;

namespace BriefBar.Core.AzureDevOps;

public sealed record ADOProjectRef(string Id, string Name)
{
    internal static ADOProjectRef? Read(JsonElement element) =>
        ADOJson.Text(element: element, name: "id") is { } id && ADOJson.Text(element: element, name: "name") is { } name
            ? new ADOProjectRef(Id: id, Name: name)
            : null;
}
