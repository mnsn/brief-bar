using System.Globalization;

namespace BriefBar.Core.AzureDevOps;

/// Votes as Azure DevOps sends them, and what they mean.
public static class Votes
{
    /// The vote `raw` stands for; none for nothing, or a value Azure DevOps doesn't use.
    public static Vote From(int? raw) => raw is { } value && Enum.IsDefined(value: (Vote)value) ? (Vote)value : Vote.None;

    /// The vote a thread property, such as `CodeReviewVoteResult`, says.
    public static Vote From(string? raw) =>
        From(raw: int.TryParse(s: raw, style: NumberStyles.AllowLeadingSign, provider: CultureInfo.InvariantCulture, result: out var value) ? value : null);

    public static bool IsApproval(this Vote vote) => vote is Vote.Approved or Vote.ApprovedWithSuggestions;

    /// Waiting for the author or rejected: the reviewer wants changes.
    public static bool WantsChanges(this Vote vote) => vote is Vote.WaitingForAuthor or Vote.Rejected;
}
