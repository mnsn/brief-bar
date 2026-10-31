using BriefBar.Core.Copilot;
using static BriefBar.Core.Tests.Copilot.Line;
using static BriefBar.Core.Tests.Copilot.TestTimes;

namespace BriefBar.Core.Tests.Copilot;

public sealed class RelayedQuestionsTests
{
    /// What the merge needs: with Show relayed questions once off, nothing is merged and a relay is work.
    static readonly ResolverOptions relayedOnce = new() { ShowRelayedQuestionsOnce = true };
    static readonly RelatedSession release = new(Id: "coordinator", Name: "Release 2.5");
    static readonly RelatedSession colors = new(Id: "child", Name: "Pick colors");

    /// The app tells the coordinator, which relays it: you answer it there, once.
    [Fact]
    public void ARelayedQuestionShowsOnceWhereTheCoordinatorAsksIt()
    {
        var question = Asking(question: "Which **color**?", at: T(seconds: 10), choices: ["Blue", "Green"]);
        // A relay names a session by its workspace or its own ID. It's enough on its own, whatever the app records.
        foreach (var (named, coordinator) in new (string, string?)[] { ("w-child", "coordinator"), ("child", null) })
        {
            var sessions = Merged(records:
            [
                Record(id: "child", name: "Pick colors", lines: question, workspace: "w-child", coordinator: coordinator),
                Record(id: "coordinator", name: "Release 2.5", lines: Relaying(session: named, at: T(seconds: 12), context: "From the theme session.")),
            ]);
            var asking = sessions["coordinator"];
            Assert.Equal(expected: DisplayPhase.NeedsYou, actual: asking.Phase);
            Assert.Equal(expected: StatusReason.Question, actual: asking.Reason);
            Assert.Equal(expected: "Waiting for your answer", actual: asking.Headline);
            Assert.Equal(expected: "Which color?", actual: asking.Detail);
            Assert.Equal(expected: ["Blue", "Green"], actual: asking.Choices);
            Assert.Equal(expected: T(seconds: 10), actual: asking.Since);
            Assert.Equal(expected: [colors], actual: asking.AsksFor);
            Assert.Null(@object: asking.AnswerIn);

            var waiting = sessions["child"];
            Assert.Equal(expected: DisplayPhase.Running, actual: waiting.Phase);
            Assert.Equal(expected: StatusReason.Relayed, actual: waiting.Reason);
            Assert.Equal(expected: "Answer in “Release 2.5”", actual: waiting.Headline);
            Assert.Equal(expected: "Which color?", actual: waiting.Detail);
            Assert.Equal(expected: ["Blue", "Green"], actual: waiting.Choices);
            Assert.Equal(expected: T(seconds: 10), actual: waiting.Since);
            Assert.Equal(expected: release, actual: waiting.AnswerIn);
            Assert.Empty(collection: waiting.AsksFor);
            Assert.Equal(expected: 1, actual: new PhaseCounts(snapshots: sessions.Values).NeedsYou);
        }
    }

    /// A plan can't be relayed, so the coordinator asks about it in its own words.
    [Fact]
    public void APlanTheCoordinatorAsksAboutShowsOnce()
    {
        var sessions = Merged(records:
        [
            Record(id: "child", name: "Pick colors", lines: Planning(summary: "Use the brand palette.", at: T(seconds: 10)), coordinator: "coordinator"),
            Record(id: "coordinator", name: "Release 2.5", lines: Asking(question: "Approve “Pick colors”'s plan?", at: T(seconds: 40))),
        ]);
        var asking = sessions["coordinator"];
        Assert.Equal(expected: DisplayPhase.NeedsYou, actual: asking.Phase);
        Assert.Equal(expected: "Approve “Pick colors”'s plan?", actual: asking.Detail);
        Assert.Equal(expected: T(seconds: 10), actual: asking.Since);
        Assert.Equal(expected: [colors], actual: asking.AsksFor);
        var waiting = sessions["child"];
        Assert.Equal(expected: DisplayPhase.Running, actual: waiting.Phase);
        Assert.Equal(expected: StatusReason.Relayed, actual: waiting.Reason);
        Assert.Equal(expected: "Use the brand palette.", actual: waiting.Detail);
        Assert.Equal(expected: T(seconds: 10), actual: waiting.Since);
        Assert.Equal(expected: release, actual: waiting.AnswerIn);
    }

    [Fact]
    public void UntilTheCoordinatorAsksTheSessionNeedsYouItself()
    {
        Dictionary<string, StatusReason> Reasons(string[] child, string[] asking, string? coordinator = "coordinator") =>
            Merged(records:
            [
                Record(id: "child", name: "Pick colors", lines: child, coordinator: coordinator),
                Record(id: "coordinator", name: "Release 2.5", lines: asking),
            ]).ToDictionary(keySelector: pair => pair.Key, elementSelector: pair => pair.Value.Reason);
        var plan = Planning(summary: "Use the brand palette.", at: T(seconds: 10));
        // It hasn't asked yet.
        Assert.Equal(expected: Expected(child: StatusReason.PlanApproval, coordinator: StatusReason.Working), actual: Reasons(child: plan, asking: Working(at: T(seconds: 12))));
        // Its question came first, so it isn't about the plan.
        Assert.Equal(expected: Expected(child: StatusReason.PlanApproval, coordinator: StatusReason.Question), actual: Reasons(child: plan, asking: Asking(question: "Ship on Friday?", at: T(seconds: 5))));
        // It doesn't coordinate the session, nor relays its question.
        Assert.Equal(expected: Expected(child: StatusReason.PlanApproval, coordinator: StatusReason.Question), actual: Reasons(child: plan, asking: Asking(question: "Ship on Friday?", at: T(seconds: 40)), coordinator: null));
        Assert.Equal(expected: Expected(child: StatusReason.PlanApproval, coordinator: StatusReason.Question), actual: Reasons(child: plan, asking: Asking(question: "Ship on Friday?", at: T(seconds: 40)), coordinator: "someone-else"));
        // Only the session itself can answer a permission prompt.
        string[] permission = [UserMessage(at: T(seconds: 0)), PermissionRequested(id: "r1", request: new() { ["kind"] = "shell", ["fullCommandText"] = "git push" }, at: T(seconds: 10))];
        Assert.Equal(expected: Expected(child: StatusReason.Permission, coordinator: StatusReason.Question), actual: Reasons(child: permission, asking: Asking(question: "Push?", at: T(seconds: 40))));
        // A relay is only of a question.
        Assert.Equal(expected: Expected(child: StatusReason.PlanApproval, coordinator: StatusReason.Question), actual: Reasons(child: plan, asking: Relaying(session: "child", at: T(seconds: 40)), coordinator: null));
        // A coordinator whose own plan waits shows that, so the question it relays needs you in its session too.
        string[] relayingWithAPlan = [.. Relaying(session: "child", at: T(seconds: 40)), ToolStart(name: "exit_plan_mode", id: "p", at: T(seconds: 41), arguments: new() { ["summary"] = "Ship on Friday." })];
        Assert.Equal(expected: Expected(child: StatusReason.Question, coordinator: StatusReason.PlanApproval), actual: Reasons(child: Asking(question: "Which color?", at: T(seconds: 10)), asking: relayingWithAPlan));
        // A coordinator that isn't listed asks nothing here.
        var alone = Merged(records: [Record(id: "child", name: "Pick colors", lines: plan, coordinator: "coordinator")]);
        Assert.Equal(expected: StatusReason.PlanApproval, actual: alone["child"].Reason);
    }

    /// The session it relays for isn't listed, archived say: the relay says what it says before the question.
    [Fact]
    public void ARelayForAnUnlistedSessionKeepsItsOwnWords()
    {
        var sessions = Merged(records: [Record(id: "coordinator", name: "Release 2.5", lines: Relaying(session: "w-gone", at: T(seconds: 12), context: "From the theme session."))]);
        var asking = sessions["coordinator"];
        Assert.Equal(expected: DisplayPhase.NeedsYou, actual: asking.Phase);
        Assert.Equal(expected: "From the theme session.", actual: asking.Detail);
        Assert.Equal(expected: T(seconds: 12), actual: asking.Since);
        Assert.Empty(collection: asking.AsksFor);
    }

    /// Once it asks, it brings you the rest that waited for it before, one after another.
    [Fact]
    public void EverySessionThatWaitedForTheCoordinatorShowsOnce()
    {
        var sessions = Merged(records:
        [
            Record(id: "first", name: "Pick colors", lines: Asking(question: "Which color?", at: T(seconds: 10)), coordinator: "coordinator"),
            Record(id: "second", name: "Pick fonts", lines: Planning(summary: "Use Inter.", at: T(seconds: 20)), coordinator: "coordinator"),
            Record(id: "later", name: "Pick icons", lines: Asking(question: "Which icons?", at: T(seconds: 40)), coordinator: "coordinator"),
            Record(id: "coordinator", name: "Release 2.5", lines: Relaying(session: "first", at: T(seconds: 30))),
        ]);
        var asking = sessions["coordinator"];
        Assert.Equal(expected: "Which color?", actual: asking.Detail);
        Assert.Equal(expected: T(seconds: 10), actual: asking.Since);
        Assert.Equal(expected: ["first", "second"], actual: asking.AsksFor.Select(selector: session => session.Id));
        Assert.Equal(expected: release, actual: sessions["first"].AnswerIn);
        Assert.Equal(expected: release, actual: sessions["second"].AnswerIn);
        // It asked for it after the coordinator asked, so maybe not through it.
        Assert.Equal(expected: DisplayPhase.NeedsYou, actual: sessions["later"].Phase);
        Assert.Null(@object: sessions["later"].AnswerIn);
    }

    /// A coordinator that's coordinated in turn: you answer where the question reaches you.
    [Fact]
    public void ARelayOfARelayIsAnsweredWhereItEnds()
    {
        var sessions = Merged(records:
        [
            Record(id: "child", name: "Pick colors", lines: Asking(question: "Which color?", at: T(seconds: 10)), workspace: "w-child", coordinator: "coordinator"),
            Record(id: "coordinator", name: "Release 2.5", lines: Relaying(session: "w-child", at: T(seconds: 12)), workspace: "w-coordinator", coordinator: "planner"),
            Record(id: "planner", name: "Plan the quarter", lines: Relaying(session: "w-coordinator", at: T(seconds: 14))),
        ]);
        var planner = new RelatedSession(Id: "planner", Name: "Plan the quarter");
        var asking = sessions["planner"];
        Assert.Equal(expected: DisplayPhase.NeedsYou, actual: asking.Phase);
        Assert.Equal(expected: "Which color?", actual: asking.Detail);
        Assert.Equal(expected: T(seconds: 10), actual: asking.Since);
        Assert.Equal(expected: ["child", "coordinator"], actual: asking.AsksFor.Select(selector: session => session.Id));
        foreach (var id in new[] { "child", "coordinator" })
        {
            Assert.Equal(expected: DisplayPhase.Running, actual: sessions[id].Phase);
            Assert.Equal(expected: "Which color?", actual: sessions[id].Detail);
            Assert.Equal(expected: planner, actual: sessions[id].AnswerIn);
        }
    }

    /// A coordinator can relay several questions at once, whatever the app records of who coordinates whom: each is
    /// answered where it asks, from the first it relayed.
    [Fact]
    public void EveryQuestionACoordinatorRelaysAtOnceShowsOnce()
    {
        string[] relayingBoth =
        [
            UserMessage(at: T(seconds: 0)),
            ToolStart(name: "relay_session_input", id: "r1", at: T(seconds: 12), arguments: new() { ["project_session_id"] = "w-first" }),
            ToolStart(name: "relay_session_input", id: "r2", at: T(seconds: 13), arguments: new() { ["project_session_id"] = "w-second" }),
        ];
        var sessions = Merged(records:
        [
            Record(id: "first", name: "Pick colors", lines: Asking(question: "Which color?", at: T(seconds: 10)), workspace: "w-first"),
            Record(id: "second", name: "Pick fonts", lines: Asking(question: "Which font?", at: T(seconds: 11)), workspace: "w-second"),
            Record(id: "coordinator", name: "Release 2.5", lines: relayingBoth),
        ]);
        var coordinator = sessions["coordinator"];
        Assert.Equal(expected: DisplayPhase.NeedsYou, actual: coordinator.Phase);
        Assert.Equal(expected: "Which color?", actual: coordinator.Detail);
        Assert.Equal(expected: T(seconds: 10), actual: coordinator.Since);
        Assert.Equal(expected: ["first", "second"], actual: coordinator.AsksFor.Select(selector: session => session.Id));
        foreach (var id in new[] { "first", "second" })
        {
            Assert.Equal(expected: DisplayPhase.Running, actual: sessions[id].Phase);
            Assert.Equal(expected: release, actual: sessions[id].AnswerIn);
        }
        Assert.Equal(expected: "Which font?", actual: sessions["second"].Detail);

        // Its own question comes first, and isn't one it relays.
        string[] ownQuestionToo = [.. relayingBoth, ToolStart(name: "ask_user", id: "q", at: T(seconds: 14), arguments: new() { ["question"] = "Ship it?" })];
        var own = Merged(records:
        [
            Record(id: "first", name: "Pick colors", lines: Asking(question: "Which color?", at: T(seconds: 10)), workspace: "w-first"),
            Record(id: "coordinator", name: "Release 2.5", lines: ownQuestionToo),
        ]);
        Assert.Equal(expected: "Ship it?", actual: own["coordinator"].Detail);
        Assert.Empty(collection: own["coordinator"].AsksFor);
        Assert.Equal(expected: DisplayPhase.NeedsYou, actual: own["first"].Phase);
    }

    /// Sessions can't relay each other's questions, but if they seemed to, one of them would still need you.
    [Fact]
    public void ACycleStillLeavesOneToAnswer()
    {
        var sessions = Merged(records:
        [
            Record(id: "a", name: "A", lines: Relaying(session: "w-b", at: T(seconds: 12)), workspace: "w-a"),
            Record(id: "b", name: "B", lines: Relaying(session: "w-a", at: T(seconds: 14)), workspace: "w-b"),
        ]);
        Assert.Equal(expected: DisplayPhase.NeedsYou, actual: sessions["a"].Phase);
        Assert.Equal(expected: [new RelatedSession(Id: "b", Name: "B")], actual: sessions["a"].AsksFor);
        Assert.Equal(expected: new RelatedSession(Id: "a", Name: "A"), actual: sessions["b"].AnswerIn);
    }

    [Fact]
    public void LeavesEverythingElseAsItIs()
    {
        SessionRecord[] records =
        [
            Record(id: "child", name: "Pick colors", lines: Asking(question: "Which color?", at: T(seconds: 10)), coordinator: "coordinator"),
            Record(id: "coordinator", name: "Release 2.5", lines: Working(at: T(seconds: 12))),
        ];
        var snapshots = records.Select(selector: record => StatusResolver.Snapshot(record: record, now: T(seconds: 60), options: relayedOnce)).ToList();
        Assert.Equal(expected: snapshots, actual: RelayedQuestions.Merge(snapshots: snapshots, records: records));
        Assert.Empty(collection: RelayedQuestions.Merge(snapshots: [], records: records));
    }

    static string[] Asking(string question, DateTimeOffset at, string[]? choices = null) =>
    [
        UserMessage(at: T(seconds: 0)),
        ToolStart(name: "ask_user", id: "q", at: at, arguments: new() { ["question"] = question, ["choices"] = choices ?? [] }),
    ];

    static string[] Planning(string summary, DateTimeOffset at) =>
        [UserMessage(at: T(seconds: 0)), ToolStart(name: "exit_plan_mode", id: "p", at: at, arguments: new() { ["summary"] = summary })];

    static string[] Relaying(string session, DateTimeOffset at, string? context = null)
    {
        var arguments = new Dictionary<string, object?> { ["project_session_id"] = session, ["request_id"] = "request-" + session };
        if (context is not null)
        {
            arguments["context"] = context;
        }
        return [UserMessage(at: T(seconds: 0)), ToolStart(name: "relay_session_input", id: "r", at: at, arguments: arguments)];
    }

    static string[] Working(DateTimeOffset at) =>
        [UserMessage(at: T(seconds: 0)), ToolStart(name: "bash", id: "b", at: at, arguments: new() { ["description"] = "Run the tests" })];

    static SessionRecord Record(string id, string name, string[] lines, string? workspace = null, string? coordinator = null) => new(
        Meta: new SessionMeta { Id = id, Name = name, IsRunning = true, UpdatedAt = T(seconds: 0), CoordinatorSessionId = coordinator, WorkspaceId = workspace },
        Log: LogState(lines: lines));

    static Dictionary<string, SessionSnapshot> Merged(SessionRecord[] records)
    {
        var snapshots = records.Select(selector: record => StatusResolver.Snapshot(record: record, now: T(seconds: 60), options: relayedOnce)).ToList();
        return RelayedQuestions.Merge(snapshots: snapshots, records: records).ToDictionary(keySelector: snapshot => snapshot.Id);
    }

    static Dictionary<string, StatusReason> Expected(StatusReason child, StatusReason coordinator) =>
        new() { ["child"] = child, ["coordinator"] = coordinator };
}
