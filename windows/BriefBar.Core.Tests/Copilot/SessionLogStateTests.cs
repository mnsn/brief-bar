using BriefBar.Core.Copilot;
using static BriefBar.Core.Tests.Copilot.Line;
using static BriefBar.Core.Tests.Copilot.TestTimes;

namespace BriefBar.Core.Tests.Copilot;

public sealed class SessionLogStateTests
{
    [Fact]
    public void StartsUnknown()
    {
        var state = new SessionLogState();
        Assert.Equal(expected: LogPhase.Unknown, actual: state.Phase);
        Assert.Null(@object: state.PhaseSince);
        Assert.Null(@object: state.LastEventAt);
        Assert.Equal(expected: LogActivity.Unknown, actual: state.Activity);
    }

    [Fact]
    public void TurnEndBetweenToolCallsDoesNotFinish()
    {
        List<string> lines =
        [
            SessionStart(at: T(seconds: 0)),
            UserMessage(at: T(seconds: 1)),
            TurnStart(at: T(seconds: 2)),
            AssistantMessage(at: T(seconds: 3), toolCalls: ["c1"]),
            ToolStart(name: "bash", id: "c1", at: T(seconds: 4), arguments: new() { ["description"] = "Run tests" }),
            ToolComplete(id: "c1", at: T(seconds: 5)),
            TurnEnd(at: T(seconds: 6)),
        ];
        var midRun = LogState(lines: lines);
        Assert.Equal(expected: LogPhase.Running, actual: midRun.Phase);
        Assert.Equal(expected: LogActivity.Working(since: T(seconds: 1), detail: "Run tests"), actual: midRun.Activity);

        lines.AddRange(collection: [TurnStart(at: T(seconds: 7)), AssistantMessage(at: T(seconds: 8)), TurnEnd(at: T(seconds: 9))]);
        var done = LogState(lines: lines);
        Assert.Equal(expected: LogActivity.Finished(at: T(seconds: 9), summary: null), actual: done.Activity);
        Assert.Null(@object: done.CurrentStep);
        Assert.Equal(expected: T(seconds: 9), actual: done.LastEventAt);
    }

    [Fact]
    public void PendingWorkBlocksFinishing()
    {
        List<string> lines =
        [
            UserMessage(at: T(seconds: 1)),
            PermissionRequested(id: "r1", request: new() { ["kind"] = "shell", ["fullCommandText"] = "make" }, at: T(seconds: 2)),
            AssistantMessage(at: T(seconds: 3)),
            TurnEnd(at: T(seconds: 4)),
        ];
        Assert.Equal(expected: LogPhase.Running, actual: LogState(lines: lines).Phase);

        lines.AddRange(collection: [PermissionCompleted(id: "r1", at: T(seconds: 5)), TurnEnd(at: T(seconds: 6))]);
        Assert.Equal(expected: LogActivity.Finished(at: T(seconds: 6), summary: null), actual: LogState(lines: lines).Activity);
    }

    [Fact]
    public void QuestionsAndPlansWaitForTheUser()
    {
        string[] asking =
        [
            UserMessage(at: T(seconds: 1)),
            AssistantMessage(at: T(seconds: 2), toolCalls: ["q"]),
            ToolStart(name: "ask_user", id: "q", at: T(seconds: 3), arguments: new() { ["question"] = "Which DB?", ["choices"] = new List<string> { "A", "B" } }),
        ];
        var state = LogState(lines: asking);
        Assert.Equal(
            expected: LogActivity.NeedsAnswer(tool: new PendingTool
            {
                CallId = "q",
                Name = "ask_user",
                StartedAt = T(seconds: 3),
                Question = "Which DB?",
                Choices = ["A", "B"],
            }),
            actual: state.Activity);
        // Interaction tools aren't work steps.
        Assert.Null(@object: state.CurrentStep);

        var answered = LogState(lines: [.. asking, ToolComplete(id: "q", at: T(seconds: 4))]);
        Assert.Equal(expected: LogActivity.Working(since: T(seconds: 1), detail: null), actual: answered.Activity);

        var planning = LogState(
            UserMessage(at: T(seconds: 1)),
            ToolStart(name: "exit_plan_mode", id: "p", at: T(seconds: 2), arguments: new() { ["summary"] = "1. Add tests" }));
        Assert.Equal(
            expected: LogActivity.NeedsPlanApproval(tool: new PendingTool
            {
                CallId = "p",
                Name = "exit_plan_mode",
                StartedAt = T(seconds: 2),
                PlanSummary = "1. Add tests",
            }),
            actual: planning.Activity);
    }

    /// A coordinator that relays a question a session it coordinates waits on waits for your answer itself.
    [Fact]
    public void RelayedQuestionsWaitForTheUser()
    {
        string[] relaying =
        [
            UserMessage(at: T(seconds: 1), content: "Child session needs your input."),
            AssistantMessage(at: T(seconds: 2), toolCalls: ["r"]),
            ToolStart(name: "relay_session_input", id: "r", at: T(seconds: 3), arguments: new()
            {
                ["project_session_id"] = "w-child", ["request_id"] = "request", ["context"] = "From the checkout session.",
            }),
        ];
        var state = LogState(lines: relaying);
        Assert.Equal(
            expected: LogActivity.NeedsAnswer(tool: new PendingTool
            {
                CallId = "r",
                Name = "relay_session_input",
                StartedAt = T(seconds: 3),
                RelayedSession = "w-child",
                RelayContext = "From the checkout session.",
            }),
            actual: state.Activity);
        Assert.Null(@object: state.CurrentStep);
        Assert.Equal(expected: LogActivity.Working(since: T(seconds: 1), detail: null), actual: LogState(lines: [.. relaying, ToolComplete(id: "r", at: T(seconds: 4))]).Activity);

        // Its own question comes first.
        var both = LogState(lines: [.. relaying, ToolStart(name: "ask_user", id: "q", at: T(seconds: 5), arguments: new() { ["question"] = "Ship it?" })]);
        Assert.Equal(
            expected: LogActivity.NeedsAnswer(tool: new PendingTool { CallId = "q", Name = "ask_user", StartedAt = T(seconds: 5), Question = "Ship it?" }),
            actual: both.Activity);
        // So does its own plan.
        var planning = LogState(lines: [.. relaying, ToolStart(name: "exit_plan_mode", id: "p", at: T(seconds: 5), arguments: new() { ["summary"] = "Ship it." })]);
        Assert.Equal(
            expected: LogActivity.NeedsPlanApproval(tool: new PendingTool { CallId = "p", Name = "exit_plan_mode", StartedAt = T(seconds: 5), PlanSummary = "Ship it." }),
            actual: planning.Activity);
    }

    [Fact]
    public void PermissionsComeFirstThenQuestionsThenPlans()
    {
        List<string> lines =
        [
            UserMessage(at: T(seconds: 1)),
            ToolStart(name: "exit_plan_mode", id: "p", at: T(seconds: 2), arguments: new() { ["summary"] = "Plan" }),
            ToolStart(name: "ask_user", id: "q", at: T(seconds: 3), arguments: new() { ["question"] = "Sure?" }),
            PermissionRequested(id: "r1", request: new() { ["kind"] = "shell", ["fullCommandText"] = "first" }, at: T(seconds: 4)),
            PermissionRequested(id: "r2", request: new() { ["kind"] = "shell", ["fullCommandText"] = "second" }, at: T(seconds: 5)),
        ];
        string? WaitingOn()
        {
            var activity = LogState(lines: lines).Activity;
            return activity.Permission?.RequestId ?? activity.Tool?.CallId;
        }
        Assert.Equal(expected: "r1", actual: WaitingOn());
        lines.Add(item: PermissionCompleted(id: "r1", at: T(seconds: 6)));
        Assert.Equal(expected: "r2", actual: WaitingOn());
        lines.Add(item: PermissionCompleted(id: "r2", at: T(seconds: 7)));
        Assert.Equal(expected: "q", actual: WaitingOn());
        lines.Add(item: ToolComplete(id: "q", at: T(seconds: 8)));
        Assert.Equal(expected: "p", actual: WaitingOn());
        lines.Add(item: ToolComplete(id: "p", at: T(seconds: 9)));
        Assert.Equal(expected: LogActivity.Working(since: T(seconds: 1), detail: null), actual: LogState(lines: lines).Activity);
    }

    [Fact]
    public void AbortInterruptsButSubagentCancellationDoesNot()
    {
        string[] running =
        [
            UserMessage(at: T(seconds: 1)),
            AssistantMessage(at: T(seconds: 2), toolCalls: ["c1"]),
            ToolStart(name: "task", id: "c1", at: T(seconds: 3), arguments: new() { ["description"] = "Explore" }),
        ];
        var cancelled = LogState(lines: [.. running, Abort(at: T(seconds: 4), reason: "subagent_cancelled")]);
        Assert.Equal(expected: LogActivity.Working(since: T(seconds: 1), detail: "Explore"), actual: cancelled.Activity);
        Assert.Equal(expected: ["c1"], actual: cancelled.PendingTools.Keys.Order());

        var aborted = LogState(lines: [.. running, Abort(at: T(seconds: 4))]);
        Assert.Equal(expected: LogActivity.Interrupted(at: T(seconds: 4)), actual: aborted.Activity);
        Assert.Empty(collection: aborted.PendingTools);
        Assert.Null(@object: aborted.CurrentStep);
    }

    [Fact]
    public void ErrorsFailUntilTheNextMessage()
    {
        string[] lines = [UserMessage(at: T(seconds: 1)), SessionError(message: "Rate limited", at: T(seconds: 2))];
        Assert.Equal(expected: LogActivity.Failed(at: T(seconds: 2), message: "Rate limited"), actual: LogState(lines: lines).Activity);

        var retried = LogState(lines: [.. lines, UserMessage(at: T(seconds: 3))]);
        Assert.Equal(expected: LogActivity.Working(since: T(seconds: 3), detail: null), actual: retried.Activity);
        Assert.Null(@object: retried.ErrorMessage);
    }

    [Fact]
    public void ShutdownInterruptsOnlyARunningTurn()
    {
        var midTurn = LogState(
            UserMessage(at: T(seconds: 1)),
            ToolStart(name: "bash", id: "c1", at: T(seconds: 2), arguments: new() { ["description"] = "Build" }),
            Shutdown(at: T(seconds: 3)));
        Assert.Equal(expected: LogActivity.Interrupted(at: T(seconds: 3)), actual: midTurn.Activity);
        Assert.Empty(collection: midTurn.PendingTools);
        Assert.Null(@object: midTurn.CurrentStep);

        var afterFinishing = LogState(UserMessage(at: T(seconds: 1)), AssistantMessage(at: T(seconds: 2)), TurnEnd(at: T(seconds: 3)), Shutdown(at: T(seconds: 4)));
        Assert.Equal(expected: LogActivity.Finished(at: T(seconds: 3), summary: null), actual: afterFinishing.Activity);
    }

    [Fact]
    public void AColdResumeEndsWhatTheLastProcessLeftRunning()
    {
        // The CLI quit without a shutdown event while asking; a new one resumed the session.
        string[] crashed =
        [
            UserMessage(at: T(seconds: 1)),
            AssistantMessage(at: T(seconds: 2), toolCalls: ["q"]),
            ToolStart(name: "ask_user", id: "q", at: T(seconds: 3), arguments: new() { ["question"] = "Ship it?" }),
            Resume(at: T(seconds: 60)),
        ];
        var resumed = LogState(lines: crashed);
        Assert.Equal(expected: LogActivity.Interrupted(at: T(seconds: 3)), actual: resumed.Activity);
        Assert.Empty(collection: resumed.PendingTools);
        Assert.False(condition: resumed.LastMainMessageHadTools);
        Assert.Equal(expected: LogActivity.Working(since: T(seconds: 61), detail: null), actual: LogState(lines: [.. crashed, UserMessage(at: T(seconds: 61))]).Activity);

        // After a shutdown there's nothing left to end.
        var finished = LogState(
            UserMessage(at: T(seconds: 1)), AssistantMessage(at: T(seconds: 2)), TurnEnd(at: T(seconds: 3)),
            Shutdown(at: T(seconds: 4)), Resume(at: T(seconds: 60)));
        Assert.Equal(expected: LogActivity.Finished(at: T(seconds: 3), summary: null), actual: finished.Activity);
    }

    [Fact]
    public void AResumeThatKeepsThePendingWorkChangesNothing()
    {
        string[] asking = [UserMessage(at: T(seconds: 1)), ToolStart(name: "ask_user", id: "q", at: T(seconds: 2), arguments: new() { ["question"] = "Ship it?" })];
        var waiting = LogState(lines: asking);
        foreach (var resume in new[] { Resume(at: T(seconds: 60), keepingPendingWork: true), Resume(at: T(seconds: 60), joiningLiveWork: true) })
        {
            var state = LogState(lines: [.. asking, resume]);
            Assert.Equal(expected: waiting.Activity, actual: state.Activity);
            Assert.Equal(expected: waiting.PendingTools, actual: state.PendingTools);
        }
    }

    [Fact]
    public void TaskCompleteFinishesWithASummary()
    {
        string[] lines =
        [
            UserMessage(at: T(seconds: 1)),
            AssistantMessage(at: T(seconds: 2), toolCalls: ["c1"]),
            ToolStart(name: "task_complete", id: "c1", at: T(seconds: 3), arguments: new() { ["summary"] = "Shipped it" }),
            TaskComplete(summary: "Shipped it", at: T(seconds: 4)),
            Hook(hookType: "agentStop", at: T(seconds: 5)),
        ];
        var done = LogState(lines: lines);
        Assert.Equal(expected: LogActivity.Finished(at: T(seconds: 4), summary: "Shipped it"), actual: done.Activity);
        Assert.Empty(collection: done.PendingTools);

        var next = LogState(lines: [.. lines, UserMessage(at: T(seconds: 6))]);
        Assert.Null(@object: next.Summary);
        Assert.Equal(expected: LogActivity.Working(since: T(seconds: 6), detail: null), actual: next.Activity);
    }

    [Fact]
    public void OnlyTheMainAgentsStopHookFinishes()
    {
        string[] lines =
        [
            UserMessage(at: T(seconds: 1)),
            AssistantMessage(at: T(seconds: 2), toolCalls: ["c1"]),
            ToolStart(name: "task", id: "c1", at: T(seconds: 3)),
            Hook(hookType: "agentStop", at: T(seconds: 4), agentId: "sub-agent"),
        ];
        Assert.Equal(expected: LogPhase.Running, actual: LogState(lines: lines).Phase);
        Assert.Equal(expected: LogActivity.Finished(at: T(seconds: 5), summary: null), actual: LogState(lines: [.. lines, Hook(hookType: "agentStop", at: T(seconds: 5))]).Activity);
    }

    [Fact]
    public void SubagentEventsDoNotChangeTheMainAgent()
    {
        List<string> lines =
        [
            UserMessage(at: T(seconds: 1)),
            AssistantMessage(at: T(seconds: 2), toolCalls: ["task1"]),
            ToolStart(name: "task", id: "task1", at: T(seconds: 3), arguments: new() { ["description"] = "Explore" }),
            UserMessage(at: T(seconds: 4), content: "Explore the repo", agentId: "sub-agent"),
            TurnStart(at: T(seconds: 5), subagent: true),
            AssistantMessage(at: T(seconds: 6), toolCalls: ["s1"], subagent: true),
            ToolStart(name: "bash", id: "s1", at: T(seconds: 7), arguments: new() { ["description"] = "grep" }, subagent: true),
            AssistantMessage(at: T(seconds: 8), subagent: true),
            TurnEnd(at: T(seconds: 9), subagent: true),
            ToolComplete(id: "task1", at: T(seconds: 10)),
        ];
        var state = LogState(lines: lines);
        Assert.Equal(expected: LogActivity.Working(since: T(seconds: 1), detail: "Explore"), actual: state.Activity);
        Assert.Empty(collection: state.PendingTools);
        Assert.True(condition: state.LastMainMessageHadTools);
        Assert.Equal(expected: T(seconds: 10), actual: state.LastEventAt);

        lines.AddRange(collection: [AssistantMessage(at: T(seconds: 11)), TurnEnd(at: T(seconds: 12))]);
        Assert.Equal(expected: LogActivity.Finished(at: T(seconds: 12), summary: null), actual: LogState(lines: lines).Activity);
    }

    [Fact]
    public void SteeringMessagesKeepTheTurnGoing()
    {
        var state = LogState(
            UserMessage(at: T(seconds: 1)),
            AssistantMessage(at: T(seconds: 2), toolCalls: ["c1"]),
            ToolStart(name: "bash", id: "c1", at: T(seconds: 3), arguments: new() { ["description"] = "Long build" }),
            UserMessage(at: T(seconds: 4), content: "Also update the docs"));
        Assert.Equal(expected: LogActivity.Working(since: T(seconds: 1), detail: "Long build"), actual: state.Activity);
        Assert.Equal(expected: ["c1"], actual: state.PendingTools.Keys.Order());
        Assert.True(condition: state.LastMainMessageHadTools);
    }

    [Fact]
    public void ANewMessageDropsWhatAnEndedTurnLeftBehind()
    {
        List<string> lines =
        [
            UserMessage(at: T(seconds: 1)),
            AssistantMessage(at: T(seconds: 2), toolCalls: ["c1"]),
            Abort(at: T(seconds: 3)),
            // A straggler logged after the abort.
            ToolStart(name: "bash", id: "late", at: T(seconds: 4), arguments: new() { ["description"] = "Late" }),
        ];
        var interrupted = LogState(lines: lines);
        Assert.Equal(expected: LogActivity.Interrupted(at: T(seconds: 3)), actual: interrupted.Activity);
        Assert.Equal(expected: ["late"], actual: interrupted.PendingTools.Keys.Order());

        lines.Add(item: UserMessage(at: T(seconds: 5)));
        var resumed = LogState(lines: lines);
        Assert.Empty(collection: resumed.PendingTools);
        Assert.Null(@object: resumed.CurrentStep);
        Assert.False(condition: resumed.LastMainMessageHadTools);

        // With the stale "asked for tools" flag cleared, a bare turn end finishes the new turn.
        lines.Add(item: TurnEnd(at: T(seconds: 6)));
        Assert.Equal(expected: LogActivity.Finished(at: T(seconds: 6), summary: null), actual: LogState(lines: lines).Activity);
    }

    [Fact]
    public void EventsWithoutTimestampsUseTheLatestKnownTime()
    {
        var state = new SessionLogState();
        state.Apply(logEvent: new LogEvent(Timestamp: null, Kind: LogEventKind.UserMessage));
        Assert.Equal(expected: LogPhase.Running, actual: state.Phase);
        Assert.Null(@object: state.PhaseSince);

        state.Apply(logEvent: new LogEvent(Timestamp: T(seconds: 2), Kind: LogEventKind.TurnStart(isSubagent: false)));
        Assert.Equal(expected: T(seconds: 2), actual: state.PhaseSince);

        state.Apply(logEvent: new LogEvent(Timestamp: T(seconds: 5), Kind: LogEventKind.Other));
        state.Apply(logEvent: new LogEvent(Timestamp: null, Kind: LogEventKind.ToolStarted(tool: new ToolStart { CallId = "q", Name = "ask_user", Question = "Ok?" })));
        Assert.Equal(expected: T(seconds: 5), actual: state.PendingTools["q"].StartedAt);

        // Out-of-order timestamps never move the clock back.
        state.Apply(logEvent: new LogEvent(Timestamp: T(seconds: 3), Kind: LogEventKind.Other));
        Assert.Equal(expected: T(seconds: 5), actual: state.LastEventAt);

        state.Apply(logEvent: new LogEvent(Timestamp: null, Kind: LogEventKind.AgentStop(isSubagent: false)));
        Assert.Equal(expected: LogActivity.Finished(at: T(seconds: 5), summary: null), actual: state.Activity);
    }

    [Fact]
    public void CurrentStepFollowsTheLatestMainToolCall()
    {
        List<string> lines = [UserMessage(at: T(seconds: 1)), ToolStart(name: "view", id: "c1", at: T(seconds: 2), title: "View README.md")];
        Assert.Equal(expected: "View README.md", actual: LogState(lines: lines).CurrentStep);

        lines.Add(item: ToolStart(name: "report_intent", id: "c2", at: T(seconds: 3), arguments: new() { ["intent"] = "Exploring" }));
        Assert.Equal(expected: "View README.md", actual: LogState(lines: lines).CurrentStep);

        lines.Add(item: ToolStart(name: "bash", id: "c3", at: T(seconds: 4), arguments: new() { ["description"] = "Run tests" }, title: "Bash"));
        Assert.Equal(expected: "Run tests", actual: LogState(lines: lines).CurrentStep);

        lines.Add(item: ToolStart(name: "grep", id: "c4", at: T(seconds: 5)));
        Assert.Null(@object: LogState(lines: lines).CurrentStep);
    }

    [Fact]
    public void ATailThatStartsMidTurnStillShowsTheTurn()
    {
        Assert.Equal(expected: LogActivity.Working(since: T(seconds: 10), detail: null), actual: LogState(ToolStart(name: "bash", id: "c1", at: T(seconds: 10))).Activity);
        Assert.Equal(expected: LogPhase.Running, actual: LogState(AssistantMessage(at: T(seconds: 10))).Phase);
        Assert.Equal(expected: LogPhase.Running, actual: LogState(TurnStart(at: T(seconds: 10))).Phase);

        var permission = LogState(PermissionRequested(id: "r1", request: new() { ["kind"] = "url", ["url"] = "https://example.com" }, at: T(seconds: 10)));
        Assert.Equal(
            expected: LogActivity.NeedsPermission(permission: new PendingPermission { RequestId = "r1", Kind = "url", Detail = "https://example.com", RequestedAt = T(seconds: 10) }),
            actual: permission.Activity);

        Assert.Equal(expected: LogPhase.Unknown, actual: LogState(TurnEnd(at: T(seconds: 10))).Phase);
        Assert.Equal(expected: LogPhase.Unknown, actual: LogState(TurnStart(at: T(seconds: 10), subagent: true)).Phase);
        Assert.Equal(expected: LogActivity.Finished(at: T(seconds: 10), summary: null), actual: LogState(Hook(hookType: "agentStop", at: T(seconds: 10))).Activity);
        Assert.Equal(expected: LogActivity.Finished(at: T(seconds: 10), summary: "Done"), actual: LogState(TaskComplete(summary: "Done", at: T(seconds: 10))).Activity);
    }

    /// A copy changes without changing what it was copied from, as `EventLogReader` relies on.
    [Fact]
    public void ACopyChangesOnItsOwn()
    {
        var original = LogState(UserMessage(at: T(seconds: 1)), ToolStart(name: "ask_user", id: "q", at: T(seconds: 2), arguments: new() { ["question"] = "Ship it?" }));
        var copy = original.Clone();
        Assert.Equal(expected: original, actual: copy);
        copy.Apply(logEvent: new LogEvent(Timestamp: T(seconds: 3), Kind: LogEventKind.ToolComplete(callId: "q")));
        Assert.NotEqual(expected: original, actual: copy);
        Assert.Equal(expected: ["q"], actual: original.PendingTools.Keys);
        Assert.Empty(collection: copy.PendingTools);
    }
}
