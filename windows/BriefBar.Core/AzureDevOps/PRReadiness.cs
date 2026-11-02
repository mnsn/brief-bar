namespace BriefBar.Core.AzureDevOps;

/// What's left before you can complete one of your pull requests, and what's done: each thing Azure DevOps requires of it,
/// from its blocking policies, its reviewers' votes and its merge, as BriefBar last read them. Its row says the one thing
/// that matters most; this says all of them at once, so you can tell which are ready and what holds up the rest. The Mac's
/// `PRReadiness`.
/// - `Items`: what's left first, as the lists order states: what waits on you, what failed, what's running, what waits on
///   someone else, and what doesn't hold it up; then what's done. Each in the order Azure DevOps lists them.
/// - `IsCurrent`: its policies were read as it is now; false once it changed, by a push or a vote, until they're read
///   again.
public sealed record PRReadiness(ValueList<PRReadinessItem> Items, bool IsCurrent = true)
{
    const string MinimumReviewers = "Minimum number of reviewers";
    const string RequiredReviewersPolicy = "Required reviewers";
    const string CommentRequirements = "Comment requirements";
    const string WorkItemLinking = "Work item linking";

    /// Whether you can complete it as it is now: what was read of it is current, and everything it requires is done.
    public bool IsReady => IsCurrent && !Items.Any(predicate: item => item.IsRequired && !item.IsDone);

    /// What's left: everything that isn't done.
    public IReadOnlyList<PRReadinessItem> Left => [.. Items.Where(predicate: item => !item.IsDone)];

    /// For one of your open pull requests, once its details have been read; null for any other.
    public static PRReadiness? From(PRRecord record)
    {
        ArgumentNullException.ThrowIfNull(argument: record);
        var pr = record.PullRequest;
        return record.Role == PRRole.Author && pr.Status == PullRequestStatus.Active && record.Details is { } details
            ? From(pr: pr, details: details)
            : null;
    }

    /// As `PRClassifier` decides it's ready to complete: the same policies, read the same way, and the same votes.
    internal static PRReadiness From(PullRequest pr, PRDetails details)
    {
        var blocking = details.Checks.Where(predicate: check => check.IsBlocking && check.Kind != CheckKind.Completion && check.State != CheckState.NotApplicable).ToList();
        // Groups, such as a team a policy adds, count only as their policies say.
        var people = pr.Reviewers.Where(predicate: reviewer => !reviewer.IsGroup).ToList();
        var reviewerPolicies = blocking.Where(predicate: check => check.Kind == CheckKind.Reviewers).ToList();
        var requirements = blocking.Where(predicate: check => check.Kind == CheckKind.Requirement).ToList();
        // As the classifier has it: a reviewer policy that doesn't apply still means approvals are up to the policies.
        var hasReviewerPolicy = details.Checks.Any(predicate: check => check.Kind == CheckKind.Reviewers && check.IsBlocking);

        var items = new List<PRReadinessItem?>
        {
            pr.IsDraft ? new PRReadinessItem(Kind: PRReadinessItemKind.Draft, State: ItemState.NeedsYou, Label: "Publish the draft", Detail: "A draft can't be completed") : null,
            ChangesRequested(people: people),
            Approvals(people: people, reviewerPolicies: reviewerPolicies, hasReviewerPolicy: hasReviewerPolicy),
            RequiredReviewers(pr: pr, people: people, reviewerPolicies: reviewerPolicies),
        };
        items.AddRange(collection: OtherPolicies(policies: reviewerPolicies.Where(predicate: check => check.Name is not (MinimumReviewers or RequiredReviewersPolicy))));
        items.Add(item: Builds(builds: [.. blocking.Where(predicate: check => check.Kind == CheckKind.Build)]));
        items.Add(item: Statuses(statuses: [.. blocking.Where(predicate: check => check.Kind == CheckKind.Status)]));
        items.Add(item: Comments(threads: details.Threads, requirements: requirements));
        items.Add(item: WorkItems(requirements: requirements));
        items.AddRange(collection: OtherPolicies(policies: requirements.Where(predicate: check => check.Name is not (CommentRequirements or WorkItemLinking))));
        items.AddRange(collection: Merge(pr: pr));
        if (!details.ChecksKnown)
        {
            items.Add(item: new PRReadinessItem(
                Kind: PRReadinessItemKind.UnreadablePolicies,
                State: null,
                Label: "Can't read its policies",
                Detail: "Its project doesn't let you read its branch policies, so BriefBar can't tell whether it's ready"));
        }
        // A stable sort: each rank keeps the order Azure DevOps lists them in.
        var ordered = items.OfType<PRReadinessItem>().OrderBy(keySelector: item => item.Rank);
        return new PRReadiness(Items: new ValueList<PRReadinessItem>(items: ordered), IsCurrent: details.Fingerprint == pr.Fingerprint);
    }

    /// Its build validation pipelines, the worst first: a failure, with where it failed once that's known; one that expired
    /// or hasn't run, and has to be queued; one that's running; or all of them passed. Null without any.
    internal static PRReadinessItem? Builds(IReadOnlyList<Check> builds)
    {
        if (builds.Count == 0)
        {
            return null;
        }
        var failed = builds.Where(predicate: build => build.State == CheckState.Failed).ToList();
        if (failed.Count > 0)
        {
            var where = failed.Select(selector: build => build.Failure is { } failure ? build.Name + " · " + failure.Summary : build.Name);
            return Item(
                kind: PRReadinessItemKind.Builds,
                state: ItemState.Failing,
                label: failed.Count > 1 ? Counted(count: failed.Count) + " builds failed" : "Build failed",
                detail: string.Join(separator: ", ", values: where));
        }
        var expired = builds.Where(predicate: build => build.State == CheckState.Expired).ToList();
        if (expired.Count > 0)
        {
            return Item(
                kind: PRReadinessItemKind.Builds,
                state: ItemState.Failing,
                label: expired.Count > 1 ? Counted(count: expired.Count) + " builds expired" : "Build expired",
                detail: Names(checks: expired) + " · queue it again");
        }
        var notRun = builds.Where(predicate: build => build.State == CheckState.NotRun).ToList();
        if (notRun.Count > 0)
        {
            return Item(
                kind: PRReadinessItemKind.Builds,
                state: ItemState.NeedsYou,
                label: notRun.Count > 1 ? Counted(count: notRun.Count) + " builds haven't run" : "Build hasn't run",
                detail: Names(checks: notRun) + " · queue it");
        }
        var running = builds.Where(predicate: build => build.State is CheckState.Running or CheckState.Queued or CheckState.Pending).ToList();
        if (running.Count > 0)
        {
            var label = running.Count > 1 ? Counted(count: running.Count) + " builds running"
                : running[0].State == CheckState.Queued ? "Build queued"
                : "Build running";
            return Item(kind: PRReadinessItemKind.Builds, state: ItemState.Running, label: label, detail: Names(checks: running));
        }
        return Item(kind: PRReadinessItemKind.Builds, state: ItemState.Done, label: builds.Count > 1 ? "Builds passed" : "Build passed", detail: Names(checks: builds));
    }

    /// The statuses other services post on it: one that failed, ones still to come, or all of them passed. Null without
    /// any.
    internal static PRReadinessItem? Statuses(IReadOnlyList<Check> statuses)
    {
        if (statuses.Count == 0)
        {
            return null;
        }
        var failed = statuses.Where(predicate: status => status.State == CheckState.Failed).ToList();
        if (failed.Count > 0)
        {
            return Item(
                kind: PRReadinessItemKind.Checks,
                state: ItemState.Failing,
                label: failed.Count > 1 ? Counted(count: failed.Count) + " checks failed" : "Check failed",
                detail: Names(checks: failed));
        }
        var pending = statuses.Where(predicate: status => status.State is CheckState.Running or CheckState.Queued or CheckState.Pending).ToList();
        if (pending.Count > 0)
        {
            return Item(
                kind: PRReadinessItemKind.Checks,
                state: ItemState.Running,
                label: pending.Count > 1 ? Counted(count: pending.Count) + " checks running" : "Check running",
                detail: Names(checks: pending));
        }
        return Item(kind: PRReadinessItemKind.Checks, state: ItemState.Done, label: statuses.Count > 1 ? "Checks passed" : "Check passed", detail: Names(checks: statuses));
    }

    /// "Sam" for Sam Rivera; "Storefront Team" for the group "[Storefront]\Storefront Team".
    internal static string ShortName(Reviewer reviewer)
    {
        ArgumentNullException.ThrowIfNull(argument: reviewer);
        if (!reviewer.IsGroup)
        {
            return reviewer.Person.FirstName;
        }
        var name = reviewer.Person.Name;
        var end = name.IndexOf(value: "]\\", comparisonType: StringComparison.Ordinal);
        return name.StartsWith(value: '[') && end >= 0 ? name[(end + 2)..] : name;
    }

    /// A reviewer who wants changes, or rejected it, by first name; several, together. Null when nobody does.
    static PRReadinessItem? ChangesRequested(List<Reviewer> people)
    {
        var wantChanges = people.Where(predicate: reviewer => reviewer.Vote.WantsChanges()).ToList();
        if ((wantChanges.Find(match: reviewer => reviewer.Vote == Vote.Rejected) ?? wantChanges.FirstOrDefault()) is not { } first)
        {
            return null;
        }
        var label = wantChanges.Count > 1 ? "Changes requested"
            : first.Vote == Vote.Rejected ? first.Person.FirstName + " rejected it"
            : first.Person.FirstName + " wants changes";
        var rejected = NamesOf(reviewers: wantChanges.Where(predicate: reviewer => reviewer.Vote == Vote.Rejected));
        var waiting = NamesOf(reviewers: wantChanges.Where(predicate: reviewer => reviewer.Vote == Vote.WaitingForAuthor));
        var detail = string.Join(
            separator: " · ",
            values: new[] { rejected.Length == 0 ? null : "Rejected by " + rejected, waiting.Length == 0 ? null : "Changes requested by " + waiting }.OfType<string>());
        return Item(kind: PRReadinessItemKind.ChangesRequested, state: ItemState.NeedsYou, label: label, detail: detail);
    }

    /// How many approvals it has of the most its pending minimum-reviewers policy wants; without reviewer policies, whether
    /// someone approved. Null with reviewer policies, none of them a minimum, and no approvals.
    static PRReadinessItem? Approvals(List<Reviewer> people, List<Check> reviewerPolicies, bool hasReviewerPolicy)
    {
        var approvals = people.Where(predicate: reviewer => reviewer.Vote.IsApproval()).ToList();
        var approvedBy = approvals.Count == 0 ? null : "Approved by " + NamesOf(reviewers: approvals);
        var minimumPolicies = reviewerPolicies.Where(predicate: check => check.Name == MinimumReviewers).ToList();
        if (minimumPolicies.Count > 0)
        {
            // How many the one that isn't met yet wants, as the list's detail says it.
            var pending = minimumPolicies.Where(predicate: check => check.State != CheckState.Passed).ToList();
            var minimum = pending.Select(selector: check => check.MinimumApprovers).Max() ?? 1;
            var label = pending.Count == 0 ? "Approved"
                // Enough people approved, but not as the policy counts them: say, the last one to push can't approve.
                : approvals.Count >= minimum ? "Approval policy pending"
                : minimum > 1 ? Counted(count: approvals.Count) + " of " + Counted(count: minimum) + " approvals"
                : "Not approved yet";
            return Item(kind: PRReadinessItemKind.Approvals, state: pending.Count == 0 ? ItemState.Done : null, label: label, detail: approvedBy);
        }
        if (!hasReviewerPolicy || approvals.Count > 0)
        {
            // Without a reviewer policy, BriefBar wants someone's approval before it says it's ready.
            return Item(
                kind: PRReadinessItemKind.Approvals,
                state: approvals.Count == 0 ? null : ItemState.Done,
                label: approvals.Count == 0 ? "Not approved yet" : "Approved",
                detail: approvedBy);
        }
        return null;
    }

    /// A reviewer it requires holds it up until they approve, whether a policy or someone added them, even one who
    /// declined. Who wants changes is said already. A team is waited on only as a pending policy requires it: one whose
    /// own policy passed isn't, whatever its vote; every one that hasn't approved, when a pending policy doesn't say. Null
    /// when it requires nobody.
    static PRReadinessItem? RequiredReviewers(PullRequest pr, List<Reviewer> people, List<Check> reviewerPolicies)
    {
        var requiredPolicies = reviewerPolicies.Where(predicate: check => check.Name == RequiredReviewersPolicy).ToList();
        var pendingPolicies = requiredPolicies.Where(predicate: check => check.State != CheckState.Passed).ToList();
        var pendingIds = pendingPolicies.SelectMany(selector: check => check.ReviewerIds).ToHashSet(comparer: StringComparer.Ordinal);
        var unsaid = pendingPolicies.Exists(match: check => check.ReviewerIds.Count == 0);
        var requiredPeople = people.Where(predicate: reviewer => reviewer.IsRequired && !reviewer.Vote.IsApproval() && !reviewer.Vote.WantsChanges());
        var requiredGroups = pr.Reviewers.Where(predicate: reviewer =>
            reviewer.IsGroup && reviewer.IsRequired && !reviewer.Vote.IsApproval() && (unsaid || pendingIds.Contains(item: reviewer.Person.Id)));
        var waitingOn = requiredPeople.Concat(second: requiredGroups).ToList();
        if (waitingOn.Count > 0 || pendingPolicies.Count > 0)
        {
            var label = waitingOn.Count switch
            {
                0 => "Required reviewers",
                1 => "Waiting on " + ShortName(reviewer: waitingOn[0]),
                _ => "Waiting on " + Counted(count: waitingOn.Count) + " reviewers",
            };
            var detail = waitingOn.Count == 0 ? null : "Required: " + NamesOf(reviewers: waitingOn, limit: 5);
            return Item(kind: PRReadinessItemKind.RequiredReviewers, state: null, label: label, detail: detail);
        }
        return requiredPolicies.Count > 0 ? Item(kind: PRReadinessItemKind.RequiredReviewers, state: ItemState.Done, label: "Required reviewers") : null;
    }

    /// Its comment threads: resolved, or to resolve, as a policy requires; otherwise, the open ones, which don't hold it up.
    /// Null without a policy or open threads.
    static PRReadinessItem? Comments(IReadOnlyList<ReviewThread> threads, List<Check> requirements)
    {
        var open = threads.Count(predicate: thread => thread.Status is "active" or "pending");
        var commentPolicies = requirements.Where(predicate: check => check.Name == CommentRequirements).ToList();
        if (commentPolicies.Count > 0)
        {
            if (commentPolicies.TrueForAll(match: check => check.State == CheckState.Passed))
            {
                return Item(kind: PRReadinessItemKind.Comments, state: ItemState.Done, label: "Comments resolved");
            }
            var label = open switch
            {
                0 => "Resolve comments",
                1 => "Resolve 1 comment",
                _ => "Resolve " + Counted(count: open) + " comments",
            };
            return Item(kind: PRReadinessItemKind.Comments, state: ItemState.NeedsYou, label: label, detail: "A policy requires resolving every comment");
        }
        if (open == 0)
        {
            return null;
        }
        return new PRReadinessItem(
            Kind: PRReadinessItemKind.Comments, State: null, Label: open == 1 ? "1 open comment" : Counted(count: open) + " open comments", IsRequired: false);
    }

    /// A linked work item, as a policy requires one; null without such a policy.
    static PRReadinessItem? WorkItems(List<Check> requirements)
    {
        var workItemPolicies = requirements.Where(predicate: check => check.Name == WorkItemLinking).ToList();
        if (workItemPolicies.Count == 0)
        {
            return null;
        }
        var met = workItemPolicies.TrueForAll(match: check => check.State == CheckState.Passed);
        return Item(kind: PRReadinessItemKind.WorkItems, state: met ? ItemState.Done : ItemState.NeedsYou, label: met ? "Work item linked" : "Link a work item");
    }

    /// Any other blocking policies, each by its name, those of the same type together, such as two that each require a
    /// reviewer, in the order they came.
    static IEnumerable<PRReadinessItem> OtherPolicies(IEnumerable<Check> policies) => policies
        .GroupBy(keySelector: check => check.Name, comparer: StringComparer.Ordinal)
        .Select(selector: named => Item(
            kind: PRReadinessItemKind.Policy, state: named.All(predicate: check => check.State == CheckState.Passed) ? ItemState.Done : null, label: named.Key));

    /// Merge conflicts, and a merge Azure DevOps couldn't make otherwise.
    static IEnumerable<PRReadinessItem> Merge(PullRequest pr)
    {
        if (pr.HasConflicts)
        {
            yield return Item(kind: PRReadinessItemKind.Conflicts, state: ItemState.Failing, label: "Merge conflicts", detail: pr.SourceBranch + " into " + pr.TargetBranch);
        }
        if (pr.MergeProblem is { } problem)
        {
            yield return Item(kind: PRReadinessItemKind.MergeFailed, state: ItemState.Failing, label: problem.Headline, detail: problem.Detail);
        }
    }

    static PRReadinessItem Item(PRReadinessItemKind kind, ItemState? state, string label, string? detail = null) =>
        new(Kind: kind, State: state, Label: label, Detail: detail);

    /// "Priya Shah", "Priya Shah and Sam Rivera", the first `limit` and how many more past that.
    static string NamesOf(IEnumerable<Reviewer> reviewers, int limit = 3) =>
        ListWords.Join(names: [.. reviewers.Select(selector: reviewer => reviewer.Person.Name)], limit: limit);

    static string Names(IEnumerable<Check> checks) => string.Join(separator: ", ", values: checks.Select(selector: check => check.Name));

    static string Counted(int count) => count.ToString(provider: System.Globalization.CultureInfo.InvariantCulture);
}
