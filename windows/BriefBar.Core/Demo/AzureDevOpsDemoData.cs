using BriefBar.Core.AzureDevOps;
using BriefBar.Core.Settings;

namespace BriefBar.Core.Demo;

/// Made-up pull requests in every state, for working on the UI and taking screenshots without showing real ones
/// (`--demo`): the Mac's `DemoData` for Azure DevOps, without pull requests sent in chats, which Windows doesn't read. Its
/// Answered pull request is one Chen asked you to review, which you approved. Times are relative to `now`.
public static class AzureDevOpsDemoData
{
    public const string Organization = "contoso";

    static readonly Person sam = Teammate(suffix: "b001", name: "Sam Rivera");
    static readonly Person priya = Teammate(suffix: "b002", name: "Priya Shah");
    static readonly Person alex = Teammate(suffix: "b003", name: "Alex Kim");
    static readonly Person jordan = Teammate(suffix: "b004", name: "Jordan Lee");
    static readonly Person maria = Teammate(suffix: "b005", name: "Maria Garcia");
    static readonly Person chen = Teammate(suffix: "b006", name: "Chen Wei");
    static readonly Person buildService = new(id: "6f1c1a52-0000-4000-8000-00000000c001", name: "Storefront Build Service", isBot: true);

    public static Person Me { get; } = new(id: "6f1c1a52-0000-4000-8000-00000000a001", name: "Robin Diaz");

    /// The groups the demo pull requests land in.
    public static IReadOnlyDictionary<PRGroup, int> ExpectedCounts { get; } = new Dictionary<PRGroup, int>
    {
        [PRGroup.NeedsYou] = 3,
        [PRGroup.Answered] = 1,
        [PRGroup.Failing] = 2,
        [PRGroup.Ready] = 2,
        [PRGroup.ToReview] = 1,
        [PRGroup.Waiting] = 2,
        [PRGroup.Done] = 1,
        [PRGroup.Idle] = 2,
    };

    /// What you've seen besides the first run's three days: a pull request you opened since Sam replied on it, whose
    /// reply still waits on you.
    public static IReadOnlyList<(PRKey Key, DateTimeOffset Date)> Seen(DateTimeOffset now) =>
        [(new PRKey(Organization: Organization, Number: 4102), now.AddMinutes(minutes: -5))];

    /// Azure DevOps' settings in `storage` as the demo starts: its organization found, and what you've seen.
    public static AzureDevOpsSettings Settings(ISettingsStorage storage, DateTimeOffset now)
    {
        var settings = new AzureDevOpsSettings(settings: storage, now: now)
        {
            Organizations = [Organization],
            KnownOrganizations = [Organization],
            HasDiscovered = true,
        };
        settings.StartSeeing(now: now);
        settings.MarkSeen(entries: Seen(now: now));
        return settings;
    }

    public static PulseSnapshot Snapshot(DateTimeOffset now) => new()
    {
        Records = [.. Records(now: now)],
        Organizations = [Organization],
        UserName = Me.Name,
        FirstLoaded = new Dictionary<string, DateTimeOffset>(comparer: StringComparer.Ordinal) { [Organization] = now.AddSeconds(seconds: -20) },
        RefreshedAt = now.AddSeconds(seconds: -20),
        HasLoaded = true,
    };

    public static IReadOnlyList<PRRecord> Records(DateTimeOffset now)
    {
        DateTimeOffset Ago(double minutes) => now.AddMinutes(minutes: -minutes);
        const double hour = 60;
        const double day = 24 * hour;
        var mergeStrategy = new Check(Name: "Require a merge strategy", Kind: CheckKind.Completion, State: CheckState.Pending);

        PRRecord Record(
            PullRequest pr, PRRole role = PRRole.Author, IReadOnlyList<Check>? checks = null, IReadOnlyList<ReviewThread>? threads = null,
            IReadOnlyList<Activity>? activity = null)
        {
            var dates = (threads ?? []).SelectMany(selector: thread => thread.Comments.Select(selector: comment => comment.PublishedAt))
                .Concat(second: (activity ?? []).Select(selector: entry => entry.At))
                .ToList();
            var details = new PRDetails
            {
                FetchedAt = now,
                Fingerprint = pr.Fingerprint,
                Checks = [.. checks ?? []],
                Threads = [.. threads ?? []],
                Activity = [.. activity ?? []],
                LastActivity = dates.Count == 0 ? null : dates.Max(),
            };
            return new PRRecord(pullRequest: pr, role: role, me: Me.Id, details: pr.Status == PullRequestStatus.Active ? details : null);
        }

        /// The pipelines after a merge: its CI passed, then started a deployment that waits for approval to production.
        PRRecord Merged(PRRecord record)
        {
            var pr = record.PullRequest;
            PipelineRef Pipeline(int id, string name) => new(
                Organization: Organization, ProjectId: pr.ProjectId, ProjectName: pr.ProjectName, DefinitionId: id, Name: name, Folder: "Storefront\\CI");
            PipelineStage Stage(int id, string name, PipelineStageState state, double? startedAgo = null, double? minutes = null)
            {
                DateTimeOffset? started = startedAgo is { } ago ? Ago(minutes: ago) : null;
                return new PipelineStage(
                    Id: "merge-stage-" + id.ToString(provider: System.Globalization.CultureInfo.InvariantCulture),
                    Name: name,
                    State: state,
                    StartedAt: started,
                    FinishedAt: started is { } start && minutes is { } length ? start.AddMinutes(minutes: length) : null);
            }
            var ci = new PipelineRun
            {
                Id = 82_105,
                Organization = Organization,
                ProjectName = pr.ProjectName,
                Number = "20261025.5",
                Status = PipelineRunStatus.Succeeded,
                Trigger = PipelineTrigger.Push,
                Branch = pr.TargetBranch,
                RequestedFor = Me.Name,
                QueuedAt = Ago(minutes: 39.5),
                StartedAt = Ago(minutes: 39),
                FinishedAt = Ago(minutes: 31),
            };
            var deploy = new PipelineRun
            {
                Id = 82_109,
                Organization = Organization,
                ProjectName = pr.ProjectName,
                Number = "20261025.2",
                Status = PipelineRunStatus.Running,
                Trigger = PipelineTrigger.Pipeline,
                Branch = pr.TargetBranch,
                RequestedFor = Me.Name,
                QueuedAt = Ago(minutes: 30.5),
                StartedAt = Ago(minutes: 30),
            };
            return record with
            {
                Merge = new MergePipelines(
                    PullRequest: pr.Key,
                    Title: pr.Title,
                    TargetBranch: pr.TargetBranch,
                    MergedAt: pr.ClosedAt ?? Ago(minutes: 40),
                    Url: pr.WebUrl,
                    Pipelines:
                    [
                        new PipelineStatus(
                            Pipeline: Pipeline(id: 31, name: "shop-web CI"),
                            Runs: [ci],
                            Stages:
                            [
                                Stage(id: 1, name: "Build", state: PipelineStageState.Succeeded, startedAgo: 39, minutes: 2.4),
                                Stage(id: 2, name: "Test", state: PipelineStageState.Succeeded, startedAgo: 36.5, minutes: 5.4),
                            ]),
                        new PipelineStatus(
                            Pipeline: Pipeline(id: 36, name: "shop-web Deploy"),
                            Runs: [deploy],
                            Stages:
                            [
                                Stage(id: 3, name: "Deploy to staging", state: PipelineStageState.Succeeded, startedAgo: 30, minutes: 7.2),
                                Stage(id: 4, name: "Smoke tests", state: PipelineStageState.Succeeded, startedAgo: 22.6, minutes: 3.1),
                                Stage(id: 5, name: "Production", state: PipelineStageState.Waiting),
                            ]),
                    ],
                    IsFollowing: true),
            };
        }

        return
        [
            // Needs you: a reply to your comment, which you've seen (`Seen`) but haven't answered.
            Record(
                pr: NewPullRequest(
                    number: 4102, title: "Add retry with backoff to the payments client", repository: "payments-api", created: Ago(minutes: 26 * hour),
                    reviewers: [Reviewing(person: sam, required: true), Reviewing(person: priya, vote: Vote.Approved)], branch: "payments-retry"),
                checks:
                [
                    Build(name: "payments-api CI", state: CheckState.Passed, completed: Ago(minutes: 5 * hour)),
                    MinimumReviewers(state: CheckState.Pending, minimum: 2),
                    new Check(Name: "Comment requirements", Kind: CheckKind.Requirement, State: CheckState.Pending),
                    mergeStrategy,
                ],
                threads:
                [
                    new ReviewThread(
                        Id: 11,
                        Comments:
                        [
                            Comment(id: 1, author: Me, text: "I went with exponential backoff, starting at 200 ms and doubling each time.", at: Ago(minutes: 3 * hour)),
                            Comment(
                                id: 2,
                                author: sam,
                                text: "Could we cap the backoff at 30 seconds? Otherwise a slow dependency can stall checkout for minutes, "
                                    + "and the load balancer gives up after 60 seconds anyway.",
                                at: Ago(minutes: 12)),
                        ],
                        FilePath: "/src/PaymentsClient.cs",
                        Line: 88),
                ],
                activity: [Voted(thread: 12, person: priya, vote: Vote.Approved, at: Ago(minutes: 5 * hour))]),
            // Needs you: a mention on a pull request you review.
            Record(
                pr: NewPullRequest(
                    number: 4097, title: "Move image resizing to a background queue", repository: "shop-web", created: Ago(minutes: 2 * day), author: alex,
                    reviewers: [Reviewing(person: Me), Reviewing(person: maria, vote: Vote.Approved)], branch: "resize-queue"),
                role: PRRole.Reviewer,
                checks: [Build(name: "shop-web CI", state: CheckState.Passed, completed: Ago(minutes: 2 * day))],
                threads:
                [
                    new ReviewThread(
                        Id: 21,
                        Comments:
                        [
                            Comment(
                                id: 1,
                                author: alex,
                                text: "@Robin Diaz could you double-check the cache headers? I'm not sure 24 hours is right for thumbnails that change "
                                    + "when a seller edits a listing.",
                                at: Ago(minutes: 25),
                                mentions: [Me]),
                        ]),
                ],
                activity: [Added(thread: 22, person: Me, by: alex, at: Ago(minutes: 2 * day))]),
            // Needs you: a new review request.
            Record(
                pr: NewPullRequest(
                    number: 4110, title: "Upgrade the build agents to .NET 9", repository: "infra", created: Ago(minutes: 40), author: jordan,
                    reviewers: [Reviewing(person: Me, required: true), Reviewing(person: chen)], branch: "dotnet-9"),
                role: PRRole.Reviewer,
                checks: [Build(name: "infra CI", state: CheckState.Running, completed: null)],
                activity: [Added(thread: 31, person: Me, by: jordan, at: Ago(minutes: 40))]),
            // Answered: Chen asked you to review it, and you approved it. It stays in view until you've seen it in the panel.
            Record(
                pr: NewPullRequest(
                    number: 4108, title: "Fix the shipping label layout", repository: "shop-web", created: Ago(minutes: 3 * hour), author: chen,
                    reviewers: [Reviewing(person: alex, vote: Vote.Approved), Reviewing(person: Me, vote: Vote.Approved)], branch: "shipping-labels"),
                role: PRRole.Reviewer,
                checks: [Build(name: "shop-web CI", state: CheckState.Passed, completed: Ago(minutes: 2 * hour))],
                activity:
                [
                    Voted(thread: 131, person: alex, vote: Vote.Approved, at: Ago(minutes: 2 * hour)),
                    Added(thread: 132, person: Me, by: chen, at: Ago(minutes: 9)),
                    Voted(thread: 133, person: Me, vote: Vote.Approved, at: Ago(minutes: 6)),
                ]),
            // Failing: a build failed, in its unit tests (the build service's comment about it doesn't need you).
            Record(
                pr: NewPullRequest(
                    number: 4088, title: "Show delivery estimates on the product page", repository: "shop-web", created: Ago(minutes: 50 * hour),
                    reviewers: [Reviewing(person: maria, vote: Vote.Approved)], branch: "delivery-estimates"),
                checks:
                [
                    new Check(
                        Name: "shop-web CI",
                        Kind: CheckKind.Build,
                        State: CheckState.Failed,
                        CompletedAt: Ago(minutes: 65),
                        BuildId: 204_417,
                        Failure: new PipelineFailure(Stage: "Test", Step: "Run unit tests", Message: "2 tests failed in DeliveryEstimateTests.")),
                    MinimumReviewers(state: CheckState.Passed, minimum: 1),
                ],
                threads:
                [
                    new ReviewThread(
                        Id: 41,
                        Comments: [Comment(id: 1, author: buildService, text: "2 tests failed in DeliveryEstimateTests.", at: Ago(minutes: 64))],
                        Status: "closed"),
                ],
                activity: [Voted(thread: 42, person: maria, vote: Vote.Approved, at: Ago(minutes: 20 * hour))]),
            // Failing: merge conflicts.
            Record(
                pr: NewPullRequest(
                    number: 4079, title: "Rename the order status enum", repository: "payments-api", created: Ago(minutes: 4 * day),
                    reviewers: [Reviewing(person: chen)], branch: "rename-order-status", merge: "conflicts"),
                checks: [Build(name: "payments-api CI", state: CheckState.Passed, completed: Ago(minutes: 30 * hour)), MinimumReviewers(state: CheckState.Pending, minimum: 1)],
                activity: [new Activity(threadId: 51, kind: ActivityKind.Push, at: Ago(minutes: 30 * hour), actor: Me, commitCount: 2)]),
            // Ready to complete.
            Record(
                pr: NewPullRequest(
                    number: 4091, title: "Fix the coupon rounding error", repository: "payments-api", created: Ago(minutes: 30 * hour),
                    reviewers: [Reviewing(person: priya, vote: Vote.Approved), Reviewing(person: chen, vote: Vote.Approved)], branch: "coupon-rounding"),
                checks:
                [
                    Build(name: "payments-api CI", state: CheckState.Passed, completed: Ago(minutes: 4 * hour)),
                    MinimumReviewers(state: CheckState.Passed, minimum: 2),
                    new Check(Name: "Comment requirements", Kind: CheckKind.Requirement, State: CheckState.Passed),
                    mergeStrategy,
                ],
                activity:
                [
                    Voted(thread: 61, person: priya, vote: Vote.Approved, at: Ago(minutes: 3 * hour)),
                    Voted(thread: 62, person: chen, vote: Vote.Approved, at: Ago(minutes: 50)),
                ]),
            // Ready, completing automatically.
            Record(
                pr: NewPullRequest(
                    number: 4093, title: "Add dark mode to the account page", repository: "shop-web", created: Ago(minutes: 2 * day),
                    reviewers: [Reviewing(person: maria, vote: Vote.ApprovedWithSuggestions)], branch: "dark-mode", autoComplete: true),
                checks: [Build(name: "shop-web CI", state: CheckState.Passed, completed: Ago(minutes: 2 * hour)), MinimumReviewers(state: CheckState.Passed, minimum: 1)],
                activity: [Voted(thread: 71, person: maria, vote: Vote.ApprovedWithSuggestions, at: Ago(minutes: 2 * hour))]),
            // To review: a request from before the last three days, so it's been seen.
            Record(
                pr: NewPullRequest(
                    number: 4071, title: "Cache product search results", repository: "search", created: Ago(minutes: 5 * day), author: chen,
                    reviewers: [Reviewing(person: Me), Reviewing(person: alex, vote: Vote.Approved)], branch: "search-cache"),
                role: PRRole.Reviewer,
                checks: [Build(name: "search CI", state: CheckState.Passed, completed: Ago(minutes: 5 * day))],
                activity: [Added(thread: 81, person: Me, by: chen, at: Ago(minutes: 5 * day))]),
            // Waiting for reviewers while the build runs.
            Record(
                pr: NewPullRequest(
                    number: 4099, title: "Log slow database queries", repository: "infra", created: Ago(minutes: 90),
                    reviewers: [Reviewing(person: alex), Reviewing(person: jordan)], branch: "slow-query-log"),
                checks: [Build(name: "infra CI", state: CheckState.Running, completed: null), MinimumReviewers(state: CheckState.Pending, minimum: 2)],
                activity: [new Activity(threadId: 91, kind: ActivityKind.Push, at: Ago(minutes: 20), actor: Me, commitCount: 1)]),
            // Waiting for the author: you asked for changes.
            Record(
                pr: NewPullRequest(
                    number: 4060, title: "Add rate limiting to the public API", repository: "payments-api", created: Ago(minutes: 6 * day), author: sam,
                    reviewers: [Reviewing(person: Me, vote: Vote.WaitingForAuthor), Reviewing(person: priya)], branch: "rate-limits"),
                role: PRRole.Reviewer,
                checks: [Build(name: "payments-api CI", state: CheckState.Passed, completed: Ago(minutes: 6 * day))],
                threads:
                [
                    new ReviewThread(
                        Id: 101,
                        Comments: [Comment(id: 1, author: Me, text: "The limit should be per API key rather than per IP address.", at: Ago(minutes: day))]),
                ],
                activity: [Voted(thread: 102, person: Me, vote: Vote.WaitingForAuthor, at: Ago(minutes: day))]),
            // Done: merged 40 minutes ago; its CI passed, and the deployment it started waits for approval to production.
            Merged(record: Record(pr: NewPullRequest(
                number: 4085, title: "Update the README badges", repository: "shop-web", created: Ago(minutes: day), status: PullRequestStatus.Completed,
                closed: Ago(minutes: 40)))),
            // Idle: a draft.
            Record(
                pr: NewPullRequest(
                    number: 4105, title: "Prototype one-click checkout", repository: "shop-web", created: Ago(minutes: 3 * hour), branch: "one-click", draft: true),
                checks: [Build(name: "shop-web CI", state: CheckState.NotRun, completed: null)]),
            // Idle: no activity for weeks.
            Record(
                pr: NewPullRequest(
                    number: 3990, title: "Remove the legacy coupon API", repository: "payments-api", created: Ago(minutes: 40 * day),
                    reviewers: [Reviewing(person: priya)], branch: "remove-legacy-coupons"),
                checks: [Build(name: "payments-api CI", state: CheckState.Expired, completed: Ago(minutes: 23 * day))],
                threads:
                [
                    new ReviewThread(
                        Id: 111,
                        Comments: [Comment(id: 1, author: priya, text: "Do any partners still call the v1 endpoint?", at: Ago(minutes: 23 * day))]),
                ]),
        ];
    }

    static Person Teammate(string suffix, string name) => new(id: "6f1c1a52-0000-4000-8000-00000000" + suffix, name: name);

    static PullRequest NewPullRequest(
        int number, string title, string repository, DateTimeOffset created, Person? author = null, IReadOnlyList<Reviewer>? reviewers = null,
        string branch = "feature", bool draft = false, string merge = "succeeded", bool autoComplete = false,
        PullRequestStatus status = PullRequestStatus.Active, DateTimeOffset? closed = null) => new()
        {
            Key = new PRKey(Organization: Organization, Number: number),
            Title = title,
            Status = status,
            Author = author ?? Me,
            CreatedAt = created,
            ClosedAt = closed,
            ProjectId = "7a0c4e1d-0000-4000-8000-000000000001",
            ProjectName = "Storefront",
            RepositoryId = "repository-" + repository,
            RepositoryName = repository,
            SourceBranch = branch,
            TargetBranch = "main",
            IsDraft = draft,
            MergeStatus = merge,
            Reviewers = [.. reviewers ?? []],
            AutoComplete = autoComplete,
            SourceCommit = "c" + number.ToString(provider: System.Globalization.CultureInfo.InvariantCulture),
            TargetCommit = "t1",
        };

    static Reviewer Reviewing(Person person, Vote vote = Vote.None, bool required = false) => new(Person: person, Vote: vote, IsRequired: required);

    static ReviewComment Comment(int id, Person author, string text, DateTimeOffset at, IReadOnlyList<Person>? mentions = null) =>
        new(id: id, author: author, text: text, publishedAt: at, mentions: mentions?.Select(selector: person => person.Id));

    static Activity Voted(int thread, Person person, Vote vote, DateTimeOffset at) =>
        new(threadId: thread, kind: ActivityKind.Vote, at: at, actor: person, vote: vote);

    static Activity Added(int thread, Person person, Person by, DateTimeOffset at) =>
        new(threadId: thread, kind: ActivityKind.ReviewersChanged, at: at, actor: by, added: [person.Id]);

    static Check Build(string name, CheckState state, DateTimeOffset? completed) => new(Name: name, Kind: CheckKind.Build, State: state, CompletedAt: completed);

    static Check MinimumReviewers(CheckState state, int minimum) =>
        new(Name: "Minimum number of reviewers", Kind: CheckKind.Reviewers, State: state, MinimumApprovers: minimum);
}
