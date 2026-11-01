using System.Globalization;
using BriefBar.Core.AzureDevOps;

namespace BriefBar.ViewModels;

/// A pull request you watch, on Azure DevOps' page in Settings: which one, and where, as the Mac names one it hasn't read,
/// "!4071 in shop-web".
public sealed class WatchedPullRequestViewModel(PullRequestLink link)
{
    public PRKey Key => link.Key;

    public string Title => "!" + link.Number.ToString(provider: CultureInfo.InvariantCulture) + " in " + link.Repository;

    public string Detail => link.Project + " · " + link.Organization;

    /// What Narrator calls its button.
    public string StopName => "Stop watching " + Title;
}
