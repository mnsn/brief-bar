namespace BriefBar.Core.Copilot;

/// Reads a line of `events.jsonl`, without its newline.
public delegate void LogLineAction(ReadOnlySpan<byte> line);
