using System.Globalization;

namespace BriefBar.Core.GitHub;

/// Decides where each pull request goes. Something wrong with your own comes first, then what a reviewer asks of you,
/// then whether it's waiting or ready. The Mac's `GitHubClassifier`.
public static class GitHubClassifier
{
    public static GitHubPRSnapshot Classify(GitHubPullRequest pullRequest, GitHubPRRole role)
    {
        ArgumentNullException.ThrowIfNull(argument: pullRequest);
        GitHubPRSnapshot Snapshot(GitHubPRGroup group, GitHubPRReason reason, string headline, string? detail = null) =>
            new(PullRequest: pullRequest, Role: role, Group: group, Reason: reason, Headline: headline, Detail: detail);

        if (role == GitHubPRRole.Reviewer)
        {
            return Snapshot(group: GitHubPRGroup.ToReview, reason: GitHubPRReason.ReviewRequested, headline: "Review requested", detail: pullRequest.Author is { } author ? "By " + author : null);
        }
        if (pullRequest.IsDraft)
        {
            return Snapshot(group: GitHubPRGroup.Waiting, reason: GitHubPRReason.Draft, headline: "Draft");
        }
        if (pullRequest.Checks == GitHubChecks.Failing)
        {
            return Snapshot(group: GitHubPRGroup.Failing, reason: GitHubPRReason.ChecksFailed, headline: pullRequest.HasConflicts ? "Checks failing · merge conflicts" : "Checks failing");
        }
        if (pullRequest.HasConflicts)
        {
            return Snapshot(group: GitHubPRGroup.Failing, reason: GitHubPRReason.Conflicts, headline: "Merge conflicts");
        }
        var changesRequestedBy = pullRequest.Reviewers(state: GitHubReviewState.ChangesRequested);
        if (pullRequest.ReviewDecision == GitHubReviewDecision.ChangesRequested || (pullRequest.ReviewDecision is null && changesRequestedBy.Count > 0))
        {
            return Snapshot(
                group: GitHubPRGroup.ChangesRequested,
                reason: GitHubPRReason.ChangesRequested,
                headline: "Changes requested",
                detail: changesRequestedBy.Count == 0 ? null : "By " + Names(names: changesRequestedBy));
        }
        if (pullRequest.Checks == GitHubChecks.Running)
        {
            return Snapshot(group: GitHubPRGroup.Waiting, reason: GitHubPRReason.ChecksRunning, headline: "Checks running");
        }
        var approvedBy = pullRequest.Reviewers(state: GitHubReviewState.Approved);
        if (pullRequest.ReviewDecision == GitHubReviewDecision.Approved || (pullRequest.ReviewDecision is null && approvedBy.Count > 0))
        {
            return Snapshot(group: GitHubPRGroup.Ready, reason: GitHubPRReason.Approved, headline: "Approved", detail: approvedBy.Count == 0 ? null : "By " + Names(names: approvedBy));
        }
        return Snapshot(group: GitHubPRGroup.Waiting, reason: GitHubPRReason.WaitingForReview, headline: "Waiting for review");
    }

    /// Each pull request once, yours first when it's both, in the list's order.
    public static IReadOnlyList<GitHubPRSnapshot> Snapshots(IEnumerable<GitHubPullRequest> reviewing, IEnumerable<GitHubPullRequest> authored)
    {
        ArgumentNullException.ThrowIfNull(argument: reviewing);
        ArgumentNullException.ThrowIfNull(argument: authored);
        var seen = new HashSet<string>(comparer: StringComparer.Ordinal);
        var snapshots = authored.Select(selector: pullRequest => (PullRequest: pullRequest, Role: GitHubPRRole.Author))
            .Concat(second: reviewing.Select(selector: pullRequest => (PullRequest: pullRequest, Role: GitHubPRRole.Reviewer)))
            .Where(predicate: pair => seen.Add(item: pair.PullRequest.Id))
            .Select(selector: pair => Classify(pullRequest: pair.PullRequest, role: pair.Role));
        return Sorted(snapshots: snapshots);
    }

    /// By group, then the most recently changed first.
    public static IReadOnlyList<GitHubPRSnapshot> Sorted(IEnumerable<GitHubPRSnapshot> snapshots)
    {
        ArgumentNullException.ThrowIfNull(argument: snapshots);
        return snapshots.OrderBy(keySelector: snapshot => snapshot.Group)
            .ThenByDescending(keySelector: snapshot => snapshot.Since)
            .ThenBy(keySelector: snapshot => snapshot.Id, comparer: StringComparer.Ordinal)
            .ToList();
    }

    /// "priya", "priya and sam", "priya, sam, and kai", "priya, sam, and 2 others", as Windows writes a list
    /// (`ListWords`), where the Mac writes "priya, sam and kai".
    public static string Names(IReadOnlyList<string> names)
    {
        ArgumentNullException.ThrowIfNull(argument: names);
        return names.Count > 3
            ? ListWords.Join(names: [names[0], names[1], (names.Count - 2).ToString(provider: CultureInfo.InvariantCulture) + " others"])
            : ListWords.Join(names: names);
    }
}
