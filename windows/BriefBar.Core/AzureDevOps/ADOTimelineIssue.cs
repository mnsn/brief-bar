using System.Text.Json;

namespace BriefBar.Core.AzureDevOps;

/// An error or warning a timeline record logged.
public sealed record ADOTimelineIssue(string? Type, string? Message)
{
    internal static ADOTimelineIssue Read(JsonElement element) =>
        new(Type: LenientJson.Text(element: element, name: "type"), Message: LenientJson.Text(element: element, name: "message"));
}
