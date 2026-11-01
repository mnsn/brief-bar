using System.Text.Json;

namespace BriefBar.Core.AzureDevOps;

/// The settings of a policy that BriefBar reads: a build's or a status's name, and how many approvals a reviewer policy
/// wants.
public sealed record ADOPolicySettings(
    string? DisplayName = null,
    int? MinimumApproverCount = null,
    string? StatusName = null,
    string? StatusGenre = null,
    string? DefaultDisplayName = null)
{
    internal static ADOPolicySettings Read(JsonElement element) => new(
        DisplayName: ADOJson.Text(element: element, name: "displayName"),
        MinimumApproverCount: ADOJson.WholeNumber(element: element, name: "minimumApproverCount"),
        StatusName: ADOJson.Text(element: element, name: "statusName"),
        StatusGenre: ADOJson.Text(element: element, name: "statusGenre"),
        DefaultDisplayName: ADOJson.Text(element: element, name: "defaultDisplayName"));
}
