namespace BriefBar.Core.AzureDevOps;

/// One pull request in a sentence, for a brief: `Id` names it across refreshes while it's the same news. The Mac's
/// `BriefItem`, without the prompt that its summaries word it with.
public sealed record BriefItem(string Id, PRKey Key, PRGroup Group, PRReason Reason, string Sentence, Uri Url);
