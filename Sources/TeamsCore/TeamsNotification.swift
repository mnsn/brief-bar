import BriefBarCore
import Foundation
import NotificationCenterDB

/// The two menu-bar items, and the chats each one lists.
public enum ChatGroup: String, Sendable, Codable, CaseIterable, Identifiable {
    /// 1:1 chats.
    case chats
    /// Group chats, including meeting chats.
    case groups

    public var id: String { rawValue }
}

public enum ConversationKind: String, Sendable, Codable, CaseIterable {
    case oneOnOne, group, meeting, channel

    /// The kind of a chat (`default_type` `chats`) from its ID. Anything that isn't a 1:1 or meeting
    /// chat is a group chat: `@thread.v2` today, `@thread.skype` for older ones.
    public init(chatID id: String) {
        let lowercased = id.lowercased()
        if lowercased.hasSuffix("@unq.gbl.spaces") {
            self = .oneOnOne
        } else if lowercased.hasPrefix("19:meeting_") {
            self = .meeting
        } else {
            self = .group
        }
    }

    /// The menu-bar item that lists it; nil for channels, which BriefBar doesn't show.
    public var chatGroup: ChatGroup? {
        switch self {
        case .oneOnOne: return .chats
        case .group, .meeting: return .groups
        case .channel: return nil
        }
    }
}

public enum ConversationID {
    /// Teams thread IDs look like `19:<id>@<domain>`, for example `19:…@unq.gbl.spaces` or `19:…@thread.v2`.
    public static func isValid(_ id: String) -> Bool {
        id.wholeMatch(of: /19:[^\s"'<>{}\[\]()|\\,;&?#\/]+@[A-Za-z0-9.\-]+/) != nil
    }
}

/// A chat message, from the notification Teams posted for it.
public struct ChatMessage: Sendable, Equatable, Hashable, Codable {
    public var conversationID: String
    public var kind: ConversationKind
    /// Teams' message ID (milliseconds since 1970), when the notification has it.
    public var messageID: String?
    /// The notification's key, used when there's no message ID.
    public var notificationKey: String
    public var deliveredAt: Date
    /// The chat's name: the sender in a 1:1 chat, the chat's name or members in a group chat.
    public var chatName: String
    public var sender: String?
    public var text: String

    public init(
        conversationID: String, kind: ConversationKind, messageID: String?, notificationKey: String,
        deliveredAt: Date, chatName: String, sender: String?, text: String
    ) {
        self.conversationID = conversationID
        self.kind = kind
        self.messageID = messageID
        self.notificationKey = notificationKey
        self.deliveredAt = deliveredAt
        self.chatName = chatName
        self.sender = sender
        self.text = text
    }

    /// Identifies the message across notifications: Teams may post one message more than once.
    public var key: String { conversationID + "/" + (messageID ?? notificationKey) }
}

public enum Unrecognized: String, Sendable, Equatable, Codable, CaseIterable {
    case noData, notPlist, noRequest, noUserInfo, missingType, invalidConversationID
    /// A type BriefBar doesn't know, on a notification that looks like a chat message (it has a reply
    /// box or a chat's ID): more likely a renamed chat type than another kind of notification.
    case unknownChatType
}

/// What a stored Teams notification is.
public enum TeamsItem: Sendable, Equatable {
    /// A chat message: it has a reply box (`textInputsend_*`).
    case message(ChatMessage)
    /// Other chat notifications, such as reactions to your messages. Not unread messages.
    case chatActivity(conversationID: String, kind: ConversationKind)
    /// A channel post or reply. Recognized, but not shown.
    case channelPost(channelID: String?)
    /// A well-formed notification of a kind BriefBar doesn't show, such as a call. Not a sign that
    /// the format changed.
    case otherNotification
    case unrecognized(Unrecognized)

    public var message: ChatMessage? {
        if case .message(let message) = self { return message }
        return nil
    }
}

public struct ParsedNotification: Sendable, Equatable {
    /// The notification's key (see `RawNotification.key`).
    public var key: String
    public var deliveredAt: Date?
    public var item: TeamsItem
    /// The decoded notification; nil when it couldn't be decoded.
    public var raw: RawNotification?

    public init(key: String, deliveredAt: Date?, item: TeamsItem, raw: RawNotification? = nil) {
        self.key = key
        self.deliveredAt = deliveredAt
        self.item = item
        self.raw = raw
    }
}

/// Interprets Teams' notifications. Their user info, as of Teams 26261:
///
/// - Chats: `default_type` `chats`, `default_id` the conversation ID, `default_options` JSON with
///   `messageId`. Messages add a reply box: `textInputsend_type` `chats` and `textInputsend_options`
///   JSON whose `convId` is the conversation ID again. Reactions have no reply box.
/// - Channels: `default_type` `channels`, `default_id` JSON with `channelId` and `replyChainId`.
public enum TeamsNotificationParser {
    public static func parse(_ record: StoredRecord) -> ParsedNotification {
        switch RecordDecoder.decode(record) {
        case .success(let raw):
            return ParsedNotification(key: raw.key, deliveredAt: raw.deliveredAt, item: parse(raw), raw: raw)
        case .failure(let failure):
            let key = record.uuid.map { $0.map { String(format: "%02x", $0) }.joined() }
                ?? record.recordID.map { "rec\($0)" } ?? "record"
            let reason: Unrecognized = switch failure {
            case .noData: .noData
            case .notPlist: .notPlist
            case .noRequest: .noRequest
            }
            return ParsedNotification(key: key, deliveredAt: record.deliveredDate, item: .unrecognized(reason))
        }
    }

    public static func parse(_ raw: RawNotification) -> TeamsItem {
        guard raw.userInfoState == .decoded, !raw.userInfo.isEmpty else { return .unrecognized(.noUserInfo) }
        switch raw.userInfo["default_type"]?.trimmingCharacters(in: .whitespaces) {
        case "chats":
            return parseChat(raw)
        case "channels":
            let channel = json(raw.userInfo["default_id"])?["channelId"] as? String
            return .channelPost(channelID: channel.flatMap { ConversationID.isValid($0) ? $0 : nil })
        case nil, "":
            return .unrecognized(.missingType)
        default:
            return looksLikeChat(raw) ? .unrecognized(.unknownChatType) : .otherNotification
        }
    }

    /// A reply box, or a chat's (not a channel's) ID where chats have theirs.
    static func looksLikeChat(_ raw: RawNotification) -> Bool {
        if raw.userInfoKeys.contains(where: { $0.hasPrefix("textInputsend") }) { return true }
        let ids = [raw.userInfo["default_id"], json(raw.userInfo["textInputsend_options"])?["convId"] as? String]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        return ids.contains { ConversationID.isValid($0) && !$0.lowercased().hasSuffix("@thread.tacv2") }
    }

    private static func parseChat(_ raw: RawNotification) -> TeamsItem {
        let reply = json(raw.userInfo["textInputsend_options"])
        let candidates = [raw.userInfo["default_id"], reply?["convId"] as? String]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let conversation = candidates.first(where: ConversationID.isValid) else {
            return .unrecognized(.invalidConversationID)
        }
        let kind = ConversationKind(chatID: conversation)
        let hasReplyBox = raw.userInfo["textInputsend_type"] != nil || raw.userInfo["textInputsend_options"] != nil
        guard hasReplyBox else { return .chatActivity(conversationID: conversation, kind: kind) }

        let title = raw.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = raw.body.trimmingCharacters(in: .whitespacesAndNewlines)
        var sender: String?
        var text = body
        if kind == .oneOnOne {
            sender = title.isEmpty ? nil : title
        } else if let split = splitSender(body) {
            (sender, text) = split
        }
        return .message(ChatMessage(
            conversationID: conversation,
            kind: kind,
            messageID: messageID(json(raw.userInfo["default_options"])?["messageId"]),
            notificationKey: raw.key,
            deliveredAt: raw.deliveredAt ?? .distantPast,
            chatName: title,
            sender: sender,
            text: text
        ))
    }

    /// Group chat bodies read "Sender: text".
    static func splitSender(_ body: String) -> (sender: String, text: String)? {
        guard let separator = body.range(of: ": ") else { return nil }
        let sender = body[..<separator.lowerBound]
        guard !sender.isEmpty, sender.count <= 80, !sender.contains(where: \.isNewline) else { return nil }
        return (String(sender), String(body[separator.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func messageID(_ value: Any?) -> String? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let id = number.int64Value
            return id > 0 ? String(id) : nil
        }
        if let text = (value as? String)?.trimmingCharacters(in: .whitespaces),
           !text.isEmpty, text.allSatisfy(\.isASCIIDigit) {
            return text
        }
        return nil
    }

    static func json(_ text: String?) -> [String: Any]? {
        guard let data = text?.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              data.first == UInt8(ascii: "{")
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
