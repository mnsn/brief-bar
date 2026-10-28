import BriefBarUI
import Combine
import CopilotCore
import Foundation

/// Copilot's settings, in BriefBar's preferences, and the sessions you've cleared.
@MainActor
final class AppSettings: ObservableObject {
    typealias WidgetSize = BriefBarUI.WidgetSize

    static let keepEndedChoices: [(minutes: Int, title: String)] = [
        (15, "15 Minutes"), (60, "1 Hour"), (240, "4 Hours"), (1_440, "1 Day"),
    ]

    private enum Key {
        static let keepEndedMinutes = "copilot.keepEndedMinutes"
        static let showContextUsage = "copilot.showContextUsage"
        static let moveViewedToIdle = "copilot.moveViewedToIdle"
        static let cleared = "copilot.clearedSessions"
        static let viewed = "copilot.acknowledgedSessions"
    }

    private let defaults: UserDefaults

    /// How long finished/stopped sessions stay highlighted unless explicitly cleared.
    @Published var keepEndedMinutes: Int {
        didSet { defaults.set(keepEndedMinutes, forKey: Key.keepEndedMinutes) }
    }
    /// Shows how full each session's context window is.
    @Published var showContextUsage: Bool {
        didSet { defaults.set(showContextUsage, forKey: Key.showContextUsage) }
    }
    /// Opt-in: viewing an ended session dismisses it before the retention time expires.
    @Published var moveViewedToIdle: Bool {
        didSet { defaults.set(moveViewedToIdle, forKey: Key.moveViewedToIdle) }
    }
    /// Session ID → when the user last clicked Clear for its finished/stopped state.
    @Published private(set) var cleared: [String: Date]
    @Published private(set) var viewed: [String: Date]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let minutes = defaults.integer(forKey: Key.keepEndedMinutes)
        keepEndedMinutes = minutes > 0 ? minutes : 60
        showContextUsage = defaults.bool(forKey: Key.showContextUsage)
        moveViewedToIdle = defaults.bool(forKey: Key.moveViewedToIdle)

        // Old acknowledgments include automatic dismissals just from viewing a session.
        // Keep them only as viewed markers, used while the option is on, never as explicit clears.
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        cleared = Self.dates(in: defaults, key: Key.cleared, after: cutoff)
        viewed = Self.dates(in: defaults, key: Key.viewed, after: cutoff)
    }

    /// Command-line and agent reads honor the same retention and dismissal settings as the UI.
    nonisolated static func resolve(_ state: EngineSnapshot, now: Date, defaults: UserDefaults) -> [SessionSnapshot] {
        let minutes = defaults.integer(forKey: Key.keepEndedMinutes)
        let options = ResolverOptions(
            recentWindow: TimeInterval((minutes > 0 ? minutes : 60) * 60),
            moveViewedToIdle: defaults.bool(forKey: Key.moveViewedToIdle)
        )
        let cutoff = now.addingTimeInterval(-7 * 86_400)
        let cleared = dates(in: defaults, key: Key.cleared, after: cutoff)
        let viewed = dates(in: defaults, key: Key.viewed, after: cutoff)
        return SessionOrdering.sorted(state.records.map {
            StatusResolver.snapshot(
                for: $0, now: now, options: options, view: state.view,
                clearedAt: cleared[$0.id], viewedAt: viewed[$0.id]
            )
        })
    }

    nonisolated private static func dates(in defaults: UserDefaults, key: String, after cutoff: Date) -> [String: Date] {
        let stored = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        return stored.mapValues { Date(timeIntervalSince1970: $0) }.filter { $0.value > cutoff }
    }

    func clear<S: Sequence>(_ ids: S, at date: Date = Date()) where S.Element == String {
        var updated = cleared
        for id in ids { updated[id] = date }
        guard updated != cleared else { return }
        cleared = updated
        defaults.set(updated.mapValues(\.timeIntervalSince1970), forKey: Key.cleared)
    }

    func markViewed<S: Sequence>(_ ids: S, at date: Date = Date()) where S.Element == String {
        var updated = viewed
        for id in ids { updated[id] = date }
        guard updated != viewed else { return }
        viewed = updated
        defaults.set(updated.mapValues(\.timeIntervalSince1970), forKey: Key.viewed)
    }

    /// Forgets cleared and viewed sessions when Copilot is turned off.
    func forgetDismissed() {
        cleared = [:]
        viewed = [:]
        defaults.removeObject(forKey: Key.cleared)
        defaults.removeObject(forKey: Key.viewed)
    }
}

extension BriefBarUI.WidgetSize {
    /// How wide a widget needs to be for sessions, at this size.
    var width: CGFloat { self == .compact ? 270 : 320 }
}
