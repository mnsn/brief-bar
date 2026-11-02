namespace BriefBar.Core.AzureDevOps;

/// How the pull requests are listed: by what each needs from you, or by when each was created. The Mac's `PROrder`.
public enum PROrder
{
    /// In their groups, Needs you first, the most recent first in each.
    Status,

    /// By when each was created, the newest first.
    NewestFirst,

    /// By when each was created, the ones open longest first.
    OldestFirst,
}
