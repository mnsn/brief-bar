import AzureDevOpsCore
import BriefBarUI
import Combine
import CopilotTasks
import Foundation

/// Azure DevOps' settings, and which pull requests you've seen or removed from Needs You, in BriefBar's preferences.
/// Nothing from Notification Center goes there: the links people sent you in chats, and what you've seen of the pull
/// requests listed only because of them, stay in memory, since any program running as you can read the preferences.
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
    /// Follows the pipelines that run after you merge a pull request, while Done keeps it.
    @Published var followMerges: Bool {
        didSet { defaults.set(followMerges, forKey: Key.followMerges) }
    }
    /// Pull requests you watch by their links, though you're not on them: listed as if you reviewed them, until
    /// they close or you stop watching them.
    @Published var watchedPullRequests: [PullRequestLink] {
        didSet { Self.store(watchedPullRequests, in: defaults, forKey: Key.watchedPullRequests) }
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
    /// Send Work to Copilot: a button on the sprint's work items that hands one to the Copilot CLI on this Mac. Off by
    /// default: Copilot then changes code, pushes a branch and opens a pull request, as you.
    @Published var copilotEnabled: Bool {
        didSet { defaults.set(copilotEnabled, forKey: Key.copilotEnabled) }
    }
    /// What a task is sent with, unless you choose otherwise.
    @Published var copilotOptions: CopilotRunOptions {
        didSet { Self.store(copilotOptions, in: defaults, forKey: Key.copilotOptions) }
    }
    /// What an easy task is sent with.
    @Published var copilotQuickOptions: CopilotRunOptions {
        didSet { Self.store(copilotQuickOptions, in: defaults, forKey: Key.copilotQuickOptions) }
    }
    /// The prompt, with placeholders (`PromptTemplate`); nil for the standard one, which then follows updates.
    @Published var copilotPrompt: String? {
        didSet { defaults.set(copilotPrompt, forKey: Key.copilotPrompt) }
    }
    /// The repository each project's work went in last (`WorkItemReference.projectKey`), as a folder's path.
    @Published var copilotRepositories: [String: String] {
        didSet { defaults.set(copilotRepositories, forKey: Key.copilotRepositories) }
    }
    /// Where worktrees go; next to each repository when nil.
    @Published var copilotWorktreesFolder: String? {
        didSet { defaults.set(copilotWorktreesFolder, forKey: Key.copilotWorktreesFolder) }
    }
    /// The tasks sent to Copilot: which work item, where and with which model, not titles or what Copilot wrote.
    @Published var copilotRuns: [CopilotRun] {
        didSet { Self.store(copilotRuns, in: defaults, forKey: Key.copilotRuns) }
    }
    /// What the account signed in now has seen.
    @Published private(set) var seen: SeenState
    /// When you last looked at each pull request that's listed only because someone sent it to you (`PRKey.description`),
    /// in memory only, like the links: in the preferences, it would say which pull requests people sent you.
    @Published private(set) var seenSentInChats: [String: Date] = [:]
    /// When you last removed each of those from Needs You, in memory only too.
    @Published private(set) var dismissedSentInChats: [String: Date] = [:]
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
        followMerges = defaults.object(forKey: Key.followMerges) as? Bool ?? true
        watchedPullRequests = Self.load([PullRequestLink].self, from: defaults, forKey: Key.watchedPullRequests) ?? []
        organizations = defaults.stringArray(forKey: Key.organizations) ?? []
        knownOrganizations = defaults.stringArray(forKey: Key.knownOrganizations) ?? []
        hasDiscovered = defaults.bool(forKey: Key.hasDiscovered)
        chatLinksEnabled = defaults.bool(forKey: Key.chatLinksEnabled)
        sprintTeam = Self.load(TeamRef.self, from: defaults, forKey: Key.sprintTeam)
        sprintJustMine = defaults.bool(forKey: Key.sprintJustMine)
        pinnedPipelines = Self.load([PipelineRef].self, from: defaults, forKey: Key.pinnedPipelines) ?? []
        copilotEnabled = defaults.bool(forKey: Key.copilotEnabled)
        copilotOptions = Self.load(CopilotRunOptions.self, from: defaults, forKey: Key.copilotOptions) ?? CopilotModel.standard
        copilotQuickOptions = Self.load(CopilotRunOptions.self, from: defaults, forKey: Key.copilotQuickOptions) ?? CopilotModel.quick
        copilotPrompt = defaults.string(forKey: Key.copilotPrompt)
        copilotRepositories = defaults.dictionary(forKey: Key.copilotRepositories) as? [String: String] ?? [:]
        copilotWorktreesFolder = defaults.string(forKey: Key.copilotWorktreesFolder)
        // Any program running as you can write the preferences: a run whose ID isn't a session's is left out.
        copilotRuns = (Self.load([CopilotRun].self, from: defaults, forKey: Key.copilotRuns) ?? []).filter(\.isValid)
        chatLinks = ChatLinkState()
        // Where earlier builds kept the links, which any program running as you could read: gone, whatever the setting.
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

    /// The prompt tasks are sent with.
    var copilotPromptTemplate: String {
        copilotPrompt ?? PromptTemplate.standard
    }

    /// Forgets the tasks sent to Copilot, and the repositories their work went in, when Azure DevOps is turned off.
    /// What Copilot printed for them is deleted with them (`CopilotTasksStore.deleteOutput`). Copilot's worktrees,
    /// branches and sessions stay: they're your work.
    func forgetCopilotRuns() {
        copilotRuns = []
        copilotRepositories = [:]
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
            inactiveAfter: idleDays > 0 ? TimeInterval(idleDays) * 86_400 : nil,
            followMerges: followMerges
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
    /// you, are remembered in memory only, and leave the preferences if an earlier build saved them there.
    func markSeen(_ entries: [(key: PRKey, date: Date)], sentInChats: Set<PRKey> = []) {
        update(entries, sentInChats: sentInChats, dismissing: false)
    }

    /// Removes each pull request from Needs You up to its own time, which sees it too: the comments that waited on you
    /// there don't anymore, and what comes after needs you again. Those in `sentInChats` are remembered in memory only,
    /// as for what you've seen.
    func dismiss(_ entries: [(key: PRKey, date: Date)], sentInChats: Set<PRKey> = []) {
        update(entries, sentInChats: sentInChats, dismissing: true)
    }

    private func update(_ entries: [(key: PRKey, date: Date)], sentInChats: Set<PRKey>, dismissing: Bool) {
        keepSeenInMemory(sentInChats)
        var updated = seen
        var seenInMemory = seenSentInChats
        var dismissedInMemory = dismissedSentInChats
        for entry in entries {
            let key = entry.key.description
            if sentInChats.contains(entry.key) {
                seenInMemory[key] = max(entry.date, seenInMemory[key] ?? .distantPast)
                if dismissing { dismissedInMemory[key] = max(entry.date, dismissedInMemory[key] ?? .distantPast) }
            } else if dismissing {
                updated.dismiss([entry.key], at: entry.date)
            } else {
                updated.markSeen([entry.key], at: entry.date)
            }
        }
        if seenInMemory != seenSentInChats { seenSentInChats = seenInMemory }
        if dismissedInMemory != dismissedSentInChats { dismissedSentInChats = dismissedInMemory }
        guard updated != seen else { return }
        seen = updated
        persistSeen()
    }

    /// When you last looked at a pull request, as far as BriefBar remembers: in the preferences, or in memory.
    func seenCutoff(for key: PRKey) -> Date {
        max(seen.cutoff(for: key), seenSentInChats[key.description] ?? .distantPast)
    }

    /// Up to when the comments that wait on you in a pull request don't need you anymore: when you last removed it from
    /// Needs You, or sent them to Copilot.
    func dismissedCutoff(for key: PRKey) -> Date {
        max(seen.dismissedCutoff(for: key), dismissedSentInChats[key.description] ?? .distantPast)
    }

    /// Moves what the preferences say you've seen of these pull requests, listed only because someone sent them to
    /// you, into memory: and when you removed them from Needs You. Earlier builds kept that in the preferences.
    func keepSeenInMemory(_ keys: Set<PRKey>) {
        let names = keys.map(\.description).filter { seen.seenAt[$0] != nil || seen.dismissedAt[$0] != nil }
        guard !names.isEmpty else { return }
        var seenInMemory = seenSentInChats
        var dismissedInMemory = dismissedSentInChats
        var updated = seen
        for name in names {
            if let date = updated.seenAt.removeValue(forKey: name) {
                seenInMemory[name] = max(date, seenInMemory[name] ?? .distantPast)
            }
            if let date = updated.dismissedAt.removeValue(forKey: name) {
                dismissedInMemory[name] = max(date, dismissedInMemory[name] ?? .distantPast)
            }
        }
        if seenInMemory != seenSentInChats { seenSentInChats = seenInMemory }
        if dismissedInMemory != dismissedSentInChats { dismissedSentInChats = dismissedInMemory }
        seen = updated
        persistSeen()
    }

    /// Forgets pull requests that are no longer listed and were last seen over two months ago.
    func pruneSeen(keeping keys: Set<PRKey>, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-60 * 86_400)
        let kept = Set(keys.map(\.description))
        let inMemory = seenSentInChats.filter { kept.contains($0.key) || $0.value > cutoff }
        if inMemory != seenSentInChats { seenSentInChats = inMemory }
        let dismissedInMemory = dismissedSentInChats.filter { kept.contains($0.key) || $0.value > cutoff }
        if dismissedInMemory != dismissedSentInChats { dismissedSentInChats = dismissedInMemory }
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
        if !dismissedSentInChats.isEmpty { dismissedSentInChats = [:] }
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
        if switched, !dismissedSentInChats.isEmpty { dismissedSentInChats = [:] }
        guard book.current != seen else { return switched }
        otherSeen = book.others
        seen = book.current
        persistSeen()
        if let data = try? JSONEncoder().encode(otherSeen) {
            defaults.set(data, forKey: Key.otherSeen)
        }
        return switched
    }

    var watchedKeys: Set<PRKey> { Set(watchedPullRequests.map(\.key)) }

    /// Reads again what an agent can change through `--mcp`: the pull requests you watch, and the pipelines you pin.
    func reloadAgentChanges() {
        let watched = Self.load([PullRequestLink].self, from: defaults, forKey: Key.watchedPullRequests) ?? []
        if watched != watchedPullRequests { watchedPullRequests = watched }
        let pinned = Self.load([PipelineRef].self, from: defaults, forKey: Key.pinnedPipelines) ?? []
        if pinned != pinnedPipelines { pinnedPipelines = pinned }
    }

    func isWatching(_ key: PRKey) -> Bool {
        watchedPullRequests.contains { $0.key == key }
    }

    /// Watches a pull request by its link. Returns false if it was watched already.
    @discardableResult
    func watch(_ link: PullRequestLink) -> Bool {
        guard !isWatching(link.key) else { return false }
        watchedPullRequests.append(link)
        return true
    }

    func unwatch(_ keys: Set<PRKey>) {
        guard watchedPullRequests.contains(where: { keys.contains($0.key) }) else { return }
        watchedPullRequests.removeAll { keys.contains($0.key) }
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
    static let followMerges = "ado.followMerges"
    static let watchedPullRequests = "ado.watchedPullRequests"
    static let organizations = "ado.organizations"
    static let knownOrganizations = "ado.knownOrganizations"
    static let hasDiscovered = "ado.hasDiscoveredOrganizations"
    static let seen = "ado.seenState"
    static let otherSeen = "ado.otherAccountsSeenState"
    static let chatLinksEnabled = "ado.chatLinksEnabled"
    /// Where earlier builds kept the links sent in chats. Nothing writes it now: the app removes it at launch.
    static let chatLinks = "ado.chatLinks"
    static let sprintTeam = "ado.sprintTeam"
    static let sprintJustMine = "ado.sprintJustMine"
    static let pinnedPipelines = "ado.pinnedPipelines"
    static let copilotEnabled = "ado.copilot.enabled"
    static let copilotOptions = "ado.copilot.options"
    static let copilotQuickOptions = "ado.copilot.quickOptions"
    static let copilotPrompt = "ado.copilot.prompt"
    static let copilotRepositories = "ado.copilot.repositories"
    static let copilotWorktreesFolder = "ado.copilot.worktreesFolder"
    static let copilotRuns = "ado.copilot.runs"
}

extension BriefBarUI.WidgetSize {
    /// How wide a widget needs to be for pull requests, at this size.
    var width: CGFloat { self == .compact ? 290 : 330 }
}
