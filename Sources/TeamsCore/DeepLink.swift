import BriefBarCore
import Foundation
import NotificationCenterDB

/// Links that open a chat in the Teams app.
public enum DeepLink {
    /// `{"contextType":"chat"}`, percent-encoded.
    static let chatContext = "%7B%22contextType%22%3A%22chat%22%7D"

    /// Teams' documented link to a message in a chat (the form "Copy link" gives), with the app's
    /// `msteams:` scheme so no browser is involved. Teams opens the chat at that message.
    public static func message(conversationID: String, messageID: String) -> URL? {
        guard ConversationID.isValid(conversationID), !messageID.isEmpty, messageID.allSatisfy(\.isASCIIDigit),
              let id = encode(conversationID)
        else { return nil }
        return URL(string: "msteams:/l/message/\(id)/\(messageID)?context=\(chatContext)")
    }

    /// Opens a chat without a message. Undocumented, so only used when there's no message ID.
    public static func chat(conversationID: String) -> URL? {
        guard ConversationID.isValid(conversationID), let id = encode(conversationID) else { return nil }
        return URL(string: "msteams:/l/chat/\(id)/0")
    }

    /// The message's link, or the chat's if the message has no ID.
    public static func link(to message: ChatMessage) -> URL? {
        if let messageID = message.messageID,
           let url = Self.message(conversationID: message.conversationID, messageID: messageID) {
            return url
        }
        return chat(conversationID: message.conversationID)
    }

    /// Percent-encodes everything but unreserved characters, so `:` and `@` become `%3A` and `%40`.
    static func encode(_ text: String) -> String? {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: unreserved)
    }
}
