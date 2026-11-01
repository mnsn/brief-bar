namespace BriefBar.Core.AzureDevOps;

/// The groups a pull request can be in, in the order the panel shows them. The Mac's `PRGroup`.
public enum PRGroup
{
    /// Something new for you: a reply, a mention, a comment, a review request, a vote that wants changes. And comments
    /// you've seen that still wait on you, until you reply, they're resolved, or you take the pull request off Needs you.
    NeedsYou,

    /// Something that needed you that you've since answered yourself in Azure DevOps, until you've seen it in the panel.
    /// Only for pull requests that would otherwise wait or be idle.
    Answered,

    /// Your pull requests with a failed build or check, merge conflicts or an expired build.
    Failing,

    /// Your pull requests that are approved and pass every required check.
    Ready,

    /// Review requests you've seen but haven't voted on.
    ToReview,

    /// Your pull requests waiting on reviewers or checks, and reviews waiting on their author.
    Waiting,

    /// Completed or abandoned recently.
    Done,

    /// Nothing to do: drafts, pull requests without recent activity, reviews you've approved or declined.
    Idle,
}
