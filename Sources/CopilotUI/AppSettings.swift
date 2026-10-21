import BriefBarUI
import Combine
import Foundation

/// Copilot's settings, in BriefBar's preferences, and the sessions you've cleared.
@MainActor
final class AppSettings: ObservableObject {
    typealias Placement = WidgetPlacement
    typealias WidgetSize = BriefBarUI.WidgetSize

    static let keepEndedChoices: [(minutes: Int, title: String)] = [
        (15, "15 Minutes"), (60, "1 Hour"), (240, "4 Hours"), (1_440, "1 Day"),
    ]

    private enum Key {
        static let showWidget = "copilot.showWidget"
        static let placement = "copilot.widgetPlacement"
        static let widgetSize = "copilot.widgetSize"
        static let keepEndedMinutes = "copilot.keepEndedMinutes"
        static let showContextUsage = "copilot.showContextUsage"
        static let acknowledged = "copilot.acknowledgedSessions"
    }

    private let defaults: UserDefaults

    @Published var showWidget: Bool {
        didSet { defaults.set(showWidget, forKey: Key.showWidget) }
    }
    @Published var placement: Placement {
        didSet { defaults.set(placement.rawValue, forKey: Key.placement) }
    }
    @Published var widgetSize: WidgetSize {
        didSet { defaults.set(widgetSize.rawValue, forKey: Key.widgetSize) }
    }
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
        showWidget = defaults.object(forKey: Key.showWidget) as? Bool ?? true
        placement = defaults.string(forKey: Key.placement).flatMap(Placement.init) ?? .desktop
        widgetSize = defaults.string(forKey: Key.widgetSize).flatMap(WidgetSize.init) ?? .medium
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
    /// Copilot's widget width at this size.
    var width: CGFloat { self == .compact ? 270 : 320 }
}
