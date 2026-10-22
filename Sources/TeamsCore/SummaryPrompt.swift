import BriefBarCore
import Foundation
import NotificationCenterDB

/// What BriefBar asks Apple's on-device model when it summarizes a chat. Built here, apart from the
/// model, so it can be tested.
public enum SummaryPrompt {
    public static let instructions = """
        You summarize a Microsoft Teams chat for the person who received these messages, so they can \
        decide whether to open it now. Reply with one short sentence of at most 25 words: what the chat \
        is about, and anything the messages ask of the reader. Write in the language of the messages. \
        Use only what the messages say.
        """

    /// Characters of messages at most: the model's context window is about 4,000 tokens.
    public static let defaultLimit = 3_000
    static let messageLimit = 600

    /// The chat's unread messages, or its latest ones if none are unread, oldest first. The newest
    /// messages are kept when they don't all fit in `limit` characters.
    public static func prompt(for conversation: ConversationSummary, limit: Int = defaultLimit) -> String {
        let messages = conversation.isUnread ? conversation.unread : conversation.latestMessages
        var lines: [String] = []
        var used = 0
        for message in messages.reversed() {
            var text = message.text.replacingOccurrences(of: "\n", with: " ")
            if text.count > messageLimit {
                text = String(text.prefix(messageLimit)) + "…"
            }
            let sender = message.sender ?? (conversation.kind == .oneOnOne ? conversation.name : "Someone")
            let line = "\(sender): \(text)"
            if used + line.count > limit, !lines.isEmpty { break }
            lines.append(line)
            used += line.count
        }
        let kind = switch conversation.kind {
        case .oneOnOne: "a 1:1 chat"
        case .group: "a group chat"
        case .meeting: "a meeting's chat"
        case .channel: "a channel"
        }
        return "Chat: \(conversation.name) (\(kind))\nMessages, oldest first:\n" + lines.reversed().joined(separator: "\n")
    }

    /// Identifies what a summary covers, so a new message calls for a new one.
    public static func key(for conversation: ConversationSummary) -> String {
        let messages = conversation.isUnread ? conversation.unread : conversation.latestMessages
        return conversation.id + "|" + (messages.last?.key ?? "") + "|\(messages.count)"
    }

    /// The model's answer as one line, without wrapping quotes.
    public static func clean(_ response: String) -> String {
        var text = response.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        for (open, close) in [("\"", "\""), ("“", "”"), ("'", "'")] where text.hasPrefix(open) && text.hasSuffix(close) && text.count > 1 {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return text
    }
}

extension SummaryPrompt {
    /// A brief's line for an unread chat in BriefBar's own words: who wrote and how many messages, and with
    /// `showsText` (Teams' Show Message Previews on), what the newest one says. Without it, no message text at all.
    public static func briefSentence(for conversation: ConversationSummary, showsText: Bool) -> String {
        let count = conversation.unreadCount
        let messages = count == 1 ? "a message" : "\(count) messages"
        let newest = conversation.unread.last ?? conversation.latest
        var sentence: String
        if conversation.kind == .oneOnOne {
            sentence = "\(conversation.name) sent you \(messages)"
        } else {
            sentence = "\(conversation.name): \(count == 1 ? "a new message" : "\(count) new messages")"
            if let sender = newest?.sender, !sender.isEmpty {
                sentence += count == 1 ? " from \(sender)" : ", the newest from \(sender)"
            }
        }
        guard showsText, let text = newest?.text, !text.isEmpty else { return sentence + "." }
        return sentence + ": “\(clip(text))”"
    }

    /// One line of at most `limit` characters.
    static func clip(_ text: String, limit: Int = 120) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return line.count > limit ? String(line.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" : line
    }
}
