namespace BriefBar;

/// BriefBar's four states, the same for every source.
internal enum State { NeedsYou, Failing, Running, Done }

internal enum Source { Chats, GroupChats, AzureDevOps, Copilot, GitHub }

/// One thing in a source's list, such as a pull request or a Copilot session.
internal sealed record Item(Source Source, State State, IconData Icon, string Title, string Status, string? Detail, string Age, int Unread = 0);

/// A sentence of the brief.
internal sealed record BriefLine(Source Source, State State, string Text);

/// Made-up data, in the spirit of BriefBar's demo mode on the Mac.
internal static class Demo
{
    /// The items on the right of the bar, left to right, as BriefBar's menu-bar items.
    public static readonly Source[] BarOrder = [Source.Chats, Source.GroupChats, Source.AzureDevOps, Source.Copilot, Source.GitHub];

    public static readonly Item[] Items =
    [
        new(Source.Copilot, State.NeedsYou, Icons.ShieldLock, "Release 2.4.0", "Needs permission · acme-api",
            "git push origin main --follow-tags", "1m"),
        new(Source.Copilot, State.NeedsYou, Icons.ClipboardTaskList, "Move sign-in to OAuth 2.1", "Plan ready for review · acme-api",
            "Replace cookie sessions with OAuth 2.1 and PKCE.", "2m"),
        new(Source.Copilot, State.NeedsYou, Icons.ChatQuestion, "Add dark mode to settings", "Waiting for your answer · shop-web",
            "Should dark mode follow the system appearance?", "4m"),
        new(Source.GroupChats, State.NeedsYou, Icons.People, "Launch crew & Design", "Jordan Lee: Shipping at 5 unless someone objects.",
            null, "5m", Unread: 3),
        new(Source.AzureDevOps, State.NeedsYou, Icons.Send, "Speed up the checkout page", "Dana Whitfield sent this in Teams · shop-web",
            "By Jordan Lee", "8m"),
        new(Source.AzureDevOps, State.NeedsYou, Icons.ArrowReply, "Add retry with backoff to the payments client", "Sam Rivera replied · payments-api",
            "Could we cap the backoff at 30 seconds? Otherwise a slow dependency can stall checkout for minutes.", "12m"),
        new(Source.Chats, State.NeedsYou, Icons.Person, "Priya Shah", "Can you look at the release notes before 5?",
            null, "14m", Unread: 1),
        new(Source.GitHub, State.NeedsYou, Icons.Eye, "Add dark mode to the checkout page", "priya asks for your review · shop-web",
            "Required reviewer", "20m"),

        new(Source.AzureDevOps, State.Failing, Icons.Dismiss, "Show delivery estimates on the product page", "Failed at Run unit tests · shop-web",
            "3 tests failed in DeliveryEstimateTests", "18m"),
        new(Source.GitHub, State.Failing, Icons.Dismiss, "Upgrade to Swift 6.2", "Checks are failing · ios-app",
            "build (macos-15) failed after 6 minutes", "25m"),
        new(Source.Copilot, State.Failing, Icons.Warning, "Fix the flaky login test", "Stopped · shop-web",
            "Not responding for 10 minutes", "31m"),

        new(Source.Copilot, State.Running, Icons.ArrowSync, "Migrate payments to the new SDK", "Running · payments-api",
            "Updating 14 call sites in PaymentsClient", "3m"),
        new(Source.Copilot, State.Running, Icons.ArrowSync, "Update the README screenshots", "Running · brief-bar",
            "Capturing dark mode", "6m"),

        new(Source.AzureDevOps, State.Done, Icons.Checkmark, "Fix the coupon rounding error", "Approved and ready to complete · shop-web",
            null, "6m"),
        new(Source.Copilot, State.Done, Icons.Checkmark, "Add retry to sync", "Done · opened !4107",
            "Its checks pass.", "9m"),
        new(Source.GitHub, State.Done, Icons.Checkmark, "Bump lodash to 4.17.21", "Ready to merge · shop-web",
            null, "1h"),
    ];

    public static readonly BriefLine[] Brief =
    [
        new(Source.Copilot, State.NeedsYou, "“Release 2.4.0” needs your permission to run git push origin main --follow-tags."),
        new(Source.GroupChats, State.NeedsYou, "Launch crew & Design: shipping at 5 unless someone objects."),
        new(Source.AzureDevOps, State.NeedsYou, "Dana Whitfield sent you “Speed up the checkout page” in Teams."),
        new(Source.GitHub, State.Failing, "Checks are failing on “Upgrade to Swift 6.2”."),
        new(Source.AzureDevOps, State.Done, "“Fix the coupon rounding error” is approved and ready to complete."),
    ];

    public static int Count(State state, Source? source = null) =>
        Items.Count(item => item.State == state && (source is null || item.Source == source));
}
