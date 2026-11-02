namespace BriefBar.Core.AzureDevOps;

/// Whether you wrote the pull request, were asked to review it, or someone sent you a link to it.
public enum PRRole
{
    Author,
    Reviewer,

    /// You're neither its author nor a reviewer: someone sent it to you in a chat.
    Linked,
}
