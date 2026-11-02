using System.Text.RegularExpressions;

namespace BriefBar.Core.Teams;

/// Teams' conversation IDs, and the kind of chat each is. The Mac's `ConversationID` and `ConversationKind(chatID:)`.
public static partial class ConversationIds
{
    /// Teams thread IDs look like `19:<id>@<domain>`, for example `19:…@unq.gbl.spaces` or `19:…@thread.v2`.
    public static bool IsValid(string? id) => id is not null && ThreadId().IsMatch(input: id);

    /// The kind of chat a conversation is, from its record's `type` and its ID; null for one that isn't a chat, such as
    /// a channel ("Topic" or "Space"), a Viva Engage community or one of Teams' own streams. Teams' `type` decides: "Chat"
    /// is a 1:1 chat when its ID ends in `@unq.gbl.spaces`, and a group chat otherwise; "Meeting" is a meeting's chat.
    /// A record without a type is told by its ID, as the Mac tells a notification's chat.
    public static ConversationKind? Kind(string? type, string id)
    {
        ArgumentNullException.ThrowIfNull(argument: id);
        var isOneOnOne = id.EndsWith(value: "@unq.gbl.spaces", comparisonType: StringComparison.OrdinalIgnoreCase);
        return type switch
        {
            "Chat" => isOneOnOne ? ConversationKind.OneOnOne : ConversationKind.Group,
            "Meeting" => ConversationKind.Meeting,
            null or "" when isOneOnOne => ConversationKind.OneOnOne,
            null or "" when id.StartsWith(value: "19:meeting_", comparisonType: StringComparison.OrdinalIgnoreCase) => ConversationKind.Meeting,
            null or "" when id.EndsWith(value: "@thread.v2", comparisonType: StringComparison.OrdinalIgnoreCase) => ConversationKind.Group,
            _ => null,
        };
    }

    /// The section that lists a kind of chat.
    public static ChatGroup Group(ConversationKind kind) => kind == ConversationKind.OneOnOne ? ChatGroup.Chats : ChatGroup.Groups;

    [GeneratedRegex(pattern: @"^19:[^\s""'<>{}\[\]()|\\,;&?#/]+@[A-Za-z0-9.\-]+$", options: RegexOptions.CultureInvariant)]
    private static partial Regex ThreadId();
}
