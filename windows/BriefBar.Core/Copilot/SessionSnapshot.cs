using System.Globalization;

namespace BriefBar.Core.Copilot;

/// A session as its list shows it: its group, why it's there, and since when. The Mac's `SessionSnapshot`.
public sealed record SessionSnapshot
{
    public required string Id { get; init; }

    public required string Name { get; init; }

    public string? ProjectName { get; init; }

    public string? Branch { get; init; }

    public bool IsChat { get; init; }

    public string? Mode { get; init; }

    public DisplayPhase Phase { get; init; }

    public StatusReason Reason { get; init; }

    public required string Headline { get; init; }

    /// Its question, plan summary, error message or current step, depending on `Reason`.
    public string? Detail { get; init; }

    public ValueList<string> Choices { get; init; } = ValueList<string>.Empty;

    /// When the session entered its current state.
    public DateTimeOffset? Since { get; init; }

    /// How full the session's context window is, when the app has measured it.
    public ContextUsage? ContextUsage { get; init; }

    /// The session that asks you this one's question or plan for it, which is where you answer it (`Relayed`).
    public RelatedSession? AnswerIn { get; init; }

    /// The sessions whose questions or plans this one asks you for, the longest-waiting first.
    public ValueList<RelatedSession> AsksFor { get; init; } = ValueList<RelatedSession>.Empty;

    /// The listed session that started this one, which the app's sidebar nests it under (`SessionNesting`).
    public RelatedSession? Parent { get; init; }

    /// How far it's nested under the session that started it, within its group: 0 when it isn't.
    public int Depth { get; init; }

    public string DisplayName => Name.Length > 0 ? Name : IsChat ? "Untitled chat" : "Untitled session";

    /// Ended sessions keep their last state for context, even once they're no longer highlighted.
    public bool IsEnded => Reason is StatusReason.Finished or StatusReason.Interrupted or StatusReason.Failed or StatusReason.Unresponsive;

    /// A brief's line in BriefBar's own words: what the session waits for you on, or how it ended.
    public string BriefSentence
    {
        get
        {
            var name = "“" + DisplayName + "”";
            var detail = Detail is null ? null : Clip(text: Detail) is { Length: > 0 } clipped ? clipped : null;
            var sentence = Reason switch
            {
                StatusReason.Question => detail is null ? name + " is waiting for your answer" : name + " asks: " + detail,
                StatusReason.PlanApproval => name + " has a plan for you to review" + (detail is null ? string.Empty : ": " + detail),
                StatusReason.Permission => name + " needs your permission" + (detail is null ? string.Empty : " to run " + detail),
                StatusReason.Working or StatusReason.Starting => name + " is working",
                StatusReason.Relayed => name + " waits for your answer in " + (AnswerIn is { } answerIn ? "“" + answerIn.Name + "”" : "another session"),
                StatusReason.Finished => name + " finished",
                StatusReason.Interrupted => name + " was interrupted",
                StatusReason.Failed => name + " stopped with an error" + (detail is null ? string.Empty : ": " + detail),
                StatusReason.Unresponsive => name + " stopped responding",
                StatusReason.Idle => name + " is idle",
                _ => throw new InvalidOperationException(message: "Not a reason."),
            };
            return sentence.Length > 0 && sentence[^1] is '.' or '?' or '!' or '…' ? sentence : sentence + ".";
        }
    }

    /// One line of at most `limit` characters.
    internal static string Clip(string text, int limit = 140)
    {
        var line = string.Join(
            separator: ' ',
            value: text.Split(separator: ['\n', '\r', '\u2028', '\u2029', '\u0085'], options: StringSplitOptions.RemoveEmptyEntries))
            .Trim(trimChars: [' ', '\t']);
        var info = new StringInfo(value: line);
        return info.LengthInTextElements > limit
            ? info.SubstringByTextElements(startingTextElement: 0, lengthInTextElements: limit - 1).Trim(trimChars: [' ', '\t']) + "…"
            : line;
    }
}
