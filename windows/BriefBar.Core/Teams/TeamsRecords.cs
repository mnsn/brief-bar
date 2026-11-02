using System.Globalization;
using BriefBar.Core.ChromiumIndexedDB;

namespace BriefBar.Core.Teams;

/// Reads Teams' own records: a conversation, from `conversation-manager`'s `conversations`, and the messages a reply chain
/// holds, from `replychain-manager`'s `replychains-2`. Of a conversation it keeps its ID, kind, names, read marker, newest
/// message, whether it's muted and whether it's marked unread; the rest of the record is read only to get past it.
internal static class TeamsRecords
{
    /// The chat a conversation record holds, or null for one that isn't a chat, such as a channel. `recordKey` is the
    /// record's key, which is its ID; `userId` tells your messages apart. Throws `FormatErrorException` for a conversation
    /// BriefBar doesn't know, as after an update to Teams, or with a read marker it can't read, so that it counts as one
    /// that couldn't be read rather than one that isn't a chat, or one never read.
    public static TeamsChat? Chat(JSValue value, string? recordKey, string userId)
    {
        ArgumentNullException.ThrowIfNull(argument: value);
        var id = value["id"]?.AsString ?? recordKey;
        var type = value["type"]?.AsString;
        if (id is null)
        {
            throw FormatErrorException.Unsupported(what: "conversation without an ID");
        }
        if (ConversationIds.IsNotChat(type: type, id: id))
        {
            return null;
        }
        if (!ConversationIds.IsValid(id: id) || ConversationIds.Kind(type: type, id: id) is not { } kind)
        {
            throw FormatErrorException.Unsupported(what: "conversation type");
        }
        var properties = value["properties"];
        var thread = value["threadProperties"];
        var newest = value["lastMessage"] is { Kind: JSValueKind.PlainObject } last
            && Message(value: last, conversationId: id, userId: userId, isFromMe: Flag(value: thread?["isLastMessageFromMe"])) is { } named
                ? WithDeletion(value: last, message: named)
                : null;
        var topic = Text(value: thread?["topic"]);
        var shortTitle = Text(value: value["chatTitle"]?["shortTitle"]);
        var longTitle = Text(value: value["chatTitle"]?["longTitle"]);
        var title = (kind == ConversationKind.OneOnOne ? null : topic)
            ?? shortTitle
            ?? longTitle
            ?? (kind == ConversationKind.OneOnOne && newest is { IsFromMe: false } ? newest.Sender : null)
            ?? KindTitle(kind: kind);
        return new TeamsChat(
            Id: id,
            Kind: kind,
            Title: title,
            FullTitle: longTitle is not null && longTitle != title ? longTitle : null,
            Marker: Marker(value: properties?["consumptionhorizon"]),
            Newest: newest,
            IsMuted: Flag(value: properties?["alerts"]) == false,
            // Mark as unread leaves the read marker as it was: it sets this, in the same form, to a message before the
            // newest, and opening the chat sets it back to 0.
            MarkedUnread: ReadMarker.Parse(consumptionHorizon: properties?["consumptionHorizonBookmark"]?.AsString));
    }

    /// Whether a conversation record's read marker field (`properties.consumptionhorizon`) is in its form, read or not.
    public static bool HasHorizon(JSValue value)
    {
        ArgumentNullException.ThrowIfNull(argument: value);
        return ReadMarker.IsHorizon(consumptionHorizon: value["properties"]?["consumptionhorizon"]?.AsString);
    }

    /// The messages a reply chain's record holds: in a chat, each message is a reply chain of its own. A deleted message
    /// keeps its place, without its text, so that the conversation's newest message, which may not say it's deleted yet,
    /// isn't counted for it. Throws `FormatErrorException` for a record or a message it doesn't understand, as after an
    /// update to Teams, so that its chat counts as one whose messages couldn't all be read rather than one without them.
    public static IEnumerable<TeamsMessage> Messages(JSValue value, string userId)
    {
        ArgumentNullException.ThrowIfNull(argument: value);
        if (value["messageMap"] is not { Kind: JSValueKind.PlainObject } messages)
        {
            throw FormatErrorException.Unsupported(what: "reply chain");
        }
        var conversationId = value["conversationId"]?.AsString;
        foreach (var message in messages.Properties.Values)
        {
            if (message.Kind != JSValueKind.PlainObject
                || (message["conversationId"]?.AsString ?? conversationId) is not { } chat
                || Message(value: message, conversationId: chat, userId: userId, isFromMe: Flag(value: message["isSentByCurrentUser"])) is not { } read)
            {
                throw FormatErrorException.Unsupported(what: "message");
            }
            yield return WithDeletion(value: message, message: read);
        }
    }

    /// Whether a value says true or false, as a boolean or as text; null when it says neither.
    public static bool? Flag(JSValue? value) => value?.Kind switch
    {
        JSValueKind.Bool => value.Flag,
        JSValueKind.Text when string.Equals(a: value.Text, b: "true", comparisonType: StringComparison.OrdinalIgnoreCase) => true,
        JSValueKind.Text when string.Equals(a: value.Text, b: "false", comparisonType: StringComparison.OrdinalIgnoreCase) => false,
        _ => null,
    };

    /// A message, as a conversation's newest one or a reply chain's: Teams' two kinds of record spell some of its fields
    /// differently. Null without an ID that's a time.
    static TeamsMessage? Message(JSValue value, string conversationId, string userId, bool? isFromMe)
    {
        if (Milliseconds(value: value["id"]) is not { } id)
        {
            return null;
        }
        var sender = Text(value: value["imdisplayname"]) ?? Text(value: value["imDisplayName"]);
        var from = value["from"]?.AsString ?? value["creator"]?.AsString;
        var arrivedAt = Milliseconds(value: value["originalArrivalTime"]) ?? id;
        return new TeamsMessage(
            ConversationId: conversationId,
            Id: id,
            Sender: sender,
            IsFromMe: isFromMe ?? (from is not null && from.Contains(value: userId, comparisonType: StringComparison.OrdinalIgnoreCase)),
            Type: value["messagetype"]?.AsString ?? value["messageType"]?.AsString ?? string.Empty,
            Text: MessageText.Plain(html: value["content"]?.AsString),
            ArrivedAt: DateTimeOffset.FromUnixTimeMilliseconds(milliseconds: arrivedAt));
    }

    /// A time in milliseconds since 1970, as a number or digits; null for anything else, or a time no date holds.
    static long? Milliseconds(JSValue? value)
    {
        long milliseconds;
        switch (value?.Kind)
        {
            case JSValueKind.Number when value.Number is > 0 and < 253_402_300_799_000:
                milliseconds = (long)value.Number;
                break;
            case JSValueKind.Text when long.TryParse(s: value.Text, style: NumberStyles.None, provider: CultureInfo.InvariantCulture, result: out var parsed)
                && parsed is > 0 and < 253_402_300_799_000:
                milliseconds = parsed;
                break;
            default:
                return null;
        }
        return milliseconds;
    }

    /// Text that says something: null when it's missing, empty or only spaces.
    static string? Text(JSValue? value) => value?.AsString is { } text && !string.IsNullOrWhiteSpace(value: text) ? text.Trim() : null;

    /// A chat's read marker (`consumptionhorizon`): none for a chat without the field, which Teams has for some chats it
    /// never had you read, or one never read (`0;0;0`). Throws `FormatErrorException` for a field it can't read, so that
    /// the chat counts as one that couldn't be read, rather than one never read, whose every message would be unread.
    static ReadMarker? Marker(JSValue? value)
    {
        if (value is null || value.Kind is JSValueKind.Undefined or JSValueKind.Null)
        {
            return null;
        }
        if (value.AsString is not { } horizon || (horizon.Length > 0 && !ReadMarker.IsHorizon(consumptionHorizon: horizon)))
        {
            throw FormatErrorException.Unsupported(what: "read marker");
        }
        return ReadMarker.Parse(consumptionHorizon: horizon);
    }

    /// `message` as Teams has it now: once it's deleted (`deletionInfo`), which both kinds of record say, without its text.
    static TeamsMessage WithDeletion(JSValue value, TeamsMessage message) =>
        value["deletionInfo"] is { Kind: not (JSValueKind.Undefined or JSValueKind.Null) }
            ? message with { Text = string.Empty, IsDeleted = true }
            : message;

    static string KindTitle(ConversationKind kind) => kind switch
    {
        ConversationKind.OneOnOne => "Chat",
        ConversationKind.Group => "Group chat",
        _ => "Meeting chat",
    };
}
