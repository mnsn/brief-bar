namespace BriefBar.Core.AzureDevOps;

/// What the pull requests' panel says in place of the list, as on the Mac, while there's nothing in it.
internal enum PRPlaceholder
{
    /// The list, or, when it's empty, "All clear" or the problem.
    None,

    /// It's finding your organizations, the first time.
    Finding,

    /// None of your organizations is watched.
    NoOrganizations,

    /// It's reading your organizations for the first time, or those just chosen.
    Loading,
}
