using BriefBar.Core.AzureDevOps;
using BriefBar.Core.Demo;
using BriefBar.Core.Settings;
using static BriefBar.Core.Tests.TestTimes;

namespace BriefBar.Core.Tests.AzureDevOps;

/// Ported from the `ReadinessTests` suite in Tests/AzureDevOpsCoreTests/ReadinessTests.swift: what's left before you can
/// complete one of your pull requests, and the order a list by date shows them in.
public sealed class ReadinessTests
{
    static readonly Check mergeStrategy = new(Name: "Require a merge strategy", Kind: CheckKind.Completion, State: CheckState.Pending);

    // What's left

    [Fact]
    public void WhatWaitsOnYouComesFirstThenOthersThenWhatsDone()
    {
        var pr = Make.PR(reviewers: [new Reviewer(Person: People.Priya, Vote: Vote.Approved), new Reviewer(Person: People.Sam, Vote: Vote.None, IsRequired: true)]);
        var ready = Readiness(
            pr: pr,
            checks: [Build(state: CheckState.Passed), MinimumPolicy(state: CheckState.Pending, count: 2), CommentPolicy(state: CheckState.Pending), WorkItemPolicy(state: CheckState.Passed), mergeStrategy],
            threads: [Thread(id: 1), Thread(id: 2, status: "fixed")]);
        Assert.Equal(expected: ["✋ Resolve 1 comment", "◷ 1 of 2 approvals", "◷ Waiting on Sam", "✓ Build passed", "✓ Work item linked"], actual: Said(readiness: ready));
        Assert.False(condition: ready.IsReady);
        Assert.True(condition: ready.IsCurrent);
        Assert.Equal(
            expected: [PRReadinessItemKind.Comments, PRReadinessItemKind.Approvals, PRReadinessItemKind.RequiredReviewers],
            actual: ready.Left.Select(selector: item => item.Kind));
        // Who approved, and who it requires, for the tooltip.
        Assert.Equal(expected: "Approved by Priya Shah", actual: Item(readiness: ready, kind: PRReadinessItemKind.Approvals).Detail);
        Assert.Equal(expected: "Required: Sam Rivera", actual: Item(readiness: ready, kind: PRReadinessItemKind.RequiredReviewers).Detail);
        // The merge strategy is chosen as it completes: it isn't something left.
        Assert.DoesNotContain(collection: ready.Items, filter: item => item.Label.Contains(value: "merge strategy", comparisonType: StringComparison.Ordinal));
    }

    [Fact]
    public void EverythingDoneIsReady()
    {
        var pr = Make.PR(reviewers: [new Reviewer(Person: People.Sam, Vote: Vote.Approved), new Reviewer(Person: People.Priya, Vote: Vote.ApprovedWithSuggestions)]);
        var record = Record(
            pr: pr,
            checks: [Build(state: CheckState.Passed), MinimumPolicy(state: CheckState.Passed, count: 2), CommentPolicy(state: CheckState.Passed), WorkItemPolicy(state: CheckState.Passed), mergeStrategy]);
        var ready = PRReadiness.From(record: record);
        Assert.NotNull(@object: ready);
        Assert.Equal(expected: ["✓ Approved", "✓ Build passed", "✓ Comments resolved", "✓ Work item linked"], actual: Said(readiness: ready));
        Assert.True(condition: ready.IsReady);
        Assert.Empty(collection: ready.Left);
        var row = Snapshot(record: record);
        Assert.Equal(expected: PRGroup.Ready, actual: row.Group);
        Assert.Equal(expected: ready, actual: row.Readiness);
    }

    [Fact]
    public void FailuresAndWhatYouHaveToDo()
    {
        var pr = Make.PR(draft: true, merge: "conflicts", reviewers: [new Reviewer(Person: People.Sam, Vote: Vote.WaitingForAuthor)]);
        var failure = new PipelineFailure(Stage: "Test", Step: "Run unit tests", Message: "2 tests failed in CheckoutTests.");
        var failed = new Check(Name: "web-ci", Kind: CheckKind.Build, State: CheckState.Failed, BuildId: 41, Failure: failure);
        var ready = Readiness(pr: pr, checks: [failed, new Check(Name: "scan", Kind: CheckKind.Status, State: CheckState.Running), MinimumPolicy(state: CheckState.Pending, count: 1)]);
        Assert.Equal(
            expected: ["✋ Publish the draft", "✋ Sam wants changes", "✕ Build failed", "✕ Merge conflicts", "↻ Check running", "◷ Not approved yet"],
            actual: Said(readiness: ready));
        Assert.Equal(expected: "web-ci · Run unit tests: 2 tests failed in CheckoutTests.", actual: Item(readiness: ready, kind: PRReadinessItemKind.Builds).Detail);
        Assert.Equal(expected: "fix-total into main", actual: Item(readiness: ready, kind: PRReadinessItemKind.Conflicts).Detail);
        Assert.Equal(expected: "Changes requested by Sam Rivera", actual: Item(readiness: ready, kind: PRReadinessItemKind.ChangesRequested).Detail);
    }

    [Fact]
    public void Builds()
    {
        static string? Builds(IEnumerable<Check> checks)
        {
            var item = Readiness(pr: Make.PR(reviewers: [new Reviewer(Person: People.Sam, Vote: Vote.Approved)]), checks: checks)
                .Items.FirstOrDefault(predicate: item => item.Kind == PRReadinessItemKind.Builds);
            return item is null ? null : item.Label + " | " + item.Detail;
        }
        static Check Api(CheckState state) => new(Name: "api-ci", Kind: CheckKind.Build, State: state);
        Assert.Equal(expected: "Build passed | web-ci", actual: Builds(checks: [Build(state: CheckState.Passed)]));
        Assert.Equal(expected: "Builds passed | web-ci, api-ci", actual: Builds(checks: [Build(state: CheckState.Passed), Api(state: CheckState.Passed)]));
        Assert.Equal(expected: "2 builds failed | web-ci, api-ci", actual: Builds(checks: [Build(state: CheckState.Failed), Api(state: CheckState.Failed)]));
        // The worst one says it.
        Assert.Equal(expected: "Build expired | web-ci · queue it again", actual: Builds(checks: [Build(state: CheckState.Expired), Api(state: CheckState.Running)]));
        Assert.Equal(expected: "Build hasn't run | web-ci · queue it", actual: Builds(checks: [Build(state: CheckState.NotRun), Api(state: CheckState.Passed)]));
        Assert.Equal(expected: "Build running | web-ci", actual: Builds(checks: [Build(state: CheckState.Running), Api(state: CheckState.Passed)]));
        Assert.Equal(expected: "Build queued | web-ci", actual: Builds(checks: [Build(state: CheckState.Queued)]));
        // An optional build, or one that doesn't apply, isn't something left.
        Assert.Null(@object: Builds(checks: [new Check(Name: "perf", Kind: CheckKind.Build, State: CheckState.Failed, IsBlocking: false), Api(state: CheckState.NotApplicable)]));

        static string? Statuses(IEnumerable<CheckState> states)
        {
            var statuses = states.Select(selector: (state, index) => new Check(Name: "status " + index.ToString(provider: System.Globalization.CultureInfo.InvariantCulture), Kind: CheckKind.Status, State: state));
            var item = Readiness(pr: Make.PR(), checks: statuses).Items.FirstOrDefault(predicate: item => item.Kind == PRReadinessItemKind.Checks);
            return item is null ? null : (item.State?.ToString() ?? "null") + " " + item.Label;
        }
        Assert.Equal(expected: "Failing Check failed", actual: Statuses(states: [CheckState.Failed, CheckState.Passed]));
        Assert.Equal(expected: "Running 2 checks running", actual: Statuses(states: [CheckState.Pending, CheckState.Running]));
        Assert.Equal(expected: "Done Checks passed", actual: Statuses(states: [CheckState.Passed, CheckState.Passed]));
    }

    [Fact]
    public void Reviewers()
    {
        static List<string> Approvals(IEnumerable<Reviewer> reviewers, IEnumerable<Check>? checks = null) =>
            [.. Said(readiness: Readiness(pr: Make.PR(reviewers: reviewers), checks: checks)).Where(predicate: line => !line.Contains(value: "Build", comparisonType: StringComparison.Ordinal))];
        var priya = new Reviewer(Person: People.Priya, Vote: Vote.Approved);
        var sam = new Reviewer(Person: People.Sam, Vote: Vote.Approved);
        // Without reviewer policies, someone's approval.
        Assert.Equal(expected: ["◷ Not approved yet"], actual: Approvals(reviewers: []));
        Assert.Equal(expected: ["✓ Approved"], actual: Approvals(reviewers: [priya]));
        // With a minimum, how many of how many.
        Assert.Equal(expected: ["◷ 1 of 3 approvals"], actual: Approvals(reviewers: [priya], checks: [MinimumPolicy(state: CheckState.Pending, count: 3)]));
        Assert.Equal(expected: ["◷ Not approved yet"], actual: Approvals(reviewers: [], checks: [MinimumPolicy(state: CheckState.Pending, count: 1)]));
        Assert.Equal(expected: ["✓ Approved"], actual: Approvals(reviewers: [priya], checks: [MinimumPolicy(state: CheckState.Passed, count: 1)]));
        // Enough approved, but not as the policy counts them; and the one that isn't met says how many.
        Assert.Equal(expected: ["◷ Approval policy pending"], actual: Approvals(reviewers: [priya, sam], checks: [MinimumPolicy(state: CheckState.Pending, count: 2)]));
        Assert.Equal(
            expected: ["◷ 1 of 2 approvals"],
            actual: Approvals(reviewers: [priya], checks: [MinimumPolicy(state: CheckState.Passed, count: 1), MinimumPolicy(state: CheckState.Pending, count: 2)]));

        // Who wants changes, by first name.
        Assert.Equal(expected: ["✋ Sam rejected it", "✓ Approved"], actual: Approvals(reviewers: [new Reviewer(Person: People.Sam, Vote: Vote.Rejected), priya]));
        var several = Readiness(pr: Make.PR(reviewers: [new Reviewer(Person: People.Sam, Vote: Vote.Rejected), new Reviewer(Person: People.Alex, Vote: Vote.WaitingForAuthor)]));
        Assert.Equal(expected: "✋ Changes requested", actual: Said(readiness: several)[0]);
        Assert.Equal(expected: "Rejected by Sam Rivera · Changes requested by Alex Kim", actual: several.Items[0].Detail);

        // A reviewer it requires, even one who declined; a team, as its policy says.
        var team = new Person(id: "66666666-6666-6666-6666-666666666666", name: "[Shop]\\Checkout Team");
        var required = new Check(Name: "Required reviewers", Kind: CheckKind.Reviewers, State: CheckState.Pending);
        var passed = new Check(Name: "Required reviewers", Kind: CheckKind.Reviewers, State: CheckState.Passed);
        Assert.Equal(
            expected: ["◷ Waiting on Alex", "✓ Approved"],
            actual: Approvals(reviewers: [priya, new Reviewer(Person: People.Alex, Vote: Vote.None, IsRequired: true, HasDeclined: true)]));
        Assert.Equal(
            expected: ["◷ Waiting on Checkout Team", "✓ Approved"],
            actual: Approvals(reviewers: [priya, new Reviewer(Person: team, Vote: Vote.None, IsRequired: true, IsGroup: true)], checks: [required]));
        Assert.Equal(
            expected: ["✓ Approved", "✓ Required reviewers"],
            actual: Approvals(reviewers: [priya, new Reviewer(Person: team, Vote: Vote.Approved, IsRequired: true, IsGroup: true)], checks: [passed]));
        // Its policy passed: the team's vote is up to it.
        Assert.Equal(
            expected: ["✓ Approved", "✓ Required reviewers"],
            actual: Approvals(reviewers: [priya, new Reviewer(Person: team, Vote: Vote.None, IsRequired: true, IsGroup: true)], checks: [passed]));
        // Two policies, each requiring a team: only the team whose policy is pending is waited on, whatever the other's
        // vote. The policy names it by its ID, in any case.
        var payments = new Person(id: "77777777-7777-7777-7777-777777777777", name: "[Shop]\\Payments Team");
        Reviewer[] teams = [new Reviewer(Person: team, Vote: Vote.None, IsRequired: true, IsGroup: true), new Reviewer(Person: payments, Vote: Vote.None, IsRequired: true, IsGroup: true)];
        Check[] policies =
        [
            passed with { ReviewerIds = [team.Id] },
            required with { ReviewerIds = [payments.Id.ToUpperInvariant()] },
        ];
        Assert.Equal(expected: ["◷ Waiting on Payments Team", "✓ Approved"], actual: Approvals(reviewers: [priya, .. teams], checks: policies));
        Assert.Equal(
            expected: ["◷ Not approved yet", "◷ Waiting on 2 reviewers"],
            actual: Approvals(reviewers: [new Reviewer(Person: People.Sam, Vote: Vote.None, IsRequired: true), new Reviewer(Person: People.Alex, Vote: Vote.None, IsRequired: true)]));
        // With a reviewer policy but no minimum, approvals aren't required, but they're said once there are some.
        Assert.Equal(
            expected: ["◷ Proof Of Presence"],
            actual: Approvals(reviewers: [], checks: [new Check(Name: "Proof Of Presence", Kind: CheckKind.Reviewers, State: CheckState.Pending)]));
    }

    [Fact]
    public void OpenComments()
    {
        ReviewThread[] open = [Thread(id: 1), Thread(id: 2, status: "pending"), Thread(id: 3, status: "closed"), Thread(id: 4, status: "wontFix")];
        var approved = Make.PR(reviewers: [new Reviewer(Person: People.Sam, Vote: Vote.Approved)]);
        Assert.Equal(expected: "✋ Resolve 2 comments", actual: Said(readiness: Readiness(pr: approved, checks: [CommentPolicy(state: CheckState.Pending)], threads: open))[0]);
        Assert.Equal(expected: "✋ Resolve comments", actual: Said(readiness: Readiness(pr: approved, checks: [CommentPolicy(state: CheckState.Pending)]))[0]);
        Assert.Equal(expected: "✓ Comments resolved", actual: Said(readiness: Readiness(pr: approved, checks: [CommentPolicy(state: CheckState.Passed)], threads: open))[^1]);

        // Without a policy that requires resolving them, open comments are said, but don't hold it up.
        var unrequired = Readiness(pr: approved, threads: open);
        Assert.Equal(expected: ["· 2 open comments", "✓ Approved"], actual: Said(readiness: unrequired));
        Assert.True(condition: unrequired.IsReady);
        Assert.DoesNotContain(collection: Readiness(pr: approved, threads: [Thread(id: 3, status: "closed")]).Items, filter: item => item.Kind == PRReadinessItemKind.Comments);
    }

    [Fact]
    public void OtherPolicies()
    {
        var pr = Make.PR(reviewers: [new Reviewer(Person: People.Sam, Vote: Vote.Approved)]);
        var ready = Readiness(
            pr: pr,
            checks:
            [
                WorkItemPolicy(state: CheckState.Pending),
                new Check(Name: "File size restriction", Kind: CheckKind.Requirement, State: CheckState.Pending),
                new Check(Name: "File size restriction", Kind: CheckKind.Requirement, State: CheckState.Passed),
                new Check(Name: "Path length", Kind: CheckKind.Requirement, State: CheckState.Passed),
            ]);
        Assert.Equal(expected: ["✋ Link a work item", "◷ File size restriction", "✓ Approved", "✓ Path length"], actual: Said(readiness: ready));
    }

    /// When nobody can tell, it isn't ready; and once it changed, by a push or a vote, until its policies are read again.
    [Fact]
    public void OnlyWhatsKnownAndCurrentIsReady()
    {
        var pr = Make.PR(reviewers: [new Reviewer(Person: People.Sam, Vote: Vote.Approved)]);
        var unreadable = Readiness(pr: pr, checksKnown: false);
        Assert.Equal(expected: ["◷ Can't read its policies", "✓ Approved"], actual: Said(readiness: unreadable));
        Assert.False(condition: unreadable.IsReady);

        var details = Make.Details(pr: pr, checks: [Build(state: CheckState.Passed), MinimumPolicy(state: CheckState.Passed, count: 1)], lastActivity: T(seconds: -Make.Hour));
        var outdated = PRReadiness.From(record: new PRRecord(pullRequest: pr with { SourceCommit = "abd" }, role: PRRole.Author, me: People.Me.Id, details: details));
        Assert.NotNull(@object: outdated);
        Assert.False(condition: outdated.IsCurrent);
        Assert.False(condition: outdated.IsReady);
        Assert.Empty(collection: outdated.Left);
    }

    [Fact]
    public void OnlyYourOpenPullRequestsOnceRead()
    {
        var pr = Make.PR(author: People.Sam, reviewers: [new Reviewer(Person: People.Me, Vote: Vote.None)]);
        Assert.Null(@object: PRReadiness.From(record: new PRRecord(pullRequest: pr, role: PRRole.Reviewer, me: People.Me.Id, details: Make.Details(pr: pr))));
        Assert.Null(@object: PRReadiness.From(record: new PRRecord(pullRequest: Make.PR(), role: PRRole.Author, me: People.Me.Id)));
        var completed = Make.PR(status: PullRequestStatus.Completed, closed: T(seconds: -Make.Hour));
        Assert.Null(@object: PRReadiness.From(record: new PRRecord(pullRequest: completed, role: PRRole.Author, me: People.Me.Id, details: Make.Details(pr: completed))));

        var review = Snapshot(record: new PRRecord(pullRequest: pr, role: PRRole.Reviewer, me: People.Me.Id, details: Make.Details(pr: pr, lastActivity: T(seconds: -Make.Hour))));
        Assert.Null(@object: review.Readiness);
        Assert.Equal(expected: pr.CreatedAt, actual: review.CreatedAt);
    }

    /// The list says it's ready to complete exactly when nothing it requires is left.
    [Fact]
    public void ReadyAsTheListSaysIt()
    {
        var sam = new Reviewer(Person: People.Sam, Vote: Vote.Approved);
        Reviewer[][] reviewerSets =
        [
            [], [sam], [sam, new Reviewer(Person: People.Priya, Vote: Vote.None, IsRequired: true)],
            [sam, new Reviewer(Person: People.Alex, Vote: Vote.WaitingForAuthor)],
            [sam, new Reviewer(Person: new Person(id: "team", name: "[Shop]\\Team"), Vote: Vote.None, IsRequired: true, IsGroup: true)],
        ];
        Check[][] checkSets =
        [
            [], [Build(state: CheckState.Passed)], [Build(state: CheckState.Failed)], [Build(state: CheckState.Running)], [Build(state: CheckState.Expired)],
            [Build(state: CheckState.NotRun)], [Build(state: CheckState.Passed), MinimumPolicy(state: CheckState.Passed, count: 1)],
            [Build(state: CheckState.Passed), MinimumPolicy(state: CheckState.Pending, count: 2)], [Build(state: CheckState.Passed), CommentPolicy(state: CheckState.Pending)],
            [Build(state: CheckState.Passed), CommentPolicy(state: CheckState.Passed), WorkItemPolicy(state: CheckState.Passed)],
            [new Check(Name: "scan", Kind: CheckKind.Status, State: CheckState.Pending)],
            [new Check(Name: "Required reviewers", Kind: CheckKind.Reviewers, State: CheckState.Passed)],
            [new Check(Name: "Required reviewers", Kind: CheckKind.Reviewers, State: CheckState.Pending)],
        ];
        foreach (var reviewers in reviewerSets)
        {
            foreach (var checks in checkSets)
            {
                foreach (var merge in new[] { "succeeded", "conflicts", "failure", "rejectedByPolicy" })
                {
                    foreach (var known in new[] { true, false })
                    {
                        var pr = Make.PR(reviewers: reviewers, merge: merge, autoComplete: merge == "succeeded" && known);
                        var row = Snapshot(record: Record(pr: pr, checks: known ? checks : [], checksKnown: known));
                        Assert.NotNull(@object: row.Readiness);
                        var votes = string.Join(separator: ",", values: reviewers.Select(selector: reviewer => reviewer.Vote));
                        var names = string.Join(separator: ",", values: checks.Select(selector: check => check.Name + "=" + check.State));
                        Assert.True(condition: (row.Group == PRGroup.Ready) == row.Readiness.IsReady, userMessage: $"{votes} {names} {merge} {known}");
                    }
                }
            }
        }

        // Something new that needs you, or two weeks without activity, comes first: nothing's left all the same.
        var approved = Make.PR(reviewers: [sam]);
        Check[] passing = [Build(state: CheckState.Passed), MinimumPolicy(state: CheckState.Passed, count: 1)];
        var commented = Snapshot(record: Record(pr: approved, checks: passing, threads: [Thread(id: 1)]));
        Assert.Equal(expected: PRGroup.NeedsYou, actual: commented.Group);
        Assert.True(condition: commented.Readiness?.IsReady);
        var quietPr = Make.PR(created: T(seconds: -40 * Make.Day), reviewers: [sam]);
        var idle = Snapshot(record: new PRRecord(
            pullRequest: quietPr, role: PRRole.Author, me: People.Me.Id, details: Make.Details(pr: quietPr, checks: passing, lastActivity: T(seconds: -30 * Make.Day))));
        Assert.Equal(expected: PRGroup.Idle, actual: idle.Group);
        Assert.True(condition: idle.Readiness?.IsReady);
    }

    // Required reviewers in the list

    /// A merge Azure DevOps couldn't make, for something other than conflicts, holds it up as conflicts do, however its
    /// policies stand, and what's left says so first.
    [Fact]
    public void AMergeAzureDevOpsCouldntMakeIsFailing()
    {
        Reviewer[] approved = [new Reviewer(Person: People.Sam, Vote: Vote.Approved)];
        Check[] passing = [Build(state: CheckState.Passed), MinimumPolicy(state: CheckState.Passed, count: 1)];
        (string Merge, string Headline, string Detail)[] cases =
        [
            ("failure", "Merge failed", "Azure DevOps couldn't merge fix-total into main"),
            ("rejectedByPolicy", "Merge rejected", "A policy rejected merging fix-total into main"),
        ];
        foreach (var (merge, headline, detail) in cases)
        {
            var row = Snapshot(record: Record(pr: Make.PR(reviewers: approved, merge: merge), checks: passing));
            Assert.Equal(expected: (PRGroup.Failing, PRReason.MergeFailed, headline, detail), actual: (row.Group, row.Reason, row.Headline, row.Detail));
            Assert.NotNull(@object: row.Readiness);
            Assert.Equal(expected: ["✕ " + headline, "✓ Approved", "✓ Build passed"], actual: Said(readiness: row.Readiness));
            Assert.Equal(expected: detail, actual: row.Readiness.Items[0].Detail);
            Assert.False(condition: row.Readiness.IsReady);
        }
    }

    [Fact]
    public void ARequiredReviewerWhoHasntApprovedIsLeft()
    {
        Check[] checks = [Build(state: CheckState.Passed), MinimumPolicy(state: CheckState.Passed, count: 1)];
        var pr = Make.PR(reviewers: [new Reviewer(Person: People.Priya, Vote: Vote.Approved), new Reviewer(Person: People.Sam, Vote: Vote.None, IsRequired: true)]);
        var row = Snapshot(record: Record(pr: pr, checks: checks));
        Assert.Equal(expected: PRGroup.Waiting, actual: row.Group);
        Assert.NotNull(@object: row.Readiness);
        Assert.Equal(expected: ["◷ Waiting on Sam", "✓ Approved", "✓ Build passed"], actual: Said(readiness: row.Readiness));

        // Once they approved, it's ready, and nothing's left.
        var approved = Make.PR(reviewers: [new Reviewer(Person: People.Priya, Vote: Vote.Approved), new Reviewer(Person: People.Sam, Vote: Vote.Approved, IsRequired: true)]);
        var ready = Snapshot(record: Record(pr: approved, checks: checks));
        Assert.Equal(expected: PRGroup.Ready, actual: ready.Group);
        Assert.True(condition: ready.Readiness?.IsReady);
        // More than five it requires: the first five, and how many more.
        Person[] others =
        [
            new(id: "88888888-8888-8888-8888-888888888881", name: "Jordan Lee"),
            new(id: "88888888-8888-8888-8888-888888888882", name: "Casey Park"),
            new(id: "88888888-8888-8888-8888-888888888883", name: "Maria Garcia"),
            new(id: "88888888-8888-8888-8888-888888888884", name: "Chen Wei"),
            new(id: "88888888-8888-8888-8888-888888888885", name: "Noor Haddad"),
        ];
        var many = Readiness(
            pr: Make.PR(reviewers: [new Reviewer(Person: People.Sam, Vote: Vote.None, IsRequired: true), .. others.Select(selector: person => new Reviewer(Person: person, Vote: Vote.None, IsRequired: true))]),
            checks: checks);
        var waiting = Item(readiness: many, kind: PRReadinessItemKind.RequiredReviewers);
        Assert.Equal(expected: "Waiting on 6 reviewers", actual: waiting.Label);
        Assert.Equal(expected: "Required: Sam Rivera, Jordan Lee, Casey Park, Maria Garcia, Chen Wei, and 1 more", actual: waiting.Detail);
    }

    // Order

    [Fact]
    public void OrdersByWhenEachWasCreated()
    {
        static PRSnapshot Listed(int number, PRGroup group, DateTimeOffset? created, DateTimeOffset since)
        {
            var snapshot = Snapshot(record: new PRRecord(pullRequest: Make.PR(number: number), role: PRRole.Author, me: People.Me.Id));
            return snapshot with { Group = group, CreatedAt = created, Since = since };
        }
        PRSnapshot[] items =
        [
            Listed(number: 1, group: PRGroup.Idle, created: T(seconds: -9 * Make.Day), since: T(seconds: -1)),
            Listed(number: 2, group: PRGroup.NeedsYou, created: T(seconds: -2 * Make.Day), since: T(seconds: -5)),
            Listed(number: 3, group: PRGroup.Ready, created: T(seconds: -5 * Make.Day), since: T(seconds: -50)),
            Listed(number: 4, group: PRGroup.Waiting, created: null, since: T(seconds: 0)),
            Listed(number: 5, group: PRGroup.Failing, created: T(seconds: -Make.Hour), since: T(seconds: -Make.Hour)),
            Listed(number: 6, group: PRGroup.Done, created: T(seconds: -2 * Make.Day), since: T(seconds: -10)),
        ];
        List<PRSnapshot> shuffled = [.. items.AsEnumerable().Reverse()];
        Assert.Equal(expected: [5, 6, 2, 3, 1, 4], actual: PROrdering.Sorted(snapshots: shuffled, order: PROrder.NewestFirst).Select(selector: item => item.Key.Number));
        Assert.Equal(expected: [1, 3, 2, 6, 5, 4], actual: PROrdering.Sorted(snapshots: shuffled, order: PROrder.OldestFirst).Select(selector: item => item.Key.Number));
        Assert.Equal(expected: PROrdering.Sorted(snapshots: items), actual: PROrdering.Sorted(snapshots: shuffled, order: PROrder.Status));
        Assert.Equal(expected: [PROrder.NewestFirst, PROrder.OldestFirst], actual: PROrders.All.Where(predicate: order => order.IsByDate()));

        // Each says when it was created.
        var created = T(seconds: -4 * Make.Day);
        var row = Snapshot(record: new PRRecord(pullRequest: Make.PR(created: created), role: PRRole.Author, me: People.Me.Id));
        Assert.Equal(expected: created, actual: row.CreatedAt);
    }

    [Fact]
    public void TheDemosPullRequestsSayWhatsLeft()
    {
        var now = T(seconds: 0);
        var settings = AzureDevOpsDemoData.Settings(storage: new MemorySettings(), now: now);
        var rows = AzureDevOpsDemoData.Records(now: now)
            .Select(selector: record => PRClassifier.Snapshot(
                record: record, seenCutoff: settings.SeenCutoff(key: record.Id), dismissedCutoff: settings.DismissedCutoff(key: record.Id), now: now, options: settings.ClassifierOptions))
            .OfType<PRSnapshot>()
            .ToList();
        List<string> SaidOf(int number)
        {
            var readiness = Assert.Single(collection: rows, predicate: row => row.Key.Number == number).Readiness;
            Assert.NotNull(@object: readiness);
            return Said(readiness: readiness);
        }
        Assert.Equal(expected: ["✓ Approved", "✓ Build passed", "✓ Comments resolved"], actual: SaidOf(number: 4091));
        Assert.Equal(expected: ["✋ Resolve 1 comment", "◷ 1 of 2 approvals", "◷ Waiting on Sam", "✓ Build passed"], actual: SaidOf(number: 4102));
        Assert.Equal(expected: ["✕ Build failed", "✓ Approved"], actual: SaidOf(number: 4088));
        Assert.Equal(expected: ["✕ Merge conflicts", "◷ Not approved yet", "✓ Build passed"], actual: SaidOf(number: 4079));
        Assert.Equal(expected: ["↻ Build running", "◷ 0 of 2 approvals"], actual: SaidOf(number: 4099));
        // Reviews, and what's closed, don't say it.
        Assert.Null(@object: Assert.Single(collection: rows, predicate: row => row.Key.Number == 4097).Readiness);
        Assert.Null(@object: Assert.Single(collection: rows, predicate: row => row.Key.Number == 4085).Readiness);
        // Every one of your open pull requests does.
        Assert.All(collection: rows.Where(predicate: row => row.Role == PRRole.Author && row.Group != PRGroup.Done), action: row => Assert.NotNull(@object: row.Readiness));
    }

    static PRRecord Record(PullRequest pr, IEnumerable<Check>? checks = null, bool checksKnown = true, IEnumerable<ReviewThread>? threads = null) =>
        new(pullRequest: pr, role: PRRole.Author, me: People.Me.Id, details: Make.Details(pr: pr, checks: checks, checksKnown: checksKnown, threads: threads, lastActivity: T(seconds: -Make.Hour)));

    static PRReadiness Readiness(PullRequest pr, IEnumerable<Check>? checks = null, bool checksKnown = true, IEnumerable<ReviewThread>? threads = null)
    {
        var readiness = PRReadiness.From(record: Record(pr: pr, checks: checks, checksKnown: checksKnown, threads: threads));
        Assert.NotNull(@object: readiness);
        return readiness;
    }

    static PRSnapshot Snapshot(PRRecord record)
    {
        var snapshot = PRClassifier.Snapshot(record: record, seenCutoff: T(seconds: -3 * Make.Day), dismissedCutoff: T(seconds: -3 * Make.Day), now: T(seconds: 0));
        Assert.NotNull(@object: snapshot);
        return snapshot;
    }

    static PRReadinessItem Item(PRReadiness readiness, PRReadinessItemKind kind) => Assert.Single(collection: readiness.Items, predicate: item => item.Kind == kind);

    /// "✋ Resolve 1 comment", "◷ 1 of 2 approvals"…
    static List<string> Said(PRReadiness readiness) => [.. readiness.Items.Select(selector: item => Mark(item: item) + " " + item.Label)];

    static string Mark(PRReadinessItem item) => item.State switch
    {
        ItemState.Done => "✓",
        ItemState.Failing => "✕",
        ItemState.NeedsYou => "✋",
        ItemState.Running => "↻",
        null => item.IsRequired ? "◷" : "·",
        _ => throw new ArgumentOutOfRangeException(paramName: nameof(item), actualValue: item.State, message: "Not a state."),
    };

    static Check MinimumPolicy(CheckState state, int count) => new(Name: "Minimum number of reviewers", Kind: CheckKind.Reviewers, State: state, MinimumApprovers: count);

    static Check CommentPolicy(CheckState state) => new(Name: "Comment requirements", Kind: CheckKind.Requirement, State: state);

    static Check WorkItemPolicy(CheckState state) => new(Name: "Work item linking", Kind: CheckKind.Requirement, State: state);

    static Check Build(CheckState state) => new(Name: "web-ci", Kind: CheckKind.Build, State: state);

    static ReviewThread Thread(int id, string status = "active") =>
        new(Id: id, Comments: [Make.Comment(id: 1, author: People.Sam, at: T(seconds: -2 * Make.Hour), text: "Cap it")], Status: status);
}
