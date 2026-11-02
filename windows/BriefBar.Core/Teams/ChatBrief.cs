using System.Globalization;

namespace BriefBar.Core.Teams;

/// A brief's line for an unread chat, in BriefBar's own words: who wrote and how many messages, and, while Show Message
/// Previews is on, what the newest one says. The Mac's `SummaryPrompt.briefSentence`.
public static class ChatBrief
{
    /// "Priya Shah sent you 2 messages: “Can you look at the notes?”", "Launch crew: 3 new messages, the newest from
    /// Jordan Lee." Without `showsText`, no message text at all.
    public static string Sentence(ConversationSummary conversation, bool showsText)
    {
        ArgumentNullException.ThrowIfNull(argument: conversation);
        var count = conversation.Unread.Count;
        var newest = conversation.Shown;
        string sentence;
        if (conversation.Kind == ConversationKind.OneOnOne)
        {
            sentence = conversation.Title + " sent you " + (count == 1 ? "a message" : Count(count: count) + " messages");
        }
        else
        {
            sentence = conversation.Title + ": " + (count == 1 ? "a new message" : Count(count: count) + " new messages");
            if (newest?.Sender is { Length: > 0 } sender)
            {
                sentence += count == 1 ? " from " + sender : ", the newest from " + sender;
            }
        }
        return showsText && newest?.Text is { Length: > 0 } text ? sentence + ": “" + Clip(text: text) + "”" : sentence + ".";
    }

    /// One line of at most `limit` characters as people see them.
    public static string Clip(string text, int limit = 120)
    {
        ArgumentNullException.ThrowIfNull(argument: text);
        var line = PlainText.SingleLine(text: text);
        var info = new StringInfo(value: line);
        return info.LengthInTextElements > limit
            ? info.SubstringByTextElements(startingTextElement: 0, lengthInTextElements: limit - 1).TrimEnd() + "…"
            : line;
    }

    static string Count(int count) => count.ToString(provider: CultureInfo.InvariantCulture);
}
