using System.Text.Json;

namespace BriefBar.Core.AzureDevOps;

/// An error or warning a timeline record logged.
public sealed record ADOTimelineIssue(string? Type, string? Message)
{
    internal static ADOTimelineIssue Read(JsonElement element) =>
        new(Type: ADOJson.Text(element: element, name: "type"), Message: ADOJson.Text(element: element, name: "message"));
}
