using System.Text.Json;

namespace BriefBar.Core.AzureDevOps;

/// The settings of a policy that BriefBar reads: a build's or a status's name, how many approvals a reviewer policy
/// wants, and whom a required-reviewers policy requires.
public sealed record ADOPolicySettings(
    string? DisplayName = null,
    int? MinimumApproverCount = null,
    string? StatusName = null,
    string? StatusGenre = null,
    string? DefaultDisplayName = null,
    ValueList<string>? RequiredReviewerIds = null)
{
    internal static ADOPolicySettings Read(JsonElement element) => new(
        DisplayName: LenientJson.Text(element: element, name: "displayName"),
        MinimumApproverCount: LenientJson.WholeNumber(element: element, name: "minimumApproverCount"),
        StatusName: LenientJson.Text(element: element, name: "statusName"),
        StatusGenre: LenientJson.Text(element: element, name: "statusGenre"),
        DefaultDisplayName: LenientJson.Text(element: element, name: "defaultDisplayName"),
        RequiredReviewerIds: LenientJson.Items(element: element, name: "requiredReviewerIds", read: Identity) is { } ids ? new ValueList<string>(items: ids) : null);

    /// An identity's ID, as a required-reviewers policy lists it; null for anything but text.
    static string? Identity(JsonElement element) => element.ValueKind == JsonValueKind.String ? element.GetString() : null;
}
