import AppKit
import BriefBarUI
import TeamsCore
import SwiftUI

extension ChatGroup {
    var title: String {
        switch self {
        case .chats: return "Chats"
        case .groups: return "Group Chats"
        }
    }

    /// The menu-bar symbol.
    var symbol: String {
        switch self {
        case .chats: return "person.fill"
        case .groups: return "person.2.fill"
        }
    }

    var nsColor: NSColor {
        switch self {
        case .chats: return .systemIndigo
        case .groups: return .systemTeal
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    /// "1 unread chat", "3 unread group chats".
    func unreadDescription(_ count: Int) -> String {
        let noun = self == .chats ? "chat" : "group chat"
        return count == 0 ? "No unread \(noun)s" : "\(count) unread \(noun)\(count == 1 ? "" : "s")"
    }
}

enum RelativeTime {
    /// "now", "5m", "3h", "2d".
    static func short(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }
}

extension ChatMessage {
    /// The text a list shows: "Sender: text" in group chats.
    var preview: String {
        let text = text.isEmpty ? "New message" : text
        guard kind != .oneOnOne, let sender, !sender.isEmpty else { return text }
        return "\(sender): \(text)"
    }
}

/// A colored circle with the person's initials, or a group symbol. Drawn locally: no pictures are fetched.
struct AvatarView: View {
    let conversation: ConversationSummary

    private static let palette: [NSColor] = [
        .systemBlue, .systemPurple, .systemPink, .systemOrange, .systemTeal, .systemGreen, .systemIndigo, .systemBrown,
    ]

    var body: some View {
        ZStack {
            Circle().fill(Color(nsColor: Self.color(for: conversation.id)).gradient)
            switch conversation.kind {
            case .oneOnOne:
                Text(Self.initials(conversation.name))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            case .meeting:
                Image(systemName: "calendar")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            case .group, .channel:
                Image(systemName: "person.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .accessibilityHidden(true)
    }

    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .compactMap { word in word.first(where: \.isLetter) }
        let letters = words.count > 1 ? [words[0], words[words.count - 1]] : Array(words.prefix(1))
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    /// The same color for a chat every time.
    static func color(for id: String) -> NSColor {
        var hash: UInt64 = 5_381
        for byte in id.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

struct CountBadge: View {
    let count: Int
    let color: Color

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color))
            .fixedSize()
    }
}
