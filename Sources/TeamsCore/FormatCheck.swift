import BriefBarCore
import Foundation
import NotificationCenterDB

/// How many of the stored Teams notifications BriefBar understood.
public struct FormatReport: Sendable, Equatable, Codable {
    public var total = 0
    public var chatMessages = 0
    public var chatActivity = 0
    public var channelPosts = 0
    /// Well-formed notifications of kinds BriefBar doesn't show, such as calls.
    public var otherNotifications = 0
    public var unrecognized: [Unrecognized: Int] = [:]

    public init() {}

    public init(_ notifications: [ParsedNotification]) {
        total = notifications.count
        for notification in notifications {
            switch notification.item {
            case .message: chatMessages += 1
            case .chatActivity: chatActivity += 1
            case .channelPost: channelPosts += 1
            case .otherNotification: otherNotifications += 1
            case .unrecognized(let reason): unrecognized[reason, default: 0] += 1
            }
        }
    }

    public var recognized: Int { chatMessages + chatActivity + channelPosts + otherNotifications }
    public var unreadable: Int { total - recognized }

    public var verdict: FormatVerdict {
        if total == 0 { return .empty }
        if recognized == 0 { return .unrecognized(total: total) }
        // A few odd notifications are normal; a quarter suggests Teams changed its format.
        if unreadable * 4 > total { return .partlyUnreadable(unreadable: unreadable, total: total) }
        return .ok
    }
}

public enum FormatVerdict: Sendable, Equatable, Codable {
    case ok
    /// Notification Center has no Teams notifications.
    case empty
    case partlyUnreadable(unreadable: Int, total: Int)
    case unrecognized(total: Int)
}

/// Something that keeps BriefBar from showing everything, as the UI explains it.
public enum PulseProblem: Sendable, Equatable {
    case noAccess
    case databaseMissing(path: String)
    case layoutChanged(missing: [String])
    case readFailed(String)
    case formatChanged(total: Int)
    case partlyUnreadable(unreadable: Int, total: Int)
    /// Teams' own record of how far you've read each chat was found, but not understood.
    case readMarkersChanged
    case readMarkersPartlyUnreadable

    public var title: String {
        switch self {
        case .noAccess: return "BriefBar needs Full Disk Access"
        case .databaseMissing: return "Notification Center's database wasn't found"
        case .layoutChanged: return "Notification Center's database has changed"
        case .readFailed: return "Couldn't read Notification Center's database"
        case .formatChanged: return "Teams' notifications have changed"
        case .partlyUnreadable: return "Some Teams notifications couldn't be read"
        case .readMarkersChanged: return "Teams' read markers have changed"
        case .readMarkersPartlyUnreadable: return "Some of Teams' read markers couldn't be read"
        }
    }

    public var message: String {
        switch self {
        case .noAccess:
            return "It reads Teams' notifications from Notification Center's database, which macOS protects."
        case .databaseMissing(let path):
            return "Nothing at \(path). This version of macOS may keep it elsewhere."
        case .layoutChanged(let missing):
            return "Missing: \(missing.joined(separator: ", ")). A macOS update probably changed it, so BriefBar can't show chats."
        case .readFailed(let message):
            return message
        case .formatChanged(let total):
            return "None of the \(total) stored Teams notifications could be read. A Teams update probably changed them."
        case .partlyUnreadable(let unreadable, let total):
            return "\(unreadable) of \(total) couldn't be read, so some chats may be missing."
        case .readMarkersChanged:
            return "BriefBar can't see which chats you've read in Teams, probably since a Teams update. Chats still become read when you open them from BriefBar, when Teams' badge clears, and after Keep Unread For."
        case .readMarkersPartlyUnreadable:
            return "Some chats you read in Teams may stay unread here until you open them from BriefBar, Teams' badge clears, or Keep Unread For passes."
        }
    }

    /// Whether BriefBar can show nothing at all.
    public var isBlocking: Bool {
        switch self {
        case .partlyUnreadable, .readMarkersChanged, .readMarkersPartlyUnreadable: return false
        default: return true
        }
    }
}
