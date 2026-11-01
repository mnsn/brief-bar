using System.Text.Json;

namespace BriefBar.Core.AzureDevOps;

public sealed record ADORepositoryRef(string Id, string Name, ADOProjectRef Project)
{
    internal static ADORepositoryRef? Read(JsonElement element) =>
        LenientJson.Text(element: element, name: "id") is { } id && LenientJson.Text(element: element, name: "name") is { } name
            && LenientJson.Node(element: element, name: "project") is { } node && ADOProjectRef.Read(element: node) is { } project
            ? new ADORepositoryRef(Id: id, Name: name, Project: project)
            : null;
}
