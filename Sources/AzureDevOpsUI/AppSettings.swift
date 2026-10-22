import AzureDevOpsCore
import BriefBarUI
import Combine
import Foundation

/// Azure DevOps' settings, and which pull requests you've seen, in BriefBar's preferences. Nothing from Notification
/// Center goes there: the links people sent you in chats, and what you've seen of the pull requests listed only
/// because of them, stay in memory, since any program running as you can read the preferences.
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
    /// Looks for pull request links in the notifications every app posts, such as Teams. Off by default:
    /// it reads Notification Center, which needs Full Disk Access. Turning it off forgets every link found.
    @Published var chatLinksEnabled: Bool {
        didSet {
            defaults.set(chatLinksEnabled, forKey: Key.chatLinksEnabled)
            if !chatLinksEnabled { forgetChatLinks() }
        }
    }
    /// The links found so far: who sent which pull request, in which app and when. Never the messages. They're kept in
    /// memory only, and only while the feature is on: after a restart, BriefBar finds again only those whose
    /// notifications Notification Center still has.
    @Published private(set) var chatLinks: ChatLinkState
    /// The team whose sprint the Sprint section shows; nil until it's chosen, or found.
    @Published var sprintTeam: TeamRef? {
        didSet { Self.store(sprintTeam, in: defaults, forKey: Key.sprintTeam) }
    }
    /// Only your stories and tasks in the Sprint section.
    @Published var sprintJustMine: Bool {
        didSet { defaults.set(sprintJustMine, forKey: Key.sprintJustMine) }
    }
    /// The pipelines in the Pipelines section, in the order you pinned them.
    @Published var pinnedPipelines: [PipelineRef] {
        didSet { Self.store(pinnedPipelines, in: defaults, forKey: Key.pinnedPipelines) }
    }
    /// What the account signed in now has seen.
    @Published private(set) var seen: SeenState
    /// When you last looked at each pull request that's listed only because someone sent it to you (`PRKey.description`),
    /// in memory only, like the links: in the preferences, it would say which pull requests people sent you.
    @Published private(set) var seenSentInChats: [String: Date] = [:]
    /// What the other accounts you've signed in with have seen.
    private var otherSeen: [String: SeenState]

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
        chatLinksEnabled = defaults.bool(forKey: Key.chatLinksEnabled)
        sprintTeam = Self.load(TeamRef.self, from: defaults, forKey: Key.sprintTeam)
        sprintJustMine = defaults.bool(forKey: Key.sprintJustMine)
        pinnedPipelines = Self.load([PipelineRef].self, from: defaults, forKey: Key.pinnedPipelines) ?? []
        chatLinks = ChatLinkState()
        // Where 0.1.0 kept the links, which any program running as you could read: gone, whatever the setting.
        defaults.removeObject(forKey: Key.chatLinks)

        otherSeen = defaults.data(forKey: Key.otherSeen).flatMap { try? JSONDecoder().decode([String: SeenState].self, from: $0) } ?? [:]
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

    /// Forgets what you've seen, with every account, and the pull requests people sent you, when Azure DevOps
    /// is turned off. Your organizations, and whether to look for pull requests sent in chats, stay.
    func forgetSeen() {
        defaults.removeObject(forKey: Key.seen)
        defaults.removeObject(forKey: Key.otherSeen)
        hasSavedSeen = false
        seen = SeenState.firstRun()
        otherSeen = [:]
        forgetChatLinks()
    }

    private static func load<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, forKey key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private static func store<T: Encodable>(_ value: T?, in defaults: UserDefaults, forKey key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
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

    func markSeen<S: Sequence>(_ keys: S, at date: Date = Date(), sentInChats: Set<PRKey> = []) where S.Element == PRKey {
        markSeen(keys.map { ($0, date) }, sentInChats: sentInChats)
    }

    /// Each pull request seen up to its own time. Those in `sentInChats`, listed only because someone sent them to
    /// you, are remembered in memory only, and leave the preferences if an earlier version saved them there.
    func markSeen(_ entries: [(key: PRKey, date: Date)], sentInChats: Set<PRKey> = []) {
        keepSeenInMemory(sentInChats)
        var updated = seen
        var inMemory = seenSentInChats
        for entry in entries {
            if sentInChats.contains(entry.key) {
                inMemory[entry.key.description] = max(entry.date, inMemory[entry.key.description] ?? .distantPast)
            } else {
                updated.markSeen([entry.key], at: entry.date)
            }
        }
        if inMemory != seenSentInChats { seenSentInChats = inMemory }
        guard updated != seen else { return }
        seen = updated
        persistSeen()
    }

    /// When you last looked at a pull request, as far as BriefBar remembers: in the preferences, or in memory.
    func seenCutoff(for key: PRKey) -> Date {
        max(seen.cutoff(for: key), seenSentInChats[key.description] ?? .distantPast)
    }

    /// Moves what the preferences say you've seen of these pull requests, listed only because someone sent them to
    /// you, into memory. 0.1.0 kept that in the preferences.
    func keepSeenInMemory(_ keys: Set<PRKey>) {
        let saved = keys.compactMap { key in seen.seenAt[key.description].map { (key: key.description, date: $0) } }
        guard !saved.isEmpty else { return }
        var inMemory = seenSentInChats
        var updated = seen
        for entry in saved {
            inMemory[entry.key] = max(entry.date, inMemory[entry.key] ?? .distantPast)
            updated.seenAt[entry.key] = nil
        }
        seenSentInChats = inMemory
        seen = updated
        persistSeen()
    }

    /// Forgets pull requests that are no longer listed and were last seen over two months ago.
    func pruneSeen(keeping keys: Set<PRKey>, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-60 * 86_400)
        let kept = Set(keys.map(\.description))
        let inMemory = seenSentInChats.filter { kept.contains($0.key) || $0.value > cutoff }
        if inMemory != seenSentInChats { seenSentInChats = inMemory }
        var updated = seen
        updated.prune(keeping: keys, olderThan: cutoff)
        guard updated != seen else { return }
        seen = updated
        persistSeen()
    }

    /// Keeps newly found links, in memory, while the feature is on. Returns whether there were any.
    @discardableResult
    func addChatLinks(_ found: [ChatLink], now: Date = Date()) -> Bool {
        guard chatLinksEnabled else { return false }
        var updated = chatLinks
        let changed = updated.merge(ChatLinkState.canonical(found, organizations: organizations))
        let pruned = updated.prune(now: now)
        guard changed || pruned else { return false }
        chatLinks = updated
        return changed
    }

    /// Forgets every link found, and what you've seen of the pull requests listed only because of them.
    func forgetChatLinks() {
        if !chatLinks.links.isEmpty { chatLinks = ChatLinkState() }
        if !seenSentInChats.isEmpty { seenSentInChats = [:] }
    }

    /// Replaces the seen state, for the demo and for pictures.
    func useSeenState(_ state: SeenState, others: [String: SeenState] = [:]) {
        otherSeen = others
        seen = state
    }

    /// Switches what you've seen to the account signed in now, keeping the last one's for when it's back. Returns
    /// whether another account was signed in before.
    func useAccount(_ account: String, now: Date = Date()) -> Bool {
        var book = SeenBook(current: seen, others: otherSeen)
        let switched = book.signIn(account, now: now)
        // What the last account saw of pull requests sent in chats was its own, and is kept in memory only.
        if switched, !seenSentInChats.isEmpty { seenSentInChats = [:] }
        guard book.current != seen else { return switched }
        otherSeen = book.others
        seen = book.current
        persistSeen()
        if let data = try? JSONEncoder().encode(otherSeen) {
            defaults.set(data, forKey: Key.otherSeen)
        }
        return switched
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
    static let otherSeen = "ado.otherAccountsSeenState"
    static let chatLinksEnabled = "ado.chatLinksEnabled"
    /// Where 0.1.0 kept the links sent in chats. Nothing writes it now: the app removes it at launch.
    static let chatLinks = "ado.chatLinks"
    static let sprintTeam = "ado.sprintTeam"
    static let sprintJustMine = "ado.sprintJustMine"
    static let pinnedPipelines = "ado.pinnedPipelines"
}

extension BriefBarUI.WidgetSize {
    /// How wide a widget needs to be for pull requests, at this size.
    var width: CGFloat { self == .compact ? 290 : 330 }
}
