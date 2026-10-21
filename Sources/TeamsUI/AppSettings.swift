import Combine
import Foundation
import TeamsCore

/// Teams' settings, in BriefBar's preferences.
@MainActor
final class AppSettings: ObservableObject {
    enum KeepUnread: String, CaseIterable, Identifiable {
        case fourHours, oneDay, threeDays, untilRead

        static let defaultsKey = "teams.keepUnread"

        /// The saved choice, for the command line, which runs without the app's settings object.
        static func saved(in defaults: UserDefaults = .standard) -> KeepUnread {
            defaults.string(forKey: defaultsKey).flatMap(KeepUnread.init) ?? .oneDay
        }

        var id: String { rawValue }

        var title: String {
            switch self {
            case .fourHours: return "4 Hours"
            case .oneDay: return "1 Day"
            case .threeDays: return "3 Days"
            case .untilRead: return "Until I Read It"
            }
        }

        var interval: TimeInterval? {
            switch self {
            case .fourHours: return 4 * 3_600
            case .oneDay: return 86_400
            case .threeDays: return 3 * 86_400
            case .untilRead: return nil
            }
        }
    }

    private enum Key {
        static let keepUnread = KeepUnread.defaultsKey
        static let showPreviews = "teams.showMessagePreviews"
        static let clearWithDockBadge = "teams.clearWithDockBadge"
        static let showSummaries = "teams.showSummaries"
    }

    private let defaults: UserDefaults

    /// How long a message stays unread when BriefBar doesn't see it being read.
    @Published var keepUnread: KeepUnread {
        didSet { defaults.set(keepUnread.rawValue, forKey: Key.keepUnread) }
    }
    /// Shows the latest message under each chat.
    @Published var showPreviews: Bool {
        didSet { defaults.set(showPreviews, forKey: Key.showPreviews) }
    }
    /// Marks everything read when Teams' dock badge disappears: reading a chat in Teams leaves its
    /// notifications in Notification Center, but takes it off Teams' badge.
    @Published var clearWithDockBadge: Bool {
        didSet { defaults.set(clearWithDockBadge, forKey: Key.clearWithDockBadge) }
    }
    /// Offers one-sentence summaries from Apple's on-device model, while previews are shown.
    @Published var showSummaries: Bool {
        didSet { defaults.set(showSummaries, forKey: Key.showSummaries) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keepUnread = KeepUnread.saved(in: defaults)
        showPreviews = defaults.object(forKey: Key.showPreviews) as? Bool ?? true
        clearWithDockBadge = defaults.object(forKey: Key.clearWithDockBadge) as? Bool ?? true
        showSummaries = defaults.object(forKey: Key.showSummaries) as? Bool ?? true
    }

    var trackerSettings: TrackerSettings {
        TrackerSettings(keepUnreadFor: keepUnread.interval)
    }
}
