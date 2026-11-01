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
        LenientJson.Text(element: element, name: "id") is { } id
            ? new ADOReviewer(
                Id: id,
                DisplayName: LenientJson.Text(element: element, name: "displayName"),
                UniqueName: LenientJson.Text(element: element, name: "uniqueName"),
                Vote: LenientJson.WholeNumber(element: element, name: "vote"),
                IsRequired: LenientJson.Flag(element: element, name: "isRequired"),
                IsContainer: LenientJson.Flag(element: element, name: "isContainer"),
                HasDeclined: LenientJson.Flag(element: element, name: "hasDeclined"))
            : null;
}
