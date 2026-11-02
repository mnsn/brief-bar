namespace BriefBar.Core.AzureDevOps;

/// What one of the things `PRReadiness` checks is about. The Mac's `PRReadiness.Item.Kind`.
public enum PRReadinessItemKind
{
    /// It's a draft, which can't be completed.
    Draft,

    /// A reviewer wants changes, or rejected it.
    ChangesRequested,

    /// Enough approvals, as its minimum-reviewers policy wants; or, without reviewer policies, one.
    Approvals,

    /// The reviewers it requires, whether a policy or someone added them.
    RequiredReviewers,

    /// Its build validation pipelines.
    Builds,

    /// The statuses other services post on it.
    Checks,

    /// Its comment threads: resolved, as a policy wants, or still open.
    Comments,

    /// A linked work item, as a policy wants.
    WorkItems,

    /// Any other blocking policy, by its name.
    Policy,

    /// Merge conflicts with its target branch.
    Conflicts,

    /// A merge Azure DevOps couldn't make otherwise: it failed, or a policy rejected it.
    MergeFailed,

    /// Its project doesn't let you read its policies, so nobody can tell whether it's ready.
    UnreadablePolicies,
}
