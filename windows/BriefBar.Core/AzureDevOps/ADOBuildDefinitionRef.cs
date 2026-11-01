using System.Text.Json;

namespace BriefBar.Core.AzureDevOps;

/// The pipeline a run belongs to: its ID, name and folder.
public sealed record ADOBuildDefinitionRef(int Id, string? Name = null, string? Path = null)
{
    internal static ADOBuildDefinitionRef? Read(JsonElement element) =>
        ADOJson.WholeNumber(element: element, name: "id") is { } id
            ? new ADOBuildDefinitionRef(Id: id, Name: ADOJson.Text(element: element, name: "name"), Path: ADOJson.Text(element: element, name: "path"))
            : null;
}
