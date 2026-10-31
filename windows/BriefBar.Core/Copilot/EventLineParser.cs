using System.Text;
using System.Text.Json;

namespace BriefBar.Core.Copilot;

/// Parses one `events.jsonl` line into a `LogEvent`.
///
/// Lines can be megabytes long (tool output, file contents), so irrelevant event types are classified from their leading
/// `{"type":"…"` bytes, and only state-relevant ones are decoded in full. The Mac's `EventLineParser`.
public static class EventLineParser
{
    /// Generous room for the top-level members after the timestamp (`,"parentId":"…"}`).
    const int MaxTimestampSuffix = 512;

    /// Types whose payload isn't needed: the type and the trailing timestamp suffice.
    static readonly Dictionary<string, LogEventKind> headerOnlyTypes = new(comparer: StringComparer.Ordinal)
    {
        ["user.message"] = LogEventKind.UserMessage,
        ["session.start"] = LogEventKind.SessionStart,
        ["session.shutdown"] = LogEventKind.SessionShutdown,
    };

    static readonly HashSet<string> decodedTypes = new(
        collection:
        [
            "assistant.turn_start", "assistant.turn_end", "assistant.message",
            "tool.execution_start", "tool.execution_complete",
            "permission.requested", "permission.completed",
            "hook.start", "abort", "session.error", "session.resume", "session.task_complete",
        ],
        comparer: StringComparer.Ordinal);

    static readonly string[] permissionDetailKeys =
        ["intention", "fullCommandText", "commandText", "command", "toolTitle", "toolName", "serverName", "fileName", "path", "url"];

    static ReadOnlySpan<byte> TypePrefix => "{\"type\":\""u8;

    static ReadOnlySpan<byte> TimestampKey => "\"timestamp\":\""u8;

    static ReadOnlySpan<byte> AgentIdKey => "\"agentId\""u8;

    static ReadOnlySpan<byte> AgentStopNeedle => "agentStop"u8;

    static ReadOnlySpan<byte> ToolCompletePrefix => "{\"type\":\"tool.execution_complete\",\"data\":{\"toolCallId\":\""u8;

    static ReadOnlySpan<byte> Whitespace => " \t\r\n"u8;

    public static LogEvent? Parse(string line)
    {
        ArgumentNullException.ThrowIfNull(argument: line);
        return Parse(raw: Encoding.UTF8.GetBytes(s: line));
    }

    public static LogEvent? Parse(ReadOnlySpan<byte> raw)
    {
        var line = raw.Trim(trimElements: Whitespace);
        if (line.Length < 2)
        {
            return null;
        }

        // The shortcuts rely on the CLI's key order; a line that doesn't follow it is decoded in full.
        if (FastType(line: line) is { } type && TailTimestamp(line: line) is { } timestamp)
        {
            if (headerOnlyTypes.TryGetValue(key: type, value: out var kind))
            {
                // Prompts the main agent sends to subagents carry a top-level agentId.
                if (kind.Type != LogEventType.UserMessage || line.IndexOf(value: AgentIdKey) < 0)
                {
                    return new LogEvent(Timestamp: timestamp, Kind: kind);
                }
            }
            else if (type == "tool.execution_complete" && FastToolCompleteId(line: line) is { } callId)
            {
                return new LogEvent(Timestamp: timestamp, Kind: LogEventKind.ToolComplete(callId: callId));
            }
            else if (!decodedTypes.Contains(item: type) || (type == "hook.start" && line.IndexOf(value: AgentStopNeedle) < 0))
            {
                return new LogEvent(Timestamp: timestamp, Kind: LogEventKind.Other);
            }
        }
        return Decoded(line: line);
    }

    /// Top-level keys are ordered `type, data, [agentId], id, timestamp, parentId`, so the last `"timestamp":"` is
    /// normally the event's own. It only counts when no more than flat top-level members follow it; otherwise it's
    /// nested in `data`, and the line needs a full decode.
    internal static DateTimeOffset? TailTimestamp(ReadOnlySpan<byte> line)
    {
        var keyStart = line.LastIndexOf(value: TimestampKey);
        if (keyStart < 0)
        {
            return null;
        }
        var valueStart = keyStart + TimestampKey.Length;
        var end = valueStart;
        while (end < line.Length && line[end] != (byte)'"')
        {
            end++;
        }
        if (end >= line.Length || end <= valueStart || !EndsFlatObject(line: line, start: end + 1))
        {
            return null;
        }
        return Timestamp.Parse(bytes: line[valueStart..end]);
    }

    /// The event a whole line holds, or null for one that isn't a JSON object with a type.
    static LogEvent? Decoded(ReadOnlySpan<byte> line)
    {
        JsonDocument document;
        try
        {
            var reader = new Utf8JsonReader(jsonData: line, options: new JsonReaderOptions { MaxDepth = 1_024 });
            document = JsonDocument.ParseValue(reader: ref reader);
            if (reader.BytesConsumed != line.Length)
            {
                document.Dispose();
                return null;
            }
        }
        catch (JsonException)
        {
            return null;
        }
        using (document)
        {
            try
            {
                return document.RootElement.ValueKind == JsonValueKind.Object ? EventFrom(root: document.RootElement) : null;
            }
            catch (InvalidOperationException)
            {
                // Text .NET can't make a string of, as JSON.stringify writes for half of an emoji that was cut off: a
                // line that can't be read, as on the Mac.
                return null;
            }
        }
    }

    static LogEvent? EventFrom(JsonElement root)
    {
        if (Member(element: root, name: "type") is not { ValueKind: JsonValueKind.String } typeElement)
        {
            return null;
        }
        var type = typeElement.GetString();
        var data = Member(element: root, name: "data") is { ValueKind: JsonValueKind.Object } found ? found : (JsonElement?)null;
        var timestamp = Member(element: root, name: "timestamp") is { ValueKind: JsonValueKind.String } stamp
            ? Timestamp.Parse(text: stamp.GetString()!)
            : null;
        var isSubagent = NonEmpty(element: Member(element: data, name: "parentToolCallId")) is not null
            || NonEmpty(element: Member(element: root, name: "agentId")) is not null;

        var kind = type switch
        {
            "user.message" => isSubagent ? LogEventKind.Other : LogEventKind.UserMessage,
            "assistant.turn_start" => LogEventKind.TurnStart(isSubagent: isSubagent),
            "assistant.turn_end" => LogEventKind.TurnEnd(isSubagent: isSubagent),
            "assistant.message" => LogEventKind.AssistantMessage(
                isSubagent: isSubagent,
                hasToolRequests: Member(element: data, name: "toolRequests") is { ValueKind: JsonValueKind.Array } requests
                    && requests.GetArrayLength() > 0),
            "tool.execution_start" => ToolStartKind(data: data, isSubagent: isSubagent),
            "tool.execution_complete" => NonEmpty(element: Member(element: data, name: "toolCallId")) is { } callId
                ? LogEventKind.ToolComplete(callId: callId)
                : LogEventKind.Other,
            "permission.requested" => PermissionKind(data: data),
            "permission.completed" => NonEmpty(element: Member(element: data, name: "requestId")) is { } requestId
                ? LogEventKind.PermissionCompleted(requestId: requestId)
                : LogEventKind.Other,
            "hook.start" => Member(element: data, name: "hookType") is { ValueKind: JsonValueKind.String } hook && hook.GetString() == "agentStop"
                ? LogEventKind.AgentStop(isSubagent: isSubagent)
                : LogEventKind.Other,
            "abort" => LogEventKind.Abort(reason: NonEmpty(element: Member(element: data, name: "reason"))),
            "session.error" => LogEventKind.SessionError(
                errorType: NonEmpty(element: Member(element: data, name: "errorType")),
                message: NonEmpty(element: Member(element: data, name: "message"))),
            "session.start" => LogEventKind.SessionStart,
            // Unless the resume keeps them waiting or joins live work, the CLI marks the previous process's pending tool
            // calls and permission requests as interrupted.
            "session.resume" => IsTrue(element: Member(element: data, name: "continuePendingWork"))
                || IsTrue(element: Member(element: data, name: "sessionWasActive"))
                    ? LogEventKind.Other
                    : LogEventKind.SessionResume,
            "session.shutdown" => LogEventKind.SessionShutdown,
            "session.task_complete" => LogEventKind.TaskComplete(
                summary: NonEmpty(element: Member(element: data, name: "summary")),
                success: Member(element: data, name: "success") is { ValueKind: JsonValueKind.True or JsonValueKind.False } success
                    ? success.GetBoolean()
                    : null),
            _ => LogEventKind.Other,
        };
        return new LogEvent(Timestamp: timestamp, Kind: kind);
    }

    static LogEventKind ToolStartKind(JsonElement? data, bool isSubagent)
    {
        if (NonEmpty(element: Member(element: data, name: "toolCallId")) is not { } callId)
        {
            return LogEventKind.Other;
        }
        var name = Member(element: data, name: "toolName") is { ValueKind: JsonValueKind.String } named ? named.GetString()! : string.Empty;
        var arguments = Member(element: data, name: "arguments") is { ValueKind: JsonValueKind.Object } given ? given : (JsonElement?)null;
        var relays = name == "relay_session_input";
        var asks = name == "ask_user";
        return LogEventKind.ToolStarted(tool: new ToolStart
        {
            CallId = callId,
            Name = name,
            IsSubagent = isSubagent,
            Title = NonEmpty(element: Member(element: data, name: "toolTitle")),
            Description = NonEmpty(element: Member(element: arguments, name: "description")),
            Question = asks ? NonEmpty(element: Member(element: arguments, name: "question")) : null,
            Choices = asks ? StringArray(element: Member(element: arguments, name: "choices")) : ValueList<string>.Empty,
            PlanSummary = name == "exit_plan_mode" ? NonEmpty(element: Member(element: arguments, name: "summary")) : null,
            RelayedSession = relays ? NonEmpty(element: Member(element: arguments, name: "project_session_id")) : null,
            RelayContext = relays ? NonEmpty(element: Member(element: arguments, name: "context")) : null,
        });
    }

    static LogEventKind PermissionKind(JsonElement? data)
    {
        if (NonEmpty(element: Member(element: data, name: "requestId")) is not { } requestId)
        {
            return LogEventKind.Other;
        }
        var request = Member(element: data, name: "permissionRequest") is { ValueKind: JsonValueKind.Object } found ? found : (JsonElement?)null;
        return LogEventKind.PermissionRequested(request: new PermissionRequest
        {
            RequestId = requestId,
            Kind = NonEmpty(element: Member(element: request, name: "kind")),
            Detail = PermissionDetail(request: request),
        });
    }

    static string? PermissionDetail(JsonElement? request)
    {
        if (NonEmpty(element: Member(element: request, name: "extensionName")) is { } extensionName)
        {
            return extensionName + " extension wants access";
        }
        foreach (var key in permissionDetailKeys)
        {
            if (NonEmpty(element: Member(element: request, name: key)) is { } value)
            {
                return value;
            }
        }
        return null;
    }

    /// `name` of an object, or null when it isn't one or doesn't have it.
    static JsonElement? Member(JsonElement? element, string name) =>
        element is { ValueKind: JsonValueKind.Object } found && found.TryGetProperty(propertyName: name, value: out var member) ? member : null;

    /// A string, trimmed, or null for anything else or nothing but whitespace.
    static string? NonEmpty(JsonElement? element)
    {
        if (element is not { ValueKind: JsonValueKind.String } text)
        {
            return null;
        }
        var trimmed = text.GetString()!.Trim();
        return trimmed.Length == 0 ? null : trimmed;
    }

    static bool IsTrue(JsonElement? element) => element is { ValueKind: JsonValueKind.True };

    static ValueList<string> StringArray(JsonElement? element)
    {
        if (element is not { ValueKind: JsonValueKind.Array } array)
        {
            return ValueList<string>.Empty;
        }
        var strings = new List<string>();
        foreach (var item in array.EnumerateArray())
        {
            if (NonEmpty(element: item) is { } text)
            {
                strings.Add(item: text);
            }
        }
        return strings.Count == 0 ? ValueList<string>.Empty : new ValueList<string>(items: strings);
    }

    static bool HasPrefix(ReadOnlySpan<byte> line, ReadOnlySpan<byte> prefix) => line.Length > prefix.Length && line.StartsWith(value: prefix);

    /// A JSON string's value starting at `start`, up to its closing quote; null if it has escapes or is empty.
    static string? SimpleString(ReadOnlySpan<byte> line, int start)
    {
        var end = start;
        while (end < line.Length)
        {
            var value = line[end];
            if (value == (byte)'"')
            {
                break;
            }
            if (value == (byte)'\\')
            {
                return null;
            }
            end++;
        }
        return end < line.Length && end > start ? Encoding.UTF8.GetString(bytes: line[start..end]) : null;
    }

    static string? FastType(ReadOnlySpan<byte> line) =>
        HasPrefix(line: line, prefix: TypePrefix) ? SimpleString(line: line, start: TypePrefix.Length) : null;

    static string? FastToolCompleteId(ReadOnlySpan<byte> line) =>
        HasPrefix(line: line, prefix: ToolCompletePrefix) ? SimpleString(line: line, start: ToolCompletePrefix.Length) : null;

    /// Whether `line[start..]` closes the top-level object: no nested objects or arrays, and the only closing brace
    /// outside strings is the line's last byte.
    static bool EndsFlatObject(ReadOnlySpan<byte> line, int start)
    {
        if (line.Length - start > MaxTimestampSuffix)
        {
            return false;
        }
        var inString = false;
        for (var index = start; index < line.Length; index++)
        {
            var value = line[index];
            if (inString)
            {
                if (value == (byte)'\\')
                {
                    index++;
                }
                else if (value == (byte)'"')
                {
                    inString = false;
                }
                continue;
            }
            switch (value)
            {
                case (byte)'"':
                    inString = true;
                    break;
                case (byte)'{' or (byte)'[' or (byte)']':
                    return false;
                case (byte)'}':
                    return index == line.Length - 1;
                default:
                    break;
            }
        }
        return false;
    }
}
