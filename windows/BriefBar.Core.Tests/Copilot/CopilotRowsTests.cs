using BriefBar.Core.Copilot;
using BriefBar.Core.Demo;
using BriefBar.Core.Presentation;
using BriefBar.Core.Settings;
using static BriefBar.Core.Tests.Copilot.TestTimes;

namespace BriefBar.Core.Tests.Copilot;

public sealed class CopilotRowsTests
{
    [Fact]
    public void ShowsEachReasonWithItsIconAndAnIdleOneQuietly()
    {
        Assert.Equal(expected: Enum.GetValues<StatusReason>().Length, actual: Enum.GetValues<StatusReason>().Select(selector: CopilotRows.Icon).Distinct().Count());
        var waiting = CopilotRows.Row(session: Session(phase: DisplayPhase.NeedsYou, reason: StatusReason.Question), canOpen: true, showContextUsage: false);
        Assert.Equal(expected: IconKey.ChatQuestion, actual: waiting.Icon);
        Assert.Equal(expected: ItemState.NeedsYou, actual: waiting.State);
        Assert.Equal(expected: "needsYou", actual: waiting.Group);

        // An idle session keeps the icon it ended with, without a state, so its badge is quiet.
        var idle = CopilotRows.Row(session: Session(phase: DisplayPhase.Idle, reason: StatusReason.Finished), canOpen: true, showContextUsage: false);
        Assert.Equal(expected: IconKey.Checkmark, actual: idle.Icon);
        Assert.Null(@object: idle.State);
        Assert.Equal(expected: "idle", actual: idle.Group);
    }

    [Fact]
    public void SaysWhereASessionStandsAndWhereItWorks()
    {
        Assert.Equal(expected: "Waiting for your answer · shop-web", actual: CopilotRows.Subtitle(session: Session(phase: DisplayPhase.NeedsYou, reason: StatusReason.Question)));
        Assert.Equal(expected: "Working · Chat", actual: CopilotRows.Subtitle(session: Session(phase: DisplayPhase.Running, reason: StatusReason.Working, project: null, isChat: true)));
        Assert.Equal(expected: "Working", actual: CopilotRows.Subtitle(session: Session(phase: DisplayPhase.Running, reason: StatusReason.Working, project: null)));
    }

    [Fact]
    public void OpensASessionInTheCopilotAppOnlyWhenItsInstalled()
    {
        var session = Session(phase: DisplayPhase.Done, reason: StatusReason.Finished);
        var row = CopilotRows.Row(session: session, canOpen: true, showContextUsage: false);
        Assert.Equal(expected: [new PanelCommand(Key: CopilotCommands.Open, Title: "Open in GitHub Copilot", Opens: true)], actual: row.Commands);
        Assert.EndsWith(expectedEndString: "Click to open in GitHub Copilot", actualString: row.ToolTip, comparisonType: StringComparison.Ordinal);

        var unopenable = CopilotRows.Row(session: session, canOpen: false, showContextUsage: false);
        Assert.Empty(collection: unopenable.Commands);
        Assert.EndsWith(expectedEndString: "BriefBar opens sessions in the GitHub Copilot app, which isn't installed", actualString: unopenable.ToolTip, comparisonType: StringComparison.Ordinal);
    }

    /// A session whose question another asks you opens that one, where you answer it; its menu opens it itself, and the
    /// session that started it, which its ↳ tag names.
    [Fact]
    public void OffersWhatTheMacsMenuOffers()
    {
        var relayed = Session(phase: DisplayPhase.Running, reason: StatusReason.Relayed) with
        {
            AnswerIn = new RelatedSession(Id: "coordinator", Name: "Release 2.5"),
            Parent = new RelatedSession(Id: "lead", Name: "A session with a rather long name indeed"),
        };
        var row = CopilotRows.Row(session: relayed, canOpen: true, showContextUsage: false);
        Assert.Equal(
            expected:
            [
                new PanelCommand(Key: CopilotCommands.Open, Title: "Answer in “Release 2.5”", Opens: true),
                new PanelCommand(Key: CopilotCommands.OpenItself, Title: "Open this session", Opens: true),
                new PanelCommand(Key: CopilotCommands.OpenParent, Title: "Open “A session with a rather long name indeed”", Opens: true),
            ],
            actual: row.Commands);
        Assert.Equal(
            expected: new RowTag(Text: "↳ A session with a rather…", ToolTip: "Started by “A session with a rather long name indeed”: click to open it", Spoken: "Started by “A session with a rather long name indeed”", Command: CopilotCommands.OpenParent),
            actual: row.Tag);
        Assert.Contains(expectedSubstring: "“Release 2.5”, which coordinates it, asks you this for it", actualString: row.ToolTip, comparisonType: StringComparison.Ordinal);

        // Without the Copilot app, the tag still names the session that started it, but opens nothing.
        Assert.Equal(
            expected: new RowTag(Text: "↳ A session with a rather…", ToolTip: "Started by “A session with a rather long name indeed”", Spoken: "Started by “A session with a rather long name indeed”", Command: null),
            actual: CopilotRows.Row(session: relayed, canOpen: false, showContextUsage: false).Tag);

        // Where you answer it is the session that started it: the row names it already.
        var askedByParent = relayed with { Parent = new RelatedSession(Id: "coordinator", Name: "Release 2.5") };
        var plain = CopilotRows.Row(session: askedByParent, canOpen: true, showContextUsage: false);
        Assert.Null(@object: plain.Tag);
        Assert.Equal(expected: [CopilotCommands.Open, CopilotCommands.OpenItself], actual: plain.Commands.Select(selector: command => command.Key));
    }

    [Fact]
    public void ShowsContextUsageOnlyWhenAskedAndMeasured()
    {
        var measured = Session(phase: DisplayPhase.Running, reason: StatusReason.Working) with { ContextUsage = new ContextUsage(Tokens: 151_000, Limit: 200_000) };
        Assert.Null(@object: CopilotRows.Row(session: measured, canOpen: true, showContextUsage: false).Meter);
        Assert.Null(@object: CopilotRows.Row(session: measured with { ContextUsage = null }, canOpen: true, showContextUsage: true).Meter);
        var meter = CopilotRows.Row(session: measured, canOpen: true, showContextUsage: true).Meter;
        Assert.Equal(expected: new RowMeter(Fraction: 0.755, Text: "76%", IsHigh: true, Spoken: "Context: 76% full (151K of 200K tokens)"), actual: meter);
        Assert.False(condition: CopilotRows.Row(session: measured with { ContextUsage = new ContextUsage(Tokens: 1_200, Limit: 1_200_000) }, canOpen: true, showContextUsage: true).Meter!.IsHigh);
        Assert.Equal(expected: ["999", "1.2K", "90K", "128K", "1.5M"], actual: new long[] { 999, 1_234, 90_000, 128_000, 1_500_000 }.Select(selector: CopilotRows.Compact));
    }

    [Fact]
    public void IndentsANestedSessionThreeLevelsAtMost()
    {
        Assert.Equal(expected: 2, actual: CopilotRows.Row(session: Session(phase: DisplayPhase.Running, reason: StatusReason.Working) with { Depth = 2 }, canOpen: true, showContextUsage: false).Depth);
        Assert.Equal(expected: 3, actual: CopilotRows.Row(session: Session(phase: DisplayPhase.Running, reason: StatusReason.Working) with { Depth = 7 }, canOpen: true, showContextUsage: false).Depth);
    }

    [Fact]
    public void ListsItsGroupsAsTheMacDoes()
    {
        Assert.Equal(expected: ["Needs you", "Running", "Done", "Stopped", "Idle"], actual: CopilotRows.Groups.Select(selector: group => group.Title));
        Assert.Equal(
            expected: ["done", "stopped"],
            actual: CopilotRows.Groups.Where(predicate: group => group.Commands.Any(predicate: command => command.Key == CopilotCommands.Clear)).Select(selector: group => group.Key));
        Assert.Equal(expected: ["idle"], actual: CopilotRows.Groups.Where(predicate: group => group.IsFolded).Select(selector: group => group.Key));
        Assert.All(collection: DisplayPhases.All, action: phase => Assert.Equal(expected: phase, actual: CopilotRows.Phase(groupKey: CopilotRows.GroupKey(phase: phase))));
        Assert.Null(@object: CopilotRows.Phase(groupKey: "elsewhere"));
    }

    [Fact]
    public void SaysHowItStands()
    {
        var settings = new CopilotSettings(settings: new MemorySettings(), now: T(seconds: 0));
        var store = new SessionStore(settings: settings, openSession: _ => { }, isAppInstalled: () => true, isAppFrontmost: () => false);
        Assert.Equal(expected: SectionCondition.Starting, actual: CopilotRows.Snapshot(store: store, settings: settings).Status.Condition);

        store.Receive(snapshot: new EngineSnapshot(), now: T(seconds: 0));
        var quiet = CopilotRows.Snapshot(store: store, settings: settings);
        Assert.Equal(expected: SectionStatus.Live, actual: quiet.Status);
        Assert.Empty(collection: quiet.Rows);
        Assert.Equal(expected: new QuietNote(Title: "All quiet", Detail: "No sessions yet"), actual: quiet.Quiet);
        Assert.Equal(expected: [new PanelCommand(Key: CopilotCommands.OpenApp, Title: "Open GitHub Copilot", Opens: true)], actual: quiet.Commands);

        store.Receive(snapshot: new EngineSnapshot { Problem = "No Copilot data found at a made-up folder", ListedByApp = false }, now: T(seconds: 0));
        var problem = CopilotRows.Snapshot(store: store, settings: settings).Status;
        Assert.Equal(expected: SectionCondition.Problem, actual: problem.Condition);
        Assert.Equal(expected: "No Copilot data found at a made-up folder", actual: problem.Problem);
        Assert.Equal(expected: "Can't read", actual: problem.ShortProblem);

        // With sessions it can still show, from the last good read or the session folders, it shows them, saying why.
        var listed = new EngineSnapshot
        {
            Records = [new SessionRecord(Meta: new SessionMeta { Id = "s", Name = "Made-up session", IsRunning = null }, Log: null)],
            Problem = "Copilot database query failed: made up. The list may be out of date.",
        };
        store.Receive(snapshot: listed, now: T(seconds: 0));
        var stale = CopilotRows.Snapshot(store: store, settings: settings);
        Assert.Equal(expected: SectionCondition.Stale, actual: stale.Status.Condition);
        Assert.Single(collection: stale.Rows);
        Assert.Equal(expected: new QuietNote(Title: "All quiet", Detail: "1 idle session"), actual: stale.Quiet);
        Assert.Equal(expected: ["No sessions yet", "1 idle session", "34 idle sessions"], actual: new List<int> { 0, 1, 34 }.Select(selector: CopilotRows.IdleWords));
    }

    [Fact]
    public void BriefsWhatNeedsYouAndHowSessionsEnded()
    {
        var snapshot = DemoData.CopilotSessions(now: T(seconds: 0));
        var counted = snapshot.Rows.Where(predicate: row => row.State is not null).ToList();
        Assert.Equal(expected: counted.Select(selector: row => row.Id), actual: snapshot.BriefLines.Select(selector: line => line.Id));
        Assert.All(collection: snapshot.BriefLines, action: line => Assert.Equal(expected: counted.Single(predicate: row => row.Id == line.Id).State, actual: line.State));
        Assert.Contains(
            expected: "“Release 2.4.0” needs your permission to run git push origin main --follow-tags.",
            collection: snapshot.BriefLines.Select(selector: line => line.Sentence));
    }

    /// The demo's made-up sessions, through the same store and rows as the app's: three need you, two run, one finished,
    /// one stopped responding, and two are idle.
    [Fact]
    public void ShowsTheDemosSessionsAsItWouldTheApps()
    {
        var snapshot = DemoData.CopilotSessions(now: T(seconds: 0));
        Assert.Equal(expected: new StateCounts(NeedsYou: 3, Failing: 1, Running: 2, Done: 1), actual: snapshot.Counts);
        Assert.Equal(
            expected: ["needsYou", "needsYou", "needsYou", "running", "running", "done", "stopped", "idle", "idle"],
            actual: snapshot.Rows.Select(selector: row => row.Group));
        // Needs you starts with the longest wait.
        Assert.Equal(expected: ["demo-dark-mode", "demo-oauth", "demo-release"], actual: snapshot.Rows.Take(count: 3).Select(selector: row => row.Id));
        Assert.Equal(expected: "Needs permission · acme-api", actual: snapshot.Rows[2].Status);
        Assert.Equal(expected: "Stopped responding · shop-web", actual: snapshot.Rows.Single(predicate: row => row.Group == "stopped").Status);
        Assert.All(collection: snapshot.Rows, action: row => Assert.Null(@object: row.Meter));
    }

    static SessionSnapshot Session(DisplayPhase phase, StatusReason reason, string? project = "shop-web", bool isChat = false) => new()
    {
        Id = "s1",
        Name = "Add dark mode",
        ProjectName = project,
        IsChat = isChat,
        Phase = phase,
        Reason = reason,
        Headline = reason.Headline(),
        Since = T(seconds: 0),
    };
}
