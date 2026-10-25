import BriefBarUI
import Combine
import Foundation

/// GitHub's settings, in BriefBar's preferences.
@MainActor
final class AppSettings: ObservableObject {
    static let refreshChoices: [(minutes: Int, title: String)] = [
        (1, "1 Minute"), (2, "2 Minutes"), (5, "5 Minutes"), (15, "15 Minutes"),
    ]
    static let defaultRefreshMinutes = 2

    enum Key {
        static let refreshMinutes = "github.refreshMinutes"
    }

    private let defaults: UserDefaults

    /// How often BriefBar reads GitHub: one request each time.
    @Published var refreshMinutes: Int {
        didSet { defaults.set(refreshMinutes, forKey: Key.refreshMinutes) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let minutes = defaults.integer(forKey: Key.refreshMinutes)
        refreshMinutes = Self.refreshChoices.contains { $0.minutes == minutes } ? minutes : Self.defaultRefreshMinutes
    }

    var refreshInterval: TimeInterval { TimeInterval(refreshMinutes * 60) }
}

extension BriefBarUI.WidgetSize {
    /// How wide a widget needs to be for pull requests, at this size.
    var width: CGFloat { self == .compact ? 280 : 340 }
}
