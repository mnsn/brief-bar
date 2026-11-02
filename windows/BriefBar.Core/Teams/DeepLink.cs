using System.Globalization;

namespace BriefBar.Core.Teams;

/// Links that open a chat in the Teams app. The Mac's `DeepLink`.
public static class DeepLink
{
    /// `{"contextType":"chat"}`, percent-encoded.
    const string ChatContext = "%7B%22contextType%22%3A%22chat%22%7D";

    /// Teams' documented link to a message in a chat (the form "Copy link" gives), with the app's `msteams:` scheme so no
    /// browser is involved. Teams opens the chat at that message.
    public static Uri? Message(string conversationId, long messageId) =>
        ConversationIds.IsValid(id: conversationId) && messageId > 0
            ? new Uri(uriString: "msteams:/l/message/" + Uri.EscapeDataString(stringToEscape: conversationId) + "/"
                + messageId.ToString(provider: CultureInfo.InvariantCulture) + "?context=" + ChatContext)
            : null;

    /// Opens a chat without a message. Undocumented, so only used when there's no message ID.
    public static Uri? Chat(string conversationId) =>
        ConversationIds.IsValid(id: conversationId)
            ? new Uri(uriString: "msteams:/l/chat/" + Uri.EscapeDataString(stringToEscape: conversationId) + "/0")
            : null;

    /// A chat's link: at its oldest unread message, else its newest, else the chat itself.
    public static Uri? To(ConversationSummary conversation)
    {
        ArgumentNullException.ThrowIfNull(argument: conversation);
        var message = conversation.IsUnread ? conversation.Unread[0].Id : conversation.Latest?.Id;
        return (message is { } id ? Message(conversationId: conversation.Id, messageId: id) : null) ?? Chat(conversationId: conversation.Id);
    }
}
