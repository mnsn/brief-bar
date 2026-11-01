using System.Text.Json;

namespace BriefBar.Core.AzureDevOps;

/// A build policy's context: the run it queued, its pipeline's name, and whether its result has expired.
public sealed record ADOPolicyContext(int? BuildId = null, string? BuildDefinitionName = null, bool? IsExpired = null)
{
    internal static ADOPolicyContext Read(JsonElement element) => new(
        BuildId: LenientJson.WholeNumber(element: element, name: "buildId"),
        BuildDefinitionName: LenientJson.Text(element: element, name: "buildDefinitionName"),
        IsExpired: LenientJson.Flag(element: element, name: "isExpired"));
}
