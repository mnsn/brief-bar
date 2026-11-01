using System.Collections;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using BriefBar.Core.Copilot;
using static BriefBar.Core.Tests.Copilot.TestTimes;

namespace BriefBar.Core.Tests.Copilot;

/// Builds `events.jsonl` lines shaped like the Copilot CLI's, with made-up content, including its top-level key order
/// (`type, data, [agentId], id, timestamp, parentId`) that the parser's shortcuts rely on. The Swift tests' `Line`.
internal static class Line
{
    static readonly JsonWriterOptions writing = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    public static string Event(string type, DateTimeOffset at, Dictionary<string, object?>? data = null, string? agentId = null) =>
        EventRaw(type: type, rawData: Json(value: data ?? []), at: at, agentId: agentId);

    public static string EventRaw(string type, string rawData, DateTimeOffset at, string? agentId = null)
    {
        var line = "{\"type\":\"" + type + "\",\"data\":" + rawData;
        if (agentId is not null)
        {
            line += ",\"agentId\":\"" + agentId + "\"";
        }
        return line + ",\"id\":\"" + Guid.NewGuid().ToString() + "\",\"timestamp\":\"" + Iso(date: at) + "\",\"parentId\":null}";
    }

    /// JSON with sorted keys, as Swift's `JSONSerialization` writes it with `.sortedKeys`.
    public static string Json(object? value)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(utf8Json: stream, options: writing))
        {
            Write(writer: writer, value: value);
        }
        return Encoding.UTF8.GetString(bytes: stream.ToArray());
    }

    public static string SessionStart(DateTimeOffset at) =>
        Event(type: "session.start", at: at, data: new() { ["sessionId"] = "session", ["version"] = 1, ["producer"] = "copilot-agent" });

    public static string UserMessage(DateTimeOffset at, string content = "Please fix the bug", string? agentId = null) =>
        Event(type: "user.message", at: at, data: new() { ["content"] = content }, agentId: agentId);

    public static string TurnStart(DateTimeOffset at, bool subagent = false) =>
        Event(type: "assistant.turn_start", at: at, data: Tagged(data: new() { ["turnId"] = "0" }, subagent: subagent));

    public static string TurnEnd(DateTimeOffset at, bool subagent = false) =>
        Event(type: "assistant.turn_end", at: at, data: Tagged(data: new() { ["turnId"] = "0" }, subagent: subagent));

    public static string AssistantMessage(DateTimeOffset at, string[]? toolCalls = null, bool subagent = false)
    {
        var requests = (toolCalls ?? []).Select(selector: id => (object?)new Dictionary<string, object?>
        {
            ["toolCallId"] = id,
            ["name"] = "bash",
            ["arguments"] = new Dictionary<string, object?>(),
            ["type"] = "function",
        }).ToList();
        var data = new Dictionary<string, object?>
        {
            ["messageId"] = Guid.NewGuid().ToString(),
            ["content"] = "Working on it",
            ["toolRequests"] = requests,
        };
        return Event(type: "assistant.message", at: at, data: Tagged(data: data, subagent: subagent));
    }

    /// A message from the agent with no tool calls: to you, or, from a subagent, to the agent that started it.
    public static string Message(string content, DateTimeOffset at, bool subagent = false, string? agentId = null) =>
        Event(
            type: "assistant.message",
            at: at,
            data: Tagged(data: new() { ["messageId"] = Guid.NewGuid().ToString(), ["content"] = content, ["toolRequests"] = new List<object?>() }, subagent: subagent),
            agentId: agentId);

    public static string ToolStart(
        string name, string id, DateTimeOffset at, Dictionary<string, object?>? arguments = null, string? title = null, bool subagent = false)
    {
        var data = new Dictionary<string, object?>
        {
            ["toolCallId"] = id,
            ["toolName"] = name,
            ["arguments"] = arguments ?? [],
            ["turnId"] = "0",
        };
        if (title is not null)
        {
            data["toolTitle"] = title;
        }
        return Event(type: "tool.execution_start", at: at, data: Tagged(data: data, subagent: subagent));
    }

    /// `toolCallId` first, as the CLI writes it, with a nested timestamp that mustn't be taken for the event's own.
    public static string ToolComplete(string id, DateTimeOffset at) => EventRaw(
        type: "tool.execution_complete",
        rawData: "{\"toolCallId\":\"" + id + "\",\"success\":true,\"result\":{\"content\":\"ok\",\"timestamp\":\"2001-01-01T00:00:00.000Z\"}}",
        at: at);

    public static string PermissionRequested(string id, Dictionary<string, object?> request, DateTimeOffset at) =>
        Event(type: "permission.requested", at: at, data: new() { ["requestId"] = id, ["permissionRequest"] = request, ["agentMode"] = "interactive" });

    public static string PermissionCompleted(string id, DateTimeOffset at) =>
        Event(type: "permission.completed", at: at, data: new() { ["requestId"] = id, ["result"] = new Dictionary<string, object?> { ["kind"] = "approved" } });

    public static string Hook(string hookType, DateTimeOffset at, string? agentId = null) => Event(
        type: "hook.start",
        at: at,
        data: new()
        {
            ["hookInvocationId"] = "hook",
            ["hookType"] = hookType,
            ["input"] = new Dictionary<string, object?> { ["stopReason"] = "end_turn", ["timestamp"] = 1_791_110_203_986L },
        },
        agentId: agentId);

    public static string Abort(DateTimeOffset at, string reason = "user_initiated") =>
        Event(type: "abort", at: at, data: new() { ["reason"] = reason });

    public static string SessionError(string message, DateTimeOffset at) =>
        Event(type: "session.error", at: at, data: new() { ["errorType"] = "query", ["message"] = message });

    public static string TaskComplete(string summary, DateTimeOffset at) =>
        Event(type: "session.task_complete", at: at, data: new() { ["summary"] = summary, ["success"] = true });

    public static string Shutdown(DateTimeOffset at) => Event(type: "session.shutdown", at: at, data: new() { ["shutdownType"] = "routine" });

    /// A cold resume by default. Otherwise it keeps the previous process's pending work waiting, or joins a turn another
    /// client is running.
    public static string Resume(DateTimeOffset at, bool keepingPendingWork = false, bool joiningLiveWork = false)
    {
        var data = new Dictionary<string, object?>
        {
            ["resumeTime"] = Iso(date: at),
            ["eventCount"] = 12,
            ["alreadyInUse"] = joiningLiveWork,
            ["sessionWasActive"] = joiningLiveWork,
        };
        if (keepingPendingWork)
        {
            data["continuePendingWork"] = true;
        }
        return Event(type: "session.resume", at: at, data: data);
    }

    /// An irrelevant event of roughly `bytes` length, standing in for big tool output or images.
    public static string Filler(int bytes, DateTimeOffset at) =>
        Event(type: "session.binary_asset", at: at, data: new() { ["data"] = new string(c: 'A', count: Math.Max(val1: 0, val2: bytes - 160)) });

    /// Replays lines through the parser and reducer, as `EventLogReader` does.
    public static SessionLogState LogState(params IEnumerable<string> lines)
    {
        var state = new SessionLogState();
        foreach (var line in lines)
        {
            if (EventLineParser.Parse(line: line) is { } parsed)
            {
                state.Apply(logEvent: parsed);
            }
        }
        return state;
    }

    static Dictionary<string, object?> Tagged(Dictionary<string, object?> data, bool subagent)
    {
        if (subagent)
        {
            data["parentToolCallId"] = "toolu_parent";
        }
        return data;
    }

    static void Write(Utf8JsonWriter writer, object? value)
    {
        switch (value)
        {
            case null:
                writer.WriteNullValue();
                break;
            case string text:
                writer.WriteStringValue(value: text);
                break;
            case bool flag:
                writer.WriteBooleanValue(value: flag);
                break;
            case int number:
                writer.WriteNumberValue(value: number);
                break;
            case long number:
                writer.WriteNumberValue(value: number);
                break;
            case double number:
                writer.WriteNumberValue(value: number);
                break;
            case IDictionary<string, object?> map:
                writer.WriteStartObject();
                foreach (var (key, item) in map.OrderBy(keySelector: pair => pair.Key, comparer: StringComparer.Ordinal))
                {
                    writer.WritePropertyName(propertyName: key);
                    Write(writer: writer, value: item);
                }
                writer.WriteEndObject();
                break;
            case IEnumerable items:
                writer.WriteStartArray();
                foreach (var item in items)
                {
                    Write(writer: writer, value: item);
                }
                writer.WriteEndArray();
                break;
            default:
                throw new ArgumentException(message: "Not a JSON value.", paramName: nameof(value));
        }
    }
}
