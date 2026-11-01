namespace BriefBar.Core.AzureDevOps;

/// What a branch policy is about.
public enum CheckKind
{
    /// A build validation pipeline.
    Build,

    /// A status posted by another service.
    Status,

    /// Minimum reviewers, required reviewers and similar sign-offs.
    Reviewers,

    /// Something the author has to do, such as linking a work item or resolving comments.
    Requirement,

    /// Checked when the pull request is completed, such as the merge strategy, so it doesn't count against being ready.
    Completion,
}
