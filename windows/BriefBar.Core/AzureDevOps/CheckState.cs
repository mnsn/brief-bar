namespace BriefBar.Core.AzureDevOps;

/// How a branch policy stands.
public enum CheckState
{
    Passed,
    Failed,
    Running,
    Queued,

    /// A build that passed but is too old, or whose target branch moved: it has to run again.
    Expired,

    /// A build that hasn't run at all, as when it's queued by hand.
    NotRun,

    /// Waiting for something other than a build: approvals, a status, the author.
    Pending,

    NotApplicable,
}
