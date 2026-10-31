using BriefBar.Core.Copilot;
using static BriefBar.Core.Tests.Copilot.TestTimes;

namespace BriefBar.Core.Tests.Copilot;

public sealed class EventLineParserTests
{
    [Fact]
    public void UserMessagesComeFromTheUserOnly()
    {
        Assert.Equal(expected: new LogEvent(Timestamp: T(seconds: 1), Kind: LogEventKind.UserMessage), actual: Parse(line: Line.UserMessage(at: T(seconds: 1), content: "Hi")));
        // Prompts the main agent sends to subagents carry a top-level agentId.
        var subagentPrompt = Line.UserMessage(at: T(seconds: 2), content: "Explore the repo", agentId: "45e6ba2c-9409-4831-8e44-c91563cc057e");
        Assert.Equal(expected: new LogEvent(Timestamp: T(seconds: 2), Kind: LogEventKind.Other), actual: Parse(line: subagentPrompt));
    }

    [Fact]
    public void TurnsAndReplies()
    {
        Assert.Equal(expected: LogEventKind.TurnStart(isSubagent: false), actual: Parse(line: Line.TurnStart(at: T(seconds: 1)))?.Kind);
        Assert.Equal(expected: LogEventKind.TurnStart(isSubagent: true), actual: Parse(line: Line.TurnStart(at: T(seconds: 1), subagent: true))?.Kind);
        Assert.Equal(expected: LogEventKind.TurnEnd(isSubagent: false), actual: Parse(line: Line.TurnEnd(at: T(seconds: 1)))?.Kind);
        var subagentTurnEnd = Line.Event(type: "assistant.turn_end", at: T(seconds: 1), data: new() { ["turnId"] = "3" }, agentId: "sub-agent");
        Assert.Equal(expected: LogEventKind.TurnEnd(isSubagent: true), actual: Parse(line: subagentTurnEnd)?.Kind);

        Assert.Equal(
            expected: LogEventKind.AssistantMessage(isSubagent: false, hasToolRequests: true),
            actual: Parse(line: Line.AssistantMessage(at: T(seconds: 1), toolCalls: ["c1"]))?.Kind);
        Assert.Equal(
            expected: LogEventKind.AssistantMessage(isSubagent: false, hasToolRequests: false),
            actual: Parse(line: Line.AssistantMessage(at: T(seconds: 1)))?.Kind);
        Assert.Equal(
            expected: LogEventKind.AssistantMessage(isSubagent: false, hasToolRequests: false),
            actual: Parse(line: Line.Event(type: "assistant.message", at: T(seconds: 1), data: new() { ["content"] = "Done" }))?.Kind);
        Assert.Equal(
            expected: LogEventKind.AssistantMessage(isSubagent: true, hasToolRequests: true),
            actual: Parse(line: Line.AssistantMessage(at: T(seconds: 1), toolCalls: ["c2"], subagent: true))?.Kind);
    }

    [Fact]
    public void ToolStarts()
    {
        var bash = Line.ToolStart(
            name: "bash", id: "c1", at: T(seconds: 1), arguments: new() { ["command"] = "dotnet test", ["description"] = " Run tests " }, title: "Bash");
        Assert.Equal(
            expected: new LogEvent(Timestamp: T(seconds: 1), Kind: LogEventKind.ToolStarted(tool: new ToolStart
            {
                CallId = "c1",
                Name = "bash",
                Title = "Bash",
                Description = "Run tests",
            })),
            actual: Parse(line: bash));

        var question = Line.ToolStart(
            name: "ask_user", id: "q", at: T(seconds: 2), arguments: new() { ["question"] = "Which DB?", ["choices"] = new List<string> { "Postgres", " ", "SQLite" } });
        Assert.Equal(
            expected: LogEventKind.ToolStarted(tool: new ToolStart { CallId = "q", Name = "ask_user", Question = "Which DB?", Choices = ["Postgres", "SQLite"] }),
            actual: Parse(line: question)?.Kind);

        var plan = Line.ToolStart(name: "exit_plan_mode", id: "p", at: T(seconds: 3), arguments: new() { ["summary"] = "1. Add tests" });
        Assert.Equal(
            expected: LogEventKind.ToolStarted(tool: new ToolStart { CallId = "p", Name = "exit_plan_mode", PlanSummary = "1. Add tests" }),
            actual: Parse(line: plan)?.Kind);

        // A coordinator relays a question that a session it coordinates waits on, which it doesn't repeat.
        var relay = Line.ToolStart(name: "relay_session_input", id: "r", at: T(seconds: 3), arguments: new()
        {
            ["project_session_id"] = "w-child",
            ["request_id"] = "request",
            ["context"] = " From the checkout session. ",
        });
        Assert.Equal(
            expected: LogEventKind.ToolStarted(tool: new ToolStart
            {
                CallId = "r",
                Name = "relay_session_input",
                RelayedSession = "w-child",
                RelayContext = "From the checkout session.",
            }),
            actual: Parse(line: relay)?.Kind);
        Assert.Equal(
            expected: LogEventKind.ToolStarted(tool: new ToolStart { CallId = "r2", Name = "relay_session_input" }),
            actual: Parse(line: Line.ToolStart(name: "relay_session_input", id: "r2", at: T(seconds: 3)))?.Kind);

        // Only ask_user's arguments are a question for you, and only a relay's name a session.
        var notAQuestion = Line.ToolStart(name: "bash", id: "c2", at: T(seconds: 4), arguments: new() { ["question"] = "rhetorical" });
        Assert.Equal(expected: LogEventKind.ToolStarted(tool: new ToolStart { CallId = "c2", Name = "bash" }), actual: Parse(line: notAQuestion)?.Kind);
        var notARelay = Line.ToolStart(name: "get_session", id: "c4", at: T(seconds: 4), arguments: new() { ["project_session_id"] = "w-child" });
        Assert.Equal(expected: LogEventKind.ToolStarted(tool: new ToolStart { CallId = "c4", Name = "get_session" }), actual: Parse(line: notARelay)?.Kind);

        Assert.Equal(
            expected: LogEventKind.ToolStarted(tool: new ToolStart { CallId = "c3", Name = "view", IsSubagent = true }),
            actual: Parse(line: Line.ToolStart(name: "view", id: "c3", at: T(seconds: 5), subagent: true))?.Kind);
        Assert.Equal(
            expected: LogEventKind.Other,
            actual: Parse(line: Line.Event(type: "tool.execution_start", at: T(seconds: 6), data: new() { ["toolName"] = "bash" }))?.Kind);
    }

    [Fact]
    public void ToolCompletionsUseTheEventsOwnTimestamp()
    {
        Assert.Equal(
            expected: new LogEvent(Timestamp: T(seconds: 7), Kind: LogEventKind.ToolComplete(callId: "c1")),
            actual: Parse(line: Line.ToolComplete(id: "c1", at: T(seconds: 7))));
        // Another key order takes the full decode.
        var reordered = Line.Event(type: "tool.execution_complete", at: T(seconds: 8), data: new() { ["success"] = true, ["toolCallId"] = "c2" });
        Assert.Equal(expected: new LogEvent(Timestamp: T(seconds: 8), Kind: LogEventKind.ToolComplete(callId: "c2")), actual: Parse(line: reordered));
    }

    [Fact]
    public void PermissionRequestsDescribeWhatIsAsked()
    {
        var fromExtension = Line.PermissionRequested(
            id: "r1",
            request: new() { ["kind"] = "extension-permission-access", ["extensionName"] = "project:scs-chat", ["capabilities"] = new List<string> { "register hooks" } },
            at: T(seconds: 1));
        Assert.Equal(
            expected: LogEventKind.PermissionRequested(request: new PermissionRequest
            {
                RequestId = "r1",
                Kind = "extension-permission-access",
                Detail = "project:scs-chat extension wants access",
            }),
            actual: Parse(line: fromExtension)?.Kind);

        var shell = Line.PermissionRequested(
            id: "r2", request: new() { ["kind"] = "shell", ["fullCommandText"] = "rm -rf build", ["intention"] = "Clean the build folder" }, at: T(seconds: 2));
        Assert.Equal(
            expected: LogEventKind.PermissionRequested(request: new PermissionRequest { RequestId = "r2", Kind = "shell", Detail = "Clean the build folder" }),
            actual: Parse(line: shell)?.Kind);

        var commandOnly = Line.PermissionRequested(id: "r3", request: new() { ["kind"] = "shell", ["fullCommandText"] = "rm -rf build" }, at: T(seconds: 3));
        Assert.Equal(
            expected: LogEventKind.PermissionRequested(request: new PermissionRequest { RequestId = "r3", Kind = "shell", Detail = "rm -rf build" }),
            actual: Parse(line: commandOnly)?.Kind);

        var bare = Line.PermissionRequested(id: "r4", request: new() { ["kind"] = "url" }, at: T(seconds: 4));
        Assert.Equal(
            expected: LogEventKind.PermissionRequested(request: new PermissionRequest { RequestId = "r4", Kind = "url" }),
            actual: Parse(line: bare)?.Kind);

        Assert.Equal(expected: LogEventKind.PermissionCompleted(requestId: "r1"), actual: Parse(line: Line.PermissionCompleted(id: "r1", at: T(seconds: 5)))?.Kind);
    }

    [Fact]
    public void OnlyAgentStopHooksMatter()
    {
        Assert.Equal(expected: new LogEvent(Timestamp: T(seconds: 1), Kind: LogEventKind.AgentStop(isSubagent: false)), actual: Parse(line: Line.Hook(hookType: "agentStop", at: T(seconds: 1))));
        Assert.Equal(expected: LogEventKind.AgentStop(isSubagent: true), actual: Parse(line: Line.Hook(hookType: "agentStop", at: T(seconds: 2), agentId: "sub-agent"))?.Kind);
        Assert.Equal(expected: new LogEvent(Timestamp: T(seconds: 3), Kind: LogEventKind.Other), actual: Parse(line: Line.Hook(hookType: "preToolUse", at: T(seconds: 3))));
    }

    [Fact]
    public void SessionLifecycle()
    {
        Assert.Equal(expected: LogEventKind.Abort(reason: "user_initiated"), actual: Parse(line: Line.Abort(at: T(seconds: 1)))?.Kind);
        Assert.Equal(expected: LogEventKind.Abort(reason: "subagent_cancelled"), actual: Parse(line: Line.Abort(at: T(seconds: 1), reason: "subagent_cancelled"))?.Kind);
        Assert.Equal(expected: LogEventKind.SessionError(errorType: "query", message: "Rate limited"), actual: Parse(line: Line.SessionError(message: "Rate limited", at: T(seconds: 2)))?.Kind);
        Assert.Equal(expected: LogEventKind.TaskComplete(summary: "Shipped", success: true), actual: Parse(line: Line.TaskComplete(summary: "Shipped", at: T(seconds: 3)))?.Kind);
        Assert.Equal(expected: new LogEvent(Timestamp: T(seconds: 4), Kind: LogEventKind.SessionShutdown), actual: Parse(line: Line.Shutdown(at: T(seconds: 4))));
        Assert.Equal(expected: LogEventKind.SessionStart, actual: Parse(line: Line.SessionStart(at: T(seconds: 5)))?.Kind);
        Assert.Equal(
            expected: LogEventKind.SessionResume,
            actual: Parse(line: Line.Event(type: "session.resume", at: T(seconds: 6), data: new() { ["resumeTime"] = Iso(date: T(seconds: 6)) }))?.Kind);
        Assert.Equal(expected: new LogEvent(Timestamp: T(seconds: 6), Kind: LogEventKind.SessionResume), actual: Parse(line: Line.Resume(at: T(seconds: 6))));
        // Resumes that keep the previous process's pending work going don't end anything.
        Assert.Equal(expected: new LogEvent(Timestamp: T(seconds: 7), Kind: LogEventKind.Other), actual: Parse(line: Line.Resume(at: T(seconds: 7), keepingPendingWork: true)));
        Assert.Equal(expected: new LogEvent(Timestamp: T(seconds: 8), Kind: LogEventKind.Other), actual: Parse(line: Line.Resume(at: T(seconds: 8), joiningLiveWork: true)));
    }

    [Fact]
    public void IrrelevantAndMalformedLines()
    {
        Assert.Equal(expected: new LogEvent(Timestamp: T(seconds: 1), Kind: LogEventKind.Other), actual: Parse(line: Line.Filler(bytes: 4_000, at: T(seconds: 1))));
        Assert.Equal(expected: LogEventKind.Other, actual: Parse(line: Line.Event(type: "system.message", at: T(seconds: 2), data: new() { ["content"] = "You are…" }))?.Kind);
        foreach (var garbage in new[] { "", " ", "not json", "{}", "[1,2]", "{\"type\":42}", "{\"type\":\"abort\"} trailing" })
        {
            Assert.Null(@object: Parse(line: garbage));
        }
    }

    [Fact]
    public void ToleratesWhitespaceAndOtherKeyOrders()
    {
        Assert.Equal(expected: new LogEvent(Timestamp: T(seconds: 1), Kind: LogEventKind.SessionShutdown), actual: Parse(line: "  " + Line.Shutdown(at: T(seconds: 1)) + "\r\n"));

        var reordered = "{\"timestamp\":\"" + Iso(date: T(seconds: 2)) + "\",\"data\":{\"reason\":\"user_initiated\"},\"type\":\"abort\"}";
        Assert.Equal(expected: new LogEvent(Timestamp: T(seconds: 2), Kind: LogEventKind.Abort(reason: "user_initiated")), actual: Parse(line: reordered));

        var escapedType = "{\"type\":\"user\\u002emessage\",\"data\":{\"content\":\"hi\"},\"id\":\"x\",\"timestamp\":\"" + Iso(date: T(seconds: 3)) + "\",\"parentId\":null}";
        Assert.Equal(expected: new LogEvent(Timestamp: T(seconds: 3), Kind: LogEventKind.UserMessage), actual: Parse(line: escapedType));
    }

    /// The shortcuts that skip decoding mustn't misread lines in an unexpected shape.
    [Fact]
    public void ShortcutsOnlyTrustTheUsualKeyOrder()
    {
        var earlyAgentId = "{\"type\":\"user.message\",\"agentId\":\"sub-agent\",\"data\":{\"content\":\"Explore\"},\"id\":\"x\",\"timestamp\":\"" + Iso(date: T(seconds: 1)) + "\",\"parentId\":null}";
        Assert.Equal(expected: new LogEvent(Timestamp: T(seconds: 1), Kind: LogEventKind.Other), actual: Parse(line: earlyAgentId));
        // An agentId inside the data isn't a subagent's.
        var attachment = Line.Event(
            type: "user.message", at: T(seconds: 2),
            data: new() { ["content"] = "Hi", ["attachments"] = new[] { new Dictionary<string, object?> { ["agentId"] = "a1" } } });
        Assert.Equal(expected: new LogEvent(Timestamp: T(seconds: 2), Kind: LogEventKind.UserMessage), actual: Parse(line: attachment));

        var spacedHook = Line.EventRaw(type: "hook.start", rawData: "{\"hookInvocationId\":\"h\",\"hookType\": \"agentStop\"}", at: T(seconds: 3));
        Assert.Equal(expected: new LogEvent(Timestamp: T(seconds: 3), Kind: LogEventKind.AgentStop(isSubagent: false)), actual: Parse(line: spacedHook));

        // With the event's own timestamp first, the last one in the line is nested.
        var nested = "{\"type\":\"session.shutdown\",\"timestamp\":\"" + Iso(date: T(seconds: 4)) + "\",\"data\":{\"usage\":{\"timestamp\":\"" + Iso(date: T(seconds: 99)) + "\"}},\"id\":\"x\",\"parentId\":null}";
        Assert.Equal(expected: new LogEvent(Timestamp: T(seconds: 4), Kind: LogEventKind.SessionShutdown), actual: Parse(line: nested));
        var inArray = "{\"type\":\"session.info\",\"timestamp\":\"" + Iso(date: T(seconds: 5)) + "\",\"data\":{\"items\":[{\"timestamp\":\"" + Iso(date: T(seconds: 99)) + "\"}]}}";
        Assert.Equal(expected: new LogEvent(Timestamp: T(seconds: 5), Kind: LogEventKind.Other), actual: Parse(line: inArray));
        var braceInString = "{\"type\":\"session.info\",\"data\":{},\"id\":\"x\",\"timestamp\":\"" + Iso(date: T(seconds: 6)) + "\",\"parentId\":\"a}b\"}";
        Assert.Equal(expected: new LogEvent(Timestamp: T(seconds: 6), Kind: LogEventKind.Other), actual: Parse(line: braceInString));
    }

    /// JSON.stringify writes half of an emoji that was cut off as a lone escape, which .NET can't make a string of: the
    /// line is skipped, as the Mac skips a line it can't decode, rather than stopping the reader.
    [Fact]
    public void SkipsALineWithHalfAnEmoji()
    {
        var abort = "{\"type\":\"abort\",\"data\":{\"reason\":\"\\ud83d\"},\"id\":\"x\",\"timestamp\":\"" + Iso(date: T(seconds: 1)) + "\",\"parentId\":null}";
        Assert.Null(@object: Parse(line: abort));
        var question = Line.EventRaw(
            type: "tool.execution_start",
            rawData: "{\"toolCallId\":\"t1\",\"toolName\":\"ask_user\",\"arguments\":{\"question\":\"Ship it? \\ud83d\"}}",
            at: T(seconds: 2));
        Assert.Null(@object: Parse(line: question));
        // A whole emoji is fine.
        var whole = "{\"type\":\"abort\",\"data\":{\"reason\":\"\\ud83d\\ude80\"},\"id\":\"x\",\"timestamp\":\"" + Iso(date: T(seconds: 3)) + "\",\"parentId\":null}";
        Assert.Equal(expected: new LogEvent(Timestamp: T(seconds: 3), Kind: LogEventKind.Abort(reason: "\U0001F680")), actual: Parse(line: whole));
    }

    static LogEvent? Parse(string line) => EventLineParser.Parse(line: line);
}
