namespace BriefBar.Core.Copilot;

/// The part of a line of a Copilot session's `events.jsonl` that matters for status tracking. The Mac's `LogEvent`.
public sealed record LogEvent(DateTimeOffset? Timestamp, LogEventKind Kind);
