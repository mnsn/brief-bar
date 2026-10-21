import AzureDevOpsCore
import BriefBarUI
import Combine
import Foundation

/// Azure DevOps' settings, and which pull requests you've seen, in BriefBar's preferences.
@MainActor
final class AppSettings: ObservableObject {
    /// The installed app's preferences, which the command line reads too.
    nonisolated static var appDefaults: UserDefaults? { AppIdentity.installedAppDefaults }

    typealias WidgetSize = BriefBarUI.WidgetSize

    static let refreshChoices: [(seconds: Int, title: String)] = [
        (60, "Every Minute"), (120, "Every 2 Minutes"), (300, "Every 5 Minutes"),
    ]
    static let keepDoneChoices: [(hours: Int, title: String)] = [
        (4, "4 Hours"), (24, "1 Day"), (72, "3 Days"),
    ]
    static let idleChoices: [(days: Int, title: String)] = [
        (7, "1 Week"), (14, "2 Weeks"), (30, "1 Month"), (0, "Never"),
    ]

    typealias Key = SettingsKey

    private let defaults: UserDefaults

    @Published var refreshSeconds: Int {
        didSet { defaults.set(refreshSeconds, forKey: Key.refreshSeconds) }
    }
    /// How long completed and abandoned pull requests stay in Done (unless opened sooner).
    @Published var keepDoneHours: Int {
        didSet { defaults.set(keepDoneHours, forKey: Key.keepDoneHours) }
    }
    /// Pull requests without activity for this many days move to Idle; 0 never.
    @Published var idleDays: Int {
        didSet { defaults.set(idleDays, forKey: Key.idleDays) }
    }
    @Published var notifications: Bool {
        didSet { defaults.set(notifications, forKey: Key.notifications) }
    }
    /// Summaries written on this Mac by Apple Intelligence.
    @Published var summaries: Bool {
        didSet { defaults.set(summaries, forKey: Key.summaries) }
    }
    /// Adds the To Review count to the menu bar.
    @Published var showToReview: Bool {
        didSet { defaults.set(showToReview, forKey: Key.showToReview) }
    }
    /// The organizations to watch.
    @Published var organizations: [String] {
        didSet { defaults.set(organizations, forKey: Key.organizations) }
    }
    /// Every organization you belong to, as last found.
    @Published var knownOrganizations: [String] {
        didSet { defaults.set(knownOrganizations, forKey: Key.knownOrganizations) }
    }
    @Published var hasDiscovered: Bool {
        didSet { defaults.set(hasDiscovered, forKey: Key.hasDiscovered) }
    }
    @Published private(set) var seen: SeenState

    init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults
        refreshSeconds = Self.choice(defaults.integer(forKey: Key.refreshSeconds), in: Self.refreshChoices.map(\.seconds), default: 60)
        keepDoneHours = Self.choice(defaults.integer(forKey: Key.keepDoneHours), in: Self.keepDoneChoices.map(\.hours), default: 24)
        idleDays = Self.choice(defaults.object(forKey: Key.idleDays) as? Int ?? -1, in: Self.idleChoices.map(\.days), default: 14)
        notifications = defaults.object(forKey: Key.notifications) as? Bool ?? true
        summaries = defaults.object(forKey: Key.summaries) as? Bool ?? true
        showToReview = defaults.bool(forKey: Key.showToReview)
        organizations = defaults.stringArray(forKey: Key.organizations) ?? []
        knownOrganizations = defaults.stringArray(forKey: Key.knownOrganizations) ?? []
        hasDiscovered = defaults.bool(forKey: Key.hasDiscovered)

        if let data = defaults.data(forKey: Key.seen), let stored = try? JSONDecoder().decode(SeenState.self, from: data) {
            seen = stored
            hasSavedSeen = true
        } else {
            // Saved once Azure DevOps is on (`startSeeing`), so its first run is when you turn it on.
            seen = SeenState.firstRun(now: now)
        }
    }

    private var hasSavedSeen = false

    /// Azure DevOps starts: what you've seen counts from now, the first time.
    func startSeeing(now: Date = Date()) {
        guard !hasSavedSeen else { return }
        seen = SeenState.firstRun(now: now)
        persistSeen()
    }

    /// Forgets what you've seen, when Azure DevOps is turned off. Your organizations stay.
    func forgetSeen() {
        defaults.removeObject(forKey: Key.seen)
        hasSavedSeen = false
        seen = SeenState.firstRun()
    }

    private static func choice(_ value: Int, in choices: [Int], default fallback: Int) -> Int {
        choices.contains(value) ? value : fallback
    }

    var engineConfiguration: PulseEngine.Configuration {
        PulseEngine.Configuration(
            organizations: organizations,
            interval: TimeInterval(refreshSeconds),
            keepDoneFor: TimeInterval(keepDoneHours) * 3_600,
            inactiveAfter: idleDays > 0 ? TimeInterval(idleDays) * 86_400 : nil
        )
    }

    var classifierOptions: ClassifierOptions {
        ClassifierOptions(
            inactiveAfter: idleDays > 0 ? TimeInterval(idleDays) * 86_400 : nil,
            keepDoneFor: TimeInterval(keepDoneHours) * 3_600
        )
    }

    func markSeen<S: Sequence>(_ keys: S, at date: Date = Date()) where S.Element == PRKey {
        markSeen(keys.map { ($0, date) })
    }

    /// Each pull request seen up to its own time.
    func markSeen(_ entries: [(key: PRKey, date: Date)]) {
        var updated = seen
        for entry in entries { updated.markSeen([entry.key], at: entry.date) }
        guard updated != seen else { return }
        seen = updated
        persistSeen()
    }

    /// Forgets pull requests that are no longer listed and were last seen over two months ago.
    func pruneSeen(keeping keys: Set<PRKey>, now: Date = Date()) {
        var updated = seen
        updated.prune(keeping: keys, olderThan: now.addingTimeInterval(-60 * 86_400))
        guard updated != seen else { return }
        seen = updated
        persistSeen()
    }

    /// Replaces the seen state, for the demo.
    func useSeenState(_ state: SeenState) {
        seen = state
    }

    /// Organization names are case-insensitive in Azure DevOps.
    func isWatching(_ name: String) -> Bool {
        organizations.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    func toggleOrganization(_ name: String) {
        if isWatching(name) {
            organizations.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        } else {
            organizations = OrganizationDiscovery.merged(organizations, preferring: [name])
        }
    }

    private func persistSeen() {
        if let data = try? JSONEncoder().encode(seen) {
            defaults.set(data, forKey: Key.seen)
            hasSavedSeen = true
        }
    }
}

/// UserDefaults keys, shared with the command line, which reads them.
enum SettingsKey {
    static let refreshSeconds = "ado.refreshSeconds"
    static let keepDoneHours = "ado.keepDoneHours"
    static let idleDays = "ado.idleDays"
    static let notifications = "ado.notifications"
    static let summaries = "ado.summaries"
    static let showToReview = "ado.showToReviewInMenuBar"
    static let organizations = "ado.organizations"
    static let knownOrganizations = "ado.knownOrganizations"
    static let hasDiscovered = "ado.hasDiscoveredOrganizations"
    static let seen = "ado.seenState"
}

extension BriefBarUI.WidgetSize {
    /// How wide a widget needs to be for pull requests, at this size.
    var width: CGFloat { self == .compact ? 290 : 330 }
}
