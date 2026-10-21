import BriefBarUI
import Combine
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
        static let acknowledged = "copilot.acknowledgedSessions"
    }

    private let defaults: UserDefaults

    /// How long finished/stopped sessions stay highlighted (unless opened sooner).
    @Published var keepEndedMinutes: Int {
        didSet { defaults.set(keepEndedMinutes, forKey: Key.keepEndedMinutes) }
    }
    /// Shows how full each session's context window is.
    @Published var showContextUsage: Bool {
        didSet { defaults.set(showContextUsage, forKey: Key.showContextUsage) }
    }
    /// Session ID → when the user last dismissed its finished/stopped state.
    @Published private(set) var acknowledged: [String: Date]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let minutes = defaults.integer(forKey: Key.keepEndedMinutes)
        keepEndedMinutes = minutes > 0 ? minutes : 60
        showContextUsage = defaults.bool(forKey: Key.showContextUsage)

        let stored = defaults.dictionary(forKey: Key.acknowledged) as? [String: Double] ?? [:]
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        acknowledged = stored
            .mapValues { Date(timeIntervalSince1970: $0) }
            .filter { $0.value > cutoff }
    }

    func acknowledge<S: Sequence>(_ ids: S, at date: Date = Date()) where S.Element == String {
        var updated = acknowledged
        for id in ids { updated[id] = date }
        guard updated != acknowledged else { return }
        acknowledged = updated
        defaults.set(updated.mapValues(\.timeIntervalSince1970), forKey: Key.acknowledged)
    }

    /// Forgets which sessions you cleared, when Copilot is turned off.
    func forgetAcknowledged() {
        acknowledged = [:]
        defaults.removeObject(forKey: Key.acknowledged)
    }
}

extension BriefBarUI.WidgetSize {
    /// How wide a widget needs to be for sessions, at this size.
    var width: CGFloat { self == .compact ? 270 : 320 }
}
