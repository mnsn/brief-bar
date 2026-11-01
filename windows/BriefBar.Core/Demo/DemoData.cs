using BriefBar.Core.Presentation;

namespace BriefBar.Core.Demo;

/// Made-up data for every section, in the spirit of the Mac's `--demo`: for working on the UI, screenshots and UI
/// tests, without reading anything of yours. Dates are minutes before `now`.
public static class DemoData
{
    public static IReadOnlyList<SectionSnapshot> Snapshots(DateTimeOffset now) =>
    [
        TeamsChats(now: now),
        TeamsGroupChats(now: now),
        AzureDevOpsPullRequests(now: now),
        CopilotSessions(now: now),
        GitHubPullRequests(now: now),
    ];

    public static SectionSnapshot TeamsChats(DateTimeOffset now) => new(
        Info: Sections.TeamsChats,
        Status: SectionStatus.Live,
        Groups: [new RowGroup(Key: "unread", Title: "Unread", State: ItemState.NeedsYou)],
        Rows:
        [
            new ItemRow
            {
                Id = "priya", Section = SectionId.TeamsChats, Group = "unread", State = ItemState.NeedsYou,
                Icon = IconKey.Person, Initials = "PS", Title = "Priya Shah",
                Status = "Can you look at the release notes before 5?", StatusTone = StatusTone.Quote,
                Date = Ago(now: now, minutes: 14), Unread = 1,
            },
        ],
        BriefLines:
        [
            Line(id: "priya", section: SectionId.TeamsChats, state: ItemState.NeedsYou, now: now, minutes: 14,
                sentence: "Priya Shah: Can you look at the release notes before 5?"),
        ]);

    public static SectionSnapshot TeamsGroupChats(DateTimeOffset now) => new(
        Info: Sections.TeamsGroupChats,
        Status: SectionStatus.Live,
        Groups: [new RowGroup(Key: "unread", Title: "Unread", State: ItemState.NeedsYou)],
        Rows:
        [
            new ItemRow
            {
                Id = "launch-crew", Section = SectionId.TeamsGroupChats, Group = "unread", State = ItemState.NeedsYou,
                Icon = IconKey.People, Initials = "LC", Title = "Launch crew & Design",
                Status = "Jordan Lee: Shipping at 5 unless someone objects.", StatusTone = StatusTone.Quote,
                Date = Ago(now: now, minutes: 5), Unread = 3,
            },
        ],
        BriefLines:
        [
            Line(id: "launch-crew", section: SectionId.TeamsGroupChats, state: ItemState.NeedsYou, now: now, minutes: 5,
                sentence: "Launch crew & Design: shipping at 5 unless someone objects."),
        ]);

    public static SectionSnapshot AzureDevOpsPullRequests(DateTimeOffset now) => new(
        Info: Sections.AzureDevOpsPullRequests,
        Status: SectionStatus.Updated(time: now.AddSeconds(seconds: -20)),
        Groups:
        [
            new RowGroup(Key: "needsYou", Title: "Needs you", State: ItemState.NeedsYou),
            new RowGroup(Key: "failing", Title: "Failing", State: ItemState.Failing),
            new RowGroup(Key: "ready", Title: "Ready to complete", State: ItemState.Done),
        ],
        Rows:
        [
            new ItemRow
            {
                Id = "checkout", Section = SectionId.AzureDevOpsPullRequests, Group = "needsYou", State = ItemState.NeedsYou,
                Icon = IconKey.Send, Title = "Speed up the checkout page",
                Status = "Dana Whitfield sent this in Teams · shop-web", Detail = "By Jordan Lee",
                Date = Ago(now: now, minutes: 8), IsNew = true,
            },
            new ItemRow
            {
                Id = "retry", Section = SectionId.AzureDevOpsPullRequests, Group = "needsYou", State = ItemState.NeedsYou,
                Icon = IconKey.ArrowReply, Title = "Add retry with backoff to the payments client",
                Status = "Sam Rivera replied · payments-api",
                Detail = "Could we cap the backoff at 30 seconds? Otherwise a slow dependency can stall checkout for minutes.",
                Date = Ago(now: now, minutes: 12), Chips = [new RowChip(Kind: RowChipKind.WorkItem, Text: "5160")],
            },
            new ItemRow
            {
                Id = "delivery", Section = SectionId.AzureDevOpsPullRequests, Group = "failing", State = ItemState.Failing,
                Icon = IconKey.Dismiss, Title = "Show delivery estimates on the product page",
                Status = "Failed at Run unit tests · shop-web", Detail = "3 tests failed in DeliveryEstimateTests",
                Date = Ago(now: now, minutes: 18),
            },
            new ItemRow
            {
                Id = "coupon", Section = SectionId.AzureDevOpsPullRequests, Group = "ready", State = ItemState.Done,
                Icon = IconKey.Checkmark, Title = "Fix the coupon rounding error",
                Status = "Approved and ready to complete · shop-web", Date = Ago(now: now, minutes: 6),
            },
        ],
        BriefLines:
        [
            Line(id: "checkout", section: SectionId.AzureDevOpsPullRequests, state: ItemState.NeedsYou, now: now, minutes: 8,
                sentence: "Dana Whitfield sent you “Speed up the checkout page” in Teams."),
            Line(id: "retry", section: SectionId.AzureDevOpsPullRequests, state: ItemState.NeedsYou, now: now, minutes: 12,
                sentence: "Sam Rivera replied on “Add retry with backoff to the payments client”."),
            Line(id: "delivery", section: SectionId.AzureDevOpsPullRequests, state: ItemState.Failing, now: now, minutes: 18,
                sentence: "“Show delivery estimates on the product page” failed at Run unit tests."),
            Line(id: "coupon", section: SectionId.AzureDevOpsPullRequests, state: ItemState.Done, now: now, minutes: 6,
                sentence: "“Fix the coupon rounding error” is approved and ready to complete."),
        ]);

    public static SectionSnapshot CopilotSessions(DateTimeOffset now) => new(
        Info: Sections.CopilotSessions,
        Status: SectionStatus.Live,
        Groups:
        [
            new RowGroup(Key: "needsYou", Title: "Needs you", State: ItemState.NeedsYou),
            new RowGroup(Key: "running", Title: "Running", State: ItemState.Running),
            new RowGroup(Key: "done", Title: "Done", State: ItemState.Done),
            new RowGroup(Key: "stopped", Title: "Stopped", State: ItemState.Failing),
        ],
        Rows:
        [
            new ItemRow
            {
                Id = "release", Section = SectionId.CopilotSessions, Group = "needsYou", State = ItemState.NeedsYou,
                Icon = IconKey.ShieldLock, Title = "Release 2.4.0", Status = "Needs permission · acme-api",
                Detail = "git push origin main --follow-tags", Date = Ago(now: now, minutes: 1),
            },
            new ItemRow
            {
                Id = "oauth", Section = SectionId.CopilotSessions, Group = "needsYou", State = ItemState.NeedsYou,
                Icon = IconKey.ClipboardTaskList, Title = "Move sign-in to OAuth 2.1", Status = "Plan ready for review · acme-api",
                Detail = "Replace cookie sessions with OAuth 2.1 and PKCE.", Date = Ago(now: now, minutes: 2),
            },
            new ItemRow
            {
                Id = "dark-mode", Section = SectionId.CopilotSessions, Group = "needsYou", State = ItemState.NeedsYou,
                Icon = IconKey.ChatQuestion, Title = "Add dark mode to settings", Status = "Waiting for your answer · shop-web",
                Detail = "Should dark mode follow the system appearance?", Date = Ago(now: now, minutes: 4),
                Chips = [new RowChip(Kind: RowChipKind.WorkItem, Text: "5170"), new RowChip(Kind: RowChipKind.PullRequest, Text: "!4093")],
            },
            new ItemRow
            {
                Id = "payments-sdk", Section = SectionId.CopilotSessions, Group = "running", State = ItemState.Running,
                Icon = IconKey.ArrowSync, Title = "Migrate payments to the new SDK", Status = "Running · payments-api",
                Detail = "Updating 14 call sites in PaymentsClient", Date = Ago(now: now, minutes: 3),
            },
            new ItemRow
            {
                Id = "screenshots", Section = SectionId.CopilotSessions, Group = "running", State = ItemState.Running,
                Icon = IconKey.ArrowSync, Title = "Update the README screenshots", Status = "Running · docs-site",
                Detail = "Capturing dark mode", Date = Ago(now: now, minutes: 6),
            },
            new ItemRow
            {
                Id = "sync-retry", Section = SectionId.CopilotSessions, Group = "done", State = ItemState.Done,
                Icon = IconKey.Checkmark, Title = "Add retry to sync", Status = "Done · opened !4107",
                Detail = "Its checks pass.", Date = Ago(now: now, minutes: 9),
            },
            new ItemRow
            {
                Id = "flaky-login", Section = SectionId.CopilotSessions, Group = "stopped", State = ItemState.Failing,
                Icon = IconKey.Warning, Title = "Fix the flaky login test", Status = "Stopped · shop-web",
                Detail = "Not responding for 10 minutes", Date = Ago(now: now, minutes: 31),
            },
        ],
        BriefLines:
        [
            Line(id: "release", section: SectionId.CopilotSessions, state: ItemState.NeedsYou, now: now, minutes: 1,
                sentence: "“Release 2.4.0” needs your permission to run git push origin main --follow-tags."),
            Line(id: "oauth", section: SectionId.CopilotSessions, state: ItemState.NeedsYou, now: now, minutes: 2,
                sentence: "“Move sign-in to OAuth 2.1” has a plan for you to review."),
            Line(id: "dark-mode", section: SectionId.CopilotSessions, state: ItemState.NeedsYou, now: now, minutes: 4,
                sentence: "“Add dark mode to settings” asks: Should dark mode follow the system appearance?"),
            Line(id: "sync-retry", section: SectionId.CopilotSessions, state: ItemState.Done, now: now, minutes: 9,
                sentence: "“Add retry to sync” is done, and opened !4107."),
            Line(id: "flaky-login", section: SectionId.CopilotSessions, state: ItemState.Failing, now: now, minutes: 31,
                sentence: "“Fix the flaky login test” stopped responding."),
        ]);

    public static SectionSnapshot GitHubPullRequests(DateTimeOffset now) => new(
        Info: Sections.GitHubPullRequests,
        Status: SectionStatus.Updated(time: now.AddSeconds(seconds: -45)),
        Groups:
        [
            new RowGroup(Key: "needsYou", Title: "Needs you", State: ItemState.NeedsYou),
            new RowGroup(Key: "failing", Title: "Failing", State: ItemState.Failing),
            new RowGroup(Key: "ready", Title: "Ready to merge", State: ItemState.Done),
        ],
        Rows:
        [
            new ItemRow
            {
                Id = "checkout-dark-mode", Section = SectionId.GitHubPullRequests, Group = "needsYou", State = ItemState.NeedsYou,
                Icon = IconKey.Eye, Title = "Add dark mode to the checkout page", Status = "priya asks for your review · shop-web",
                Detail = "Required reviewer", Date = Ago(now: now, minutes: 20),
            },
            new ItemRow
            {
                Id = "swift-6-2", Section = SectionId.GitHubPullRequests, Group = "failing", State = ItemState.Failing,
                Icon = IconKey.Dismiss, Title = "Upgrade to Swift 6.2", Status = "Checks are failing · ios-app",
                Detail = "build (macos-15) failed after 6 minutes", Date = Ago(now: now, minutes: 25),
            },
            new ItemRow
            {
                Id = "lodash", Section = SectionId.GitHubPullRequests, Group = "ready", State = ItemState.Done,
                Icon = IconKey.Checkmark, Title = "Bump lodash to 4.17.21", Status = "Ready to merge · shop-web",
                Date = Ago(now: now, minutes: 60),
            },
        ],
        BriefLines:
        [
            Line(id: "checkout-dark-mode", section: SectionId.GitHubPullRequests, state: ItemState.NeedsYou, now: now, minutes: 20,
                sentence: "priya asks for your review on “Add dark mode to the checkout page”."),
            Line(id: "swift-6-2", section: SectionId.GitHubPullRequests, state: ItemState.Failing, now: now, minutes: 25,
                sentence: "Checks are failing on “Upgrade to Swift 6.2”."),
            Line(id: "lodash", section: SectionId.GitHubPullRequests, state: ItemState.Done, now: now, minutes: 60,
                sentence: "“Bump lodash to 4.17.21” is ready to merge."),
        ]);

    static DateTimeOffset Ago(DateTimeOffset now, int minutes) => now.AddMinutes(minutes: -minutes);

    static BriefLine Line(string id, SectionId section, ItemState state, DateTimeOffset now, int minutes, string sentence) =>
        new(Id: id, Section: section, State: state, Date: Ago(now: now, minutes: minutes), Sentence: sentence);
}
