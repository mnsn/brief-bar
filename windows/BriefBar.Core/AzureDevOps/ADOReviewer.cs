using System.Text.Json;

namespace BriefBar.Core.AzureDevOps;

/// A pull request's reviewer, and their vote.
public sealed record ADOReviewer(
    string Id,
    string? DisplayName = null,
    string? UniqueName = null,
    int? Vote = null,
    bool? IsRequired = null,
    bool? IsContainer = null,
    bool? HasDeclined = null)
{
    internal static ADOReviewer? Read(JsonElement element) =>
        ADOJson.Text(element: element, name: "id") is { } id
            ? new ADOReviewer(
                Id: id,
                DisplayName: ADOJson.Text(element: element, name: "displayName"),
                UniqueName: ADOJson.Text(element: element, name: "uniqueName"),
                Vote: ADOJson.WholeNumber(element: element, name: "vote"),
                IsRequired: ADOJson.Flag(element: element, name: "isRequired"),
                IsContainer: ADOJson.Flag(element: element, name: "isContainer"),
                HasDeclined: ADOJson.Flag(element: element, name: "hasDeclined"))
            : null;
}
