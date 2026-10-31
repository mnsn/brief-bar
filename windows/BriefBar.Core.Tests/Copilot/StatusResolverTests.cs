using BriefBar.Core.Copilot;
using static BriefBar.Core.Tests.Copilot.Line;
using static BriefBar.Core.Tests.Copilot.TestTimes;

namespace BriefBar.Core.Tests.Copilot;

public sealed class StatusResolverTests
{
    /// A turn that ended normally at T(3).
    static readonly string[] finishedTurn = [UserMessage(at: T(seconds: 1)), AssistantMessage(at: T(seconds: 2)), TurnEnd(at: T(seconds: 3))];

    public static TheoryData<string, string> Markdown { get; } = new()
    {
        { "**Bold** and `code`", "Bold and code" },
        { "__Underlined__ words", "Underlined words" },
        { "See [the docs](https://example.com/docs) now", "See the docs now" },
        { "![diagram](chart.png) above", "diagram above" },
        { "Cut off [link](https://exam", "Cut off link" },
        { "# Title\n> Quote\n- Item\n2. Step", "Title Quote Item Step" },
        { "  spaced \n\n out\t", "spaced out" },
        { "Plain text", "Plain text" },
    };

    [Fact]
    public void CarriesTheContextUsage()
    {
        var measured = Meta() with { ContextUsage = new ContextUsage(Tokens: 120_000, Limit: 200_000) };
        Assert.Equal(expected: new ContextUsage(Tokens: 120_000, Limit: 200_000), actual: Resolve(lines: finishedTurn, meta: measured, now: T(seconds: 10)).ContextUsage);
        Assert.Null(@object: Resolve(lines: finishedTurn, meta: Meta(), now: T(seconds: 10)).ContextUsage);
    }

    [Fact]
    public void WithoutALogTheAppsFlagsDecide()
    {
        Verify(snapshot: Resolve(lines: null, meta: Meta(running: true, updatedAt: T(seconds: 5)), now: T(seconds: 10)), phase: DisplayPhase.Running, reason: StatusReason.Working, since: T(seconds: 5));
        Verify(snapshot: Resolve(lines: null, meta: Meta(interrupted: true, updatedAt: T(seconds: 5)), now: T(seconds: 10)), phase: DisplayPhase.Stopped, reason: StatusReason.Interrupted, since: T(seconds: 5));
        Verify(snapshot: Resolve(lines: null, meta: Meta(interrupted: true, updatedAt: T(seconds: 5)), now: T(seconds: 3_606)), phase: DisplayPhase.Idle, reason: StatusReason.Interrupted, since: T(seconds: 5));
        Verify(snapshot: Resolve(lines: null, meta: Meta(updatedAt: T(seconds: 5)), now: T(seconds: 10)), phase: DisplayPhase.Idle, reason: StatusReason.Idle, since: T(seconds: 5));
        // A log without a turn in it says nothing either.
        Verify(snapshot: Resolve(lines: [SessionStart(at: T(seconds: 1))], meta: Meta(running: true, updatedAt: T(seconds: 5)), now: T(seconds: 10)), phase: DisplayPhase.Running, reason: StatusReason.Working, since: T(seconds: 5));
    }

    [Fact]
    public void Working()
    {
        string[] lines =
        [
            UserMessage(at: T(seconds: 1)),
            AssistantMessage(at: T(seconds: 2), toolCalls: ["c1"]),
            ToolStart(name: "bash", id: "c1", at: T(seconds: 3), arguments: new() { ["description"] = "Run **unit** tests" }),
        ];
        Verify(snapshot: Resolve(lines: lines, meta: Meta(running: true), now: T(seconds: 30)), phase: DisplayPhase.Running, reason: StatusReason.Working, since: T(seconds: 1), detail: "Run unit tests");
    }

    [Fact]
    public void QuestionsNeedYou()
    {
        string[] lines =
        [
            UserMessage(at: T(seconds: 1)),
            ToolStart(name: "ask_user", id: "q", at: T(seconds: 2), arguments: new() { ["question"] = "Use **Postgres** or `SQLite`?", ["choices"] = new List<string> { "Postgres", "SQLite" } }),
        ];
        var snapshot = Resolve(lines: lines, meta: Meta(running: true), now: T(seconds: 30));
        Verify(snapshot: snapshot, phase: DisplayPhase.NeedsYou, reason: StatusReason.Question, since: T(seconds: 2), detail: "Use Postgres or SQLite?");
        Assert.Equal(expected: ["Postgres", "SQLite"], actual: snapshot.Choices);
    }

    /// With Show relayed questions once, a relay waits for your answer, saying what it says first until it's merged with
    /// the session it relays for (`RelayedQuestionsTests`). Without it, it's work, as the session it relays for needs
    /// you.
    [Fact]
    public void RelayedQuestionsNeedYouOnlyWhenShownOnce()
    {
        string[] Relay(Dictionary<string, object?> arguments) =>
        [
            UserMessage(at: T(seconds: 1)),
            ToolStart(name: "bash", id: "b", at: T(seconds: 2), arguments: new() { ["description"] = "Run the tests" }),
            ToolComplete(id: "b", at: T(seconds: 3)),
            ToolStart(name: "relay_session_input", id: "r", at: T(seconds: 4), arguments: arguments),
        ];
        var once = new ResolverOptions { ShowRelayedQuestionsOnce = true };
        var framed = Relay(arguments: new() { ["project_session_id"] = "w-child", ["context"] = "From the **checkout** session." });
        Verify(snapshot: Resolve(lines: framed, meta: Meta(running: true), now: T(seconds: 30), options: once), phase: DisplayPhase.NeedsYou, reason: StatusReason.Question, since: T(seconds: 4), detail: "From the checkout session.");
        Verify(snapshot: Resolve(lines: Relay(arguments: new() { ["project_session_id"] = "w-child" }), meta: Meta(running: true), now: T(seconds: 30), options: once), phase: DisplayPhase.NeedsYou, reason: StatusReason.Question, since: T(seconds: 4));
        Verify(snapshot: Resolve(lines: framed, meta: Meta(running: true), now: T(seconds: 30)), phase: DisplayPhase.Running, reason: StatusReason.Working, since: T(seconds: 1));

        // Its own plan still needs you, whichever way the setting is.
        string[] planning = [.. framed, ToolStart(name: "exit_plan_mode", id: "p", at: T(seconds: 5), arguments: new() { ["summary"] = "Ship it." })];
        foreach (var options in new[] { new ResolverOptions(), once })
        {
            Verify(snapshot: Resolve(lines: planning, meta: Meta(running: true), now: T(seconds: 30), options: options), phase: DisplayPhase.NeedsYou, reason: StatusReason.PlanApproval, since: T(seconds: 5), detail: "Ship it.");
        }
    }

    [Fact]
    public void PlansNeedYou()
    {
        string[] lines =
        [
            UserMessage(at: T(seconds: 1)),
            ToolStart(name: "exit_plan_mode", id: "p", at: T(seconds: 2), arguments: new() { ["summary"] = "## Plan\n- Add tests\n- Ship it" }),
        ];
        Verify(snapshot: Resolve(lines: lines, meta: Meta(running: true), now: T(seconds: 30)), phase: DisplayPhase.NeedsYou, reason: StatusReason.PlanApproval, since: T(seconds: 2), detail: "Plan Add tests Ship it");
    }

    [Fact]
    public void PermissionsNeedYou()
    {
        (Dictionary<string, object?> Request, string? Detail)[] cases =
        [
            (new() { ["kind"] = "shell", ["fullCommandText"] = "rm -rf build" }, "rm -rf build"),
            (new() { ["kind"] = "url" }, "url"),
            (new(), null),
        ];
        foreach (var (request, detail) in cases)
        {
            string[] lines = [UserMessage(at: T(seconds: 1)), PermissionRequested(id: "r1", request: request, at: T(seconds: 2))];
            Verify(snapshot: Resolve(lines: lines, meta: Meta(running: true), now: T(seconds: 30)), phase: DisplayPhase.NeedsYou, reason: StatusReason.Permission, since: T(seconds: 2), detail: detail);
        }
    }

    [Fact]
    public void EndedSessionsStayHighlightedForAnHour()
    {
        Verify(snapshot: Resolve(lines: finishedTurn, meta: Meta(), now: T(seconds: 3_603)), phase: DisplayPhase.Done, reason: StatusReason.Finished, since: T(seconds: 3));
        Verify(snapshot: Resolve(lines: finishedTurn, meta: Meta(), now: T(seconds: 3_604)), phase: DisplayPhase.Idle, reason: StatusReason.Finished, since: T(seconds: 3));
        var shortWindow = new ResolverOptions { RecentWindow = TimeSpan.FromSeconds(value: 60) };
        Verify(snapshot: Resolve(lines: finishedTurn, meta: Meta(), now: T(seconds: 64), options: shortWindow), phase: DisplayPhase.Idle, reason: StatusReason.Finished, since: T(seconds: 3));
    }

    [Fact]
    public void OnlyClearingThisCompletionDismissesIt()
    {
        Verify(snapshot: Resolve(lines: finishedTurn, meta: Meta(), now: T(seconds: 60), clearedAt: T(seconds: 3)), phase: DisplayPhase.Idle, reason: StatusReason.Finished, since: T(seconds: 3));
        Verify(snapshot: Resolve(lines: finishedTurn, meta: Meta(), now: T(seconds: 60), clearedAt: T(seconds: 2)), phase: DisplayPhase.Done, reason: StatusReason.Finished, since: T(seconds: 3));
    }

    [Fact]
    public void ClearingAnEarlierRunDoesNotHideTheNextCompletion()
    {
        string[] rerun = [.. finishedTurn, UserMessage(at: T(seconds: 10)), AssistantMessage(at: T(seconds: 11)), TurnEnd(at: T(seconds: 12))];
        Verify(snapshot: Resolve(lines: rerun, meta: Meta(), now: T(seconds: 60), clearedAt: T(seconds: 4)), phase: DisplayPhase.Done, reason: StatusReason.Finished, since: T(seconds: 12));
        Verify(snapshot: Resolve(lines: rerun, meta: Meta(), now: T(seconds: 60), clearedAt: T(seconds: 12)), phase: DisplayPhase.Idle, reason: StatusReason.Finished, since: T(seconds: 12));
    }

    [Fact]
    public void StoppedSessionsAlsoRequireExplicitClearingOrExpiry()
    {
        string[] stopped = [UserMessage(at: T(seconds: 1)), SessionError(message: "Failed", at: T(seconds: 3))];
        Verify(snapshot: Resolve(lines: stopped, meta: Meta(), now: T(seconds: 60)), phase: DisplayPhase.Stopped, reason: StatusReason.Failed, since: T(seconds: 3), detail: "Failed");
        Verify(snapshot: Resolve(lines: stopped, meta: Meta(), now: T(seconds: 60), clearedAt: T(seconds: 3)), phase: DisplayPhase.Idle, reason: StatusReason.Failed, since: T(seconds: 3), detail: "Failed");
        Verify(snapshot: Resolve(lines: stopped, meta: Meta(), now: T(seconds: 3_604)), phase: DisplayPhase.Idle, reason: StatusReason.Failed, since: T(seconds: 3), detail: "Failed");
    }

    [Fact]
    public void ViewedCompletionsOnlyMoveToIdleWhenEnabled()
    {
        var autoIdle = new ResolverOptions { MoveViewedToIdle = true };
        Verify(snapshot: Resolve(lines: finishedTurn, meta: Meta(), now: T(seconds: 60), viewedAt: T(seconds: 4)), phase: DisplayPhase.Done, reason: StatusReason.Finished, since: T(seconds: 3));
        Verify(snapshot: Resolve(lines: finishedTurn, meta: Meta(), now: T(seconds: 60), options: autoIdle, viewedAt: T(seconds: 4)), phase: DisplayPhase.Idle, reason: StatusReason.Finished, since: T(seconds: 3));
        Verify(snapshot: Resolve(lines: finishedTurn, meta: Meta(), now: T(seconds: 60), options: autoIdle, viewedAt: T(seconds: 2)), phase: DisplayPhase.Done, reason: StatusReason.Finished, since: T(seconds: 3));
        string[] rerun = [.. finishedTurn, UserMessage(at: T(seconds: 10)), AssistantMessage(at: T(seconds: 11)), TurnEnd(at: T(seconds: 12))];
        Verify(snapshot: Resolve(lines: rerun, meta: Meta(), now: T(seconds: 60), options: autoIdle, viewedAt: T(seconds: 4)), phase: DisplayPhase.Done, reason: StatusReason.Finished, since: T(seconds: 12));
        string[] stopped = [UserMessage(at: T(seconds: 1)), SessionError(message: "Failed", at: T(seconds: 3))];
        Verify(snapshot: Resolve(lines: stopped, meta: Meta(), now: T(seconds: 60), viewedAt: T(seconds: 4)), phase: DisplayPhase.Stopped, reason: StatusReason.Failed, since: T(seconds: 3), detail: "Failed");
        Verify(snapshot: Resolve(lines: stopped, meta: Meta(), now: T(seconds: 60), options: autoIdle, viewedAt: T(seconds: 4)), phase: DisplayPhase.Idle, reason: StatusReason.Failed, since: T(seconds: 3), detail: "Failed");
    }

    [Fact]
    public void TheAppsUnreadMarkersOnlyDismissWhenEnabled()
    {
        DisplayPhase Phase(SessionMeta session, IReadOnlySet<string>? unread, DateTimeOffset? updatedAt, bool enabled = true) =>
            Resolve(
                lines: finishedTurn, meta: session, now: T(seconds: 60), options: new ResolverOptions { MoveViewedToIdle = enabled },
                view: new AppViewState { UnreadWorkspaceIds = unread, UnreadUpdatedAt = updatedAt }).Phase;
        Assert.Equal(expected: DisplayPhase.Done, actual: Phase(session: Meta(), unread: new HashSet<string>(), updatedAt: T(seconds: 10), enabled: false));
        Assert.Equal(expected: DisplayPhase.Idle, actual: Phase(session: Meta(), unread: new HashSet<string>(), updatedAt: T(seconds: 10)));
        Assert.Equal(expected: DisplayPhase.Idle, actual: Phase(session: Meta(), unread: new HashSet<string> { "w9" }, updatedAt: T(seconds: 10)));
        Assert.Equal(expected: DisplayPhase.Done, actual: Phase(session: Meta(), unread: new HashSet<string> { "w1" }, updatedAt: T(seconds: 10)));
        Assert.Equal(expected: DisplayPhase.Done, actual: Phase(session: Meta(), unread: new HashSet<string>(), updatedAt: T(seconds: 2)));
        Assert.Equal(expected: DisplayPhase.Done, actual: Phase(session: Meta(), unread: null, updatedAt: T(seconds: 10)));
        Assert.Equal(expected: DisplayPhase.Done, actual: Phase(session: Meta(type: "general_chat", workspaceId: null), unread: new HashSet<string>(), updatedAt: T(seconds: 10)));
    }

    [Fact]
    public void ARunningLogTheAppNoLongerRunsGoesStale()
    {
        string[] lines = [UserMessage(at: T(seconds: 1)), AssistantMessage(at: T(seconds: 2), toolCalls: ["c1"]), ToolStart(name: "bash", id: "c1", at: T(seconds: 3))];
        Verify(snapshot: Resolve(lines: lines, meta: Meta(), now: T(seconds: 93)), phase: DisplayPhase.Running, reason: StatusReason.Working, since: T(seconds: 1));
        Verify(snapshot: Resolve(lines: lines, meta: Meta(), now: T(seconds: 94)), phase: DisplayPhase.Stopped, reason: StatusReason.Unresponsive, since: T(seconds: 3));
        Verify(snapshot: Resolve(lines: lines, meta: Meta(interrupted: true), now: T(seconds: 94)), phase: DisplayPhase.Stopped, reason: StatusReason.Interrupted, since: T(seconds: 3));
        Verify(snapshot: Resolve(lines: lines, meta: Meta(), now: T(seconds: 3_604)), phase: DisplayPhase.Idle, reason: StatusReason.Unresponsive, since: T(seconds: 3));
        // While the app still says it's running, silence alone means nothing.
        Verify(snapshot: Resolve(lines: lines, meta: Meta(running: true), now: T(seconds: 10_000)), phase: DisplayPhase.Running, reason: StatusReason.Working, since: T(seconds: 1));
    }

    /// The fallback query and the folder scan can't tell whether the app is running a session.
    [Fact]
    public void AnUnknownRunningFlagLeavesItToTheLog()
    {
        string[] asking = [UserMessage(at: T(seconds: 1)), ToolStart(name: "ask_user", id: "q", at: T(seconds: 2), arguments: new() { ["question"] = "Ship it?" })];
        // A question can wait for hours; only a flag known to be off means the CLI is gone.
        Verify(snapshot: Resolve(lines: asking, meta: Meta(running: null), now: T(seconds: 10_000)), phase: DisplayPhase.NeedsYou, reason: StatusReason.Question, since: T(seconds: 2), detail: "Ship it?");
        Verify(snapshot: Resolve(lines: asking, meta: Meta(running: false), now: T(seconds: 10_000)), phase: DisplayPhase.Idle, reason: StatusReason.Unresponsive, since: T(seconds: 2));
        string[] working = [UserMessage(at: T(seconds: 1)), ToolStart(name: "bash", id: "c1", at: T(seconds: 2))];
        Verify(snapshot: Resolve(lines: working, meta: Meta(running: null), now: T(seconds: 10_000)), phase: DisplayPhase.Running, reason: StatusReason.Working, since: T(seconds: 1));
        // Nor does it start a new turn or stand in for a missing log.
        Verify(snapshot: Resolve(lines: finishedTurn, meta: Meta(running: null, updatedAt: T(seconds: 10)), now: T(seconds: 20)), phase: DisplayPhase.Done, reason: StatusReason.Finished, since: T(seconds: 3));
        Verify(snapshot: Resolve(lines: null, meta: Meta(running: null, updatedAt: T(seconds: 5)), now: T(seconds: 10)), phase: DisplayPhase.Idle, reason: StatusReason.Idle, since: T(seconds: 5));
    }

    [Fact]
    public void ANewTurnTheLogHasNotCaughtUpWithIsStarting()
    {
        Verify(snapshot: Resolve(lines: finishedTurn, meta: Meta(running: true, updatedAt: T(seconds: 10)), now: T(seconds: 20)), phase: DisplayPhase.Running, reason: StatusReason.Starting, since: T(seconds: 10));
        // The grace period is over.
        Verify(snapshot: Resolve(lines: finishedTurn, meta: Meta(running: true, updatedAt: T(seconds: 10)), now: T(seconds: 130)), phase: DisplayPhase.Done, reason: StatusReason.Finished, since: T(seconds: 3));
        // The app's time belongs to the turn the log already shows.
        Verify(snapshot: Resolve(lines: finishedTurn, meta: Meta(running: true, updatedAt: T(seconds: 4)), now: T(seconds: 20)), phase: DisplayPhase.Done, reason: StatusReason.Finished, since: T(seconds: 3));
    }

    [Fact]
    public void EndedTurnsShowTheAppsLastMessage()
    {
        string? Detail(string[] lines, ActivityPreview activity) => Resolve(lines: lines, meta: Meta(activity: activity), now: T(seconds: 60)).Detail;
        ActivityPreview Idle(string text, DateTimeOffset? at) => new(Kind: "agent_idle", Text: text, At: at);
        Assert.Equal(expected: "I fixed the login bug", actual: Detail(lines: finishedTurn, activity: Idle(text: "I fixed the **login** bug", at: T(seconds: 4))));
        Assert.Equal(expected: "Undated", actual: Detail(lines: finishedTurn, activity: Idle(text: "Undated", at: null)));
        Assert.Equal(expected: "Just in time", actual: Detail(lines: finishedTurn, activity: Idle(text: "Just in time", at: T(seconds: -27))));
        // From an earlier turn, about something else, or empty.
        Assert.Null(@object: Detail(lines: finishedTurn, activity: Idle(text: "Too old", at: T(seconds: -28))));
        Assert.Null(@object: Detail(lines: finishedTurn, activity: new ActivityPreview(Kind: "agent_asking", Text: "A question", At: T(seconds: 4))));
        Assert.Null(@object: Detail(lines: finishedTurn, activity: Idle(text: "", at: T(seconds: 4))));

        // The CLI's own summary wins.
        string[] completed = [UserMessage(at: T(seconds: 1)), TaskComplete(summary: "Shipped **it**", at: T(seconds: 2))];
        Assert.Equal(expected: "Shipped it", actual: Detail(lines: completed, activity: Idle(text: "Preview", at: T(seconds: 2))));
    }

    [Fact]
    public void FailuresAndInterruptions()
    {
        string[] failed = [UserMessage(at: T(seconds: 1)), SessionError(message: "Rate limit exceeded", at: T(seconds: 2))];
        Verify(snapshot: Resolve(lines: failed, meta: Meta(), now: T(seconds: 60)), phase: DisplayPhase.Stopped, reason: StatusReason.Failed, since: T(seconds: 2), detail: "Rate limit exceeded");

        string[] failedQuietly = [UserMessage(at: T(seconds: 1)), Event(type: "session.error", at: T(seconds: 2), data: new() { ["errorType"] = "query" })];
        var errorPreview = new ActivityPreview(Kind: "agent_error", Text: "Something broke", At: T(seconds: 2));
        Verify(snapshot: Resolve(lines: failedQuietly, meta: Meta(activity: errorPreview), now: T(seconds: 60)), phase: DisplayPhase.Stopped, reason: StatusReason.Failed, since: T(seconds: 2), detail: "Something broke");

        string[] aborted = [UserMessage(at: T(seconds: 1)), Abort(at: T(seconds: 2))];
        var idlePreview = new ActivityPreview(Kind: "agent_idle", Text: "Earlier reply", At: T(seconds: 2));
        Verify(snapshot: Resolve(lines: aborted, meta: Meta(activity: idlePreview), now: T(seconds: 60)), phase: DisplayPhase.Stopped, reason: StatusReason.Interrupted, since: T(seconds: 2));
    }

    [Fact]
    public void NamesAndContextPassThrough()
    {
        var snapshot = Resolve(lines: null, meta: Meta(name: "  Fix   the\nlogin  "), now: T(seconds: 10));
        Assert.Equal(expected: "Fix the login", actual: snapshot.Name);
        Assert.Equal(expected: "Fix the login", actual: snapshot.DisplayName);
        Assert.Equal(expected: "s1", actual: snapshot.Id);
        Assert.Equal(expected: "acme-web", actual: snapshot.ProjectName);
        Assert.Equal(expected: "fix-login", actual: snapshot.Branch);
        Assert.Equal(expected: "interactive", actual: snapshot.Mode);
        Assert.False(condition: snapshot.IsChat);

        Assert.Equal(expected: "Untitled session", actual: Resolve(lines: null, meta: Meta(name: " "), now: T(seconds: 10)).DisplayName);
        var chat = Resolve(lines: null, meta: Meta(name: "", type: "general_chat", workspaceId: null), now: T(seconds: 10));
        Assert.True(condition: chat.IsChat);
        Assert.Equal(expected: "Untitled chat", actual: chat.DisplayName);
    }

    [Theory]
    [MemberData(memberName: nameof(Markdown))]
    public void FlattensMarkdown(string markdown, string expected) => Assert.Equal(expected: expected, actual: PlainText.FromMarkdown(markdown: markdown));

    [Fact]
    public void OrderingPutsWhatNeedsYouFirst()
    {
        SessionSnapshot[] snapshots =
        [
            Item(id: "idle-undated", phase: DisplayPhase.Idle, since: null),
            Item(id: "running-old", phase: DisplayPhase.Running, since: T(seconds: 1)),
            Item(id: "asking-new", phase: DisplayPhase.NeedsYou, since: T(seconds: 10)),
            Item(id: "done", phase: DisplayPhase.Done, since: T(seconds: 3)),
            Item(id: "idle", phase: DisplayPhase.Idle, since: T(seconds: 50)),
            Item(id: "running-new", phase: DisplayPhase.Running, since: T(seconds: 20)),
            Item(id: "asking-old", phase: DisplayPhase.NeedsYou, since: T(seconds: 5)),
            Item(id: "stopped", phase: DisplayPhase.Stopped, since: T(seconds: 4)),
            Item(id: "tie-10", phase: DisplayPhase.Done, since: T(seconds: 2), name: "Session 10"),
            Item(id: "tie-2", phase: DisplayPhase.Done, since: T(seconds: 2), name: "Session 2"),
            Item(id: "same-b", phase: DisplayPhase.Done, since: T(seconds: 1), name: "Same"),
            Item(id: "same-a", phase: DisplayPhase.Done, since: T(seconds: 1), name: "Same"),
        ];
        var shuffled = snapshots.OrderBy(keySelector: _ => Random.Shared.Next()).ToList();
        Assert.Equal(
            expected: ["asking-old", "asking-new", "running-new", "running-old", "done", "tie-2", "tie-10", "same-a", "same-b", "stopped", "idle", "idle-undated"],
            actual: SessionOrdering.Sorted(snapshots: shuffled).Select(selector: snapshot => snapshot.Id));
    }

    [Fact]
    public void CountsPhases()
    {
        DisplayPhase[] phases = [DisplayPhase.NeedsYou, DisplayPhase.NeedsYou, DisplayPhase.Running, DisplayPhase.Done, DisplayPhase.Stopped, DisplayPhase.Idle, DisplayPhase.Idle, DisplayPhase.Idle];
        var counts = new PhaseCounts(snapshots: phases.Select(selector: (phase, index) => Item(id: index.ToString(provider: System.Globalization.CultureInfo.InvariantCulture), phase: phase, since: null)));
        Assert.Equal(expected: [2, 1, 1, 1, 3], actual: DisplayPhases.All.Select(selector: phase => counts[phase]));
        Assert.Equal(expected: 5, actual: counts.Active);
        // By state, the same for every source: a session that stopped is something wrong, and idle ones aren't counted.
        Assert.Equal(expected: [ItemState.NeedsYou, ItemState.Running, ItemState.Done, ItemState.Failing, null], actual: DisplayPhases.All.Select(selector: phase => phase.State()));
        Assert.Equal(expected: new StateCounts(NeedsYou: 2, Failing: 1, Running: 1, Done: 1), actual: counts.States);

        var edited = new PhaseCounts();
        edited[DisplayPhase.Done] += 2;
        Assert.Equal(expected: 2, actual: edited.Done);
        Assert.Equal(expected: 2, actual: edited.Active);
    }

    [Fact]
    public void SaysInTheBriefWhatASessionWaitsForOrHowItEnded()
    {
        string Sentence(StatusReason reason, string? detail = null, string name = "Add dark mode") =>
            (Item(id: "s", phase: DisplayPhase.NeedsYou, since: null, name: name, reason: reason) with { Detail = detail }).BriefSentence;
        Assert.Equal(expected: "“Add dark mode” asks: Should it follow the system?", actual: Sentence(reason: StatusReason.Question, detail: "Should it follow the system?"));
        Assert.Equal(expected: "“Add dark mode” is waiting for your answer.", actual: Sentence(reason: StatusReason.Question));
        Assert.Equal(expected: "“Add dark mode” has a plan for you to review: Replace cookies with OAuth.", actual: Sentence(reason: StatusReason.PlanApproval, detail: "Replace cookies with OAuth."));
        Assert.Equal(expected: "“Add dark mode” needs your permission to run git push origin main.", actual: Sentence(reason: StatusReason.Permission, detail: "git push origin main"));
        Assert.Equal(expected: "“Add dark mode” finished.", actual: Sentence(reason: StatusReason.Finished));
        Assert.Equal(expected: "“Add dark mode” was interrupted.", actual: Sentence(reason: StatusReason.Interrupted));
        Assert.Equal(expected: "“Add dark mode” stopped with an error: Lost the connection. Try again.", actual: Sentence(reason: StatusReason.Failed, detail: "Lost the connection.\nTry again."));
        Assert.Equal(expected: "“Untitled session” stopped responding.", actual: Sentence(reason: StatusReason.Unresponsive, name: ""));
        var relayed = Item(id: "s", phase: DisplayPhase.Running, since: null, name: "Add dark mode", reason: StatusReason.Relayed);
        Assert.Equal(expected: "“Add dark mode” waits for your answer in another session.", actual: relayed.BriefSentence);
        Assert.Equal(expected: "“Add dark mode” waits for your answer in “Release 2.5”.", actual: (relayed with { AnswerIn = new RelatedSession(Id: "p", Name: "Release 2.5") }).BriefSentence);
        var longOne = Sentence(reason: StatusReason.Question, detail: string.Concat(values: Enumerable.Repeat(element: "Is it this? ", count: 30)));
        Assert.EndsWith(expectedEndString: "…", actualString: longOne, comparisonType: StringComparison.Ordinal);
        Assert.True(condition: longOne.Length < 180);
    }

    [Fact]
    public void PhasesSortByUrgency()
    {
        Assert.Equal(
            expected: [DisplayPhase.NeedsYou, DisplayPhase.Running, DisplayPhase.Done, DisplayPhase.Stopped, DisplayPhase.Idle],
            actual: DisplayPhases.All.OrderBy(keySelector: _ => Random.Shared.Next()).Order());
        Assert.Equal(
            expected: [StatusReason.Finished, StatusReason.Interrupted, StatusReason.Failed, StatusReason.Unresponsive],
            actual: Enum.GetValues<StatusReason>().Where(predicate: reason => Item(id: "s", phase: DisplayPhase.Idle, since: null, reason: reason).IsEnded));
    }

    /// A session the app doesn't list, such as a task BriefBar sent to the Copilot CLI: what follows it says how it
    /// stands, and it's highlighted as long as the app's are.
    [Fact]
    public void SessionsTheAppDoesNotListShowLikeItsOwn()
    {
        SessionSnapshot Unlisted(StatusReason reason, string? detail = null, double? since = 3, double now = 60, bool isSeen = false) =>
            StatusResolver.Snapshot(
                unlistedId: "task", name: " Fix Comments:\n!4071  Fix totals ", place: "shop-web", reason: reason, detail: detail,
                since: since is { } seconds ? T(seconds: seconds) : null, now: T(seconds: now), isSeen: isSeen);
        var working = Unlisted(reason: StatusReason.Working, detail: "Run the **cart** tests");
        Verify(snapshot: working, phase: DisplayPhase.Running, reason: StatusReason.Working, since: T(seconds: 3), detail: "Run the cart tests");
        Assert.Equal(expected: "Fix Comments: !4071 Fix totals", actual: working.Name);
        Assert.Equal(expected: "shop-web", actual: working.ProjectName);
        Assert.Null(@object: working.Branch);
        Assert.False(condition: working.IsChat);
        Verify(snapshot: Unlisted(reason: StatusReason.Starting), phase: DisplayPhase.Running, reason: StatusReason.Starting, since: T(seconds: 3));

        Verify(snapshot: Unlisted(reason: StatusReason.Finished, detail: "Changes ready:\n- fixed it"), phase: DisplayPhase.Done, reason: StatusReason.Finished, since: T(seconds: 3), detail: "Changes ready: fixed it");
        Verify(snapshot: Unlisted(reason: StatusReason.Failed, detail: "git failed"), phase: DisplayPhase.Stopped, reason: StatusReason.Failed, since: T(seconds: 3), detail: "git failed");
        Verify(snapshot: Unlisted(reason: StatusReason.Interrupted), phase: DisplayPhase.Stopped, reason: StatusReason.Interrupted, since: T(seconds: 3));
        // Seen, or ended over an hour ago: idle, as it ended.
        Verify(snapshot: Unlisted(reason: StatusReason.Finished, isSeen: true), phase: DisplayPhase.Idle, reason: StatusReason.Finished, since: T(seconds: 3));
        Verify(snapshot: Unlisted(reason: StatusReason.Finished, now: 3_604), phase: DisplayPhase.Idle, reason: StatusReason.Finished, since: T(seconds: 3));
        Verify(snapshot: Unlisted(reason: StatusReason.Failed, since: null), phase: DisplayPhase.Idle, reason: StatusReason.Failed, since: null);
        Verify(snapshot: Unlisted(reason: StatusReason.Finished, detail: "  "), phase: DisplayPhase.Done, reason: StatusReason.Finished, since: T(seconds: 3));
    }

    static SessionMeta Meta(
        string name = "Fix login", string type = "project", bool? running = false, bool interrupted = false, DateTimeOffset? updatedAt = null,
        string? workspaceId = "w1", ActivityPreview? activity = null) => new()
        {
            Id = "s1",
            Name = name,
            SessionType = type,
            Mode = "interactive",
            IsRunning = running,
            WasInterrupted = interrupted,
            UpdatedAt = updatedAt ?? T(seconds: 0),
            ProjectName = "acme-web",
            Branch = "fix-login",
            WorkspaceId = workspaceId,
            LastActivity = activity,
        };

    static SessionSnapshot Resolve(
        string[]? lines, SessionMeta meta, DateTimeOffset now, ResolverOptions? options = null, AppViewState? view = null,
        DateTimeOffset? clearedAt = null, DateTimeOffset? viewedAt = null) =>
        StatusResolver.Snapshot(
            record: new SessionRecord(Meta: meta, Log: lines is null ? null : LogState(lines: lines)),
            now: now, options: options, view: view, clearedAt: clearedAt, viewedAt: viewedAt);

    static SessionSnapshot Item(string id, DisplayPhase phase, DateTimeOffset? since, string name = "", StatusReason reason = StatusReason.Idle) => new()
    {
        Id = id,
        Name = name,
        Phase = phase,
        Reason = reason,
        Headline = reason.Headline(),
        Since = since,
    };

    static void Verify(SessionSnapshot snapshot, DisplayPhase phase, StatusReason reason, DateTimeOffset? since, string? detail = null)
    {
        Assert.Equal(expected: phase, actual: snapshot.Phase);
        Assert.Equal(expected: reason, actual: snapshot.Reason);
        Assert.Equal(expected: reason.Headline(), actual: snapshot.Headline);
        Assert.Equal(expected: since, actual: snapshot.Since);
        Assert.Equal(expected: detail, actual: snapshot.Detail);
    }
}
