namespace BriefBar.Core;

/// The names of the sources: the ones the Mac saves (`teams`, `azureDevOps`…), so the two apps name them alike, and the
/// ones people read.
public static class SourceIds
{
    /// The name it's saved under, as the Mac's `SourceID` raw values.
    public static string RawValue(SourceId source) => source switch
    {
        SourceId.Teams => "teams",
        SourceId.AzureDevOps => "azureDevOps",
        SourceId.Copilot => "copilot",
        SourceId.GitHub => "github",
        _ => throw new ArgumentOutOfRangeException(paramName: nameof(source), actualValue: source, message: "Not a source."),
    };

    /// The source saved under `rawValue`, or false for one this version doesn't know.
    public static bool TryParse(string rawValue, out SourceId source)
    {
        foreach (var candidate in Enum.GetValues<SourceId>())
        {
            if (string.Equals(a: RawValue(source: candidate), b: rawValue, comparisonType: StringComparison.Ordinal))
            {
                source = candidate;
                return true;
            }
        }
        source = default;
        return false;
    }

    /// Such as "Microsoft Teams".
    public static string DisplayName(SourceId source) => source switch
    {
        SourceId.Teams => "Microsoft Teams",
        SourceId.AzureDevOps => "Azure DevOps",
        SourceId.Copilot => "GitHub Copilot",
        SourceId.GitHub => "GitHub",
        _ => throw new ArgumentOutOfRangeException(paramName: nameof(source), actualValue: source, message: "Not a source."),
    };
}
