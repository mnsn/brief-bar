import BriefBarCore
import Combine
import Foundation

/// The Notifications page: what BriefBar notified you of lately, from every source, so you can see what you missed, even
/// what macOS didn't show, as during a Focus, and every update a notification only counted. It's off until you turn it
/// on, in Settings › General, and the window shows it only while it lists something. It lists what was posted while it
/// was off too, so turning it on shows what's still kept.
///
/// What it lists stays in memory only, for as long as you choose (a day unless you change it), and is gone when
/// BriefBar restarts: the notifications' titles and messages never go to disk or to the preferences.
@MainActor
package final class RecentNotifications: ObservableObject {
    package static let enabledKey = "notifications.page"
    package static let keepHoursKey = "notifications.keepHours"

    /// The page: off until you turn it on.
    @Published package private(set) var isOn: Bool
    /// How long what was posted stays listed.
    @Published package private(set) var keepHours: Int
    @Published package private(set) var history = NotificationHistory()
    /// For how long ago each was posted: it moves on every minute while there's something listed.
    @Published package private(set) var now = Date()

    private let defaults: UserDefaults
    private var ticker: Timer?
    /// What shows the page now, such as windows, by ID.
    private var viewers: Set<String> = []

    /// - Parameter isDemo: the demo shows the page, in preferences that are thrown away.
    package init(defaults: UserDefaults, isDemo: Bool) {
        self.defaults = defaults
        isOn = isDemo || defaults.bool(forKey: Self.enabledKey)
        keepHours = NotificationHistory.keepHours(defaults.integer(forKey: Self.keepHoursKey))
    }

    /// Whether the window shows the page: it's on, and lists something.
    package var showsPage: Bool {
        isOn && !history.isEmpty
    }

    package func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        defaults.set(on, forKey: Self.enabledKey)
    }

    package func setKeepHours(_ hours: Int) {
        let hours = NotificationHistory.keepHours(hours)
        guard hours != keepHours else { return }
        keepHours = hours
        defaults.set(hours, forKey: Self.keepHoursKey)
        prune()
    }

    /// Lists what a source posted, or would have if macOS let it, as posted at `date`: the newest first, as they come.
    package func record(_ notes: [BriefBarNotification], at date: Date = Date()) {
        guard !notes.isEmpty else { return }
        var history = history
        for note in notes {
            history.add(NotificationHistory.Entry(
                id: note.id, source: note.source, state: note.state, title: note.title, subtitle: note.subtitle,
                body: note.body, date: date, userInfo: note.userInfo
            ))
        }
        self.history = history
        now = Date()
        prune()
    }

    /// You've seen it: you clicked it, on the page or in Notification Center.
    package func markSeen(_ id: String) {
        change { $0.markSeen(id) }
    }

    package func remove(_ id: String) {
        change { $0.remove(id) }
    }

    /// Takes these off the page, such as a notification that no longer says what's going on.
    package func remove(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        change { history in ids.forEach { history.remove($0) } }
    }

    /// Takes everything off the page, which then hides until something new comes.
    package func clear() {
        change { $0.removeAll() }
    }

    /// What a source posted, when it's turned off.
    package func forget(_ source: SourceID) {
        change { $0.removeAll(from: source) }
    }

    /// Something started or stopped showing the page, such as a window: once none does, everything it showed is seen.
    package func pageVisibilityChanged(_ isShowing: Bool, by viewer: String) {
        if isShowing {
            viewers.insert(viewer)
        } else if viewers.remove(viewer) != nil, viewers.isEmpty {
            let left = Date()
            change { $0.markSeen(through: left) }
        }
    }

    /// Publishes the history only when it changes, and ticks only while it lists something.
    private func change(_ body: (inout NotificationHistory) -> Void) {
        var changed = history
        body(&changed)
        if changed != history { history = changed }
        updateTicker()
    }

    /// Drops what was posted longer ago than it keeps.
    private func prune() {
        let now = Date()
        change { $0.prune(now: now, keepHours: keepHours) }
    }

    private func updateTicker() {
        if history.isEmpty {
            ticker?.invalidate()
            ticker = nil
        } else if ticker == nil {
            let ticker = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.now = Date()
                    self?.prune()
                }
            }
            ticker.tolerance = 10
            RunLoop.main.add(ticker, forMode: .common)
            self.ticker = ticker
        }
    }
}
