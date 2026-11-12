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

    /// The app's preferences, or the demo's: for what other parts of BriefBar keep there, such as whether Send Prompts to
    /// Copilot Sessions is on (`CopilotTasksStore.sessionPromptsAreOn`).
    let defaults: UserDefaults

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
    /// How the pull requests are listed: in their groups, or by when each was created.
    @Published var pullRequestOrder: PROrder {
        didSet { defaults.set(pullRequestOrder.rawValue, forKey: Key.pullRequestOrder) }
    }
    /// Follows the pipelines that run after you merge a pull request, while Done keeps it.
    @Published var followMerges: Bool {
        didSet { defaults.set(followMerges, forKey: Key.followMerges) }
    }
    /// A pull request clicked in the menu bar's list, a widget or a notification shows its details in BriefBar's window,
    /// rather than opening in Azure DevOps. Off by default: they open in Azure DevOps, as they always did.
    @Published var opensPullRequestsInBriefBar: Bool {
        didSet { defaults.set(opensPullRequestsInBriefBar, forKey: Key.opensPullRequestsInBriefBar) }
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
    /// How wide you made a work item's details beside the sprint, in points; nil for their usual width.
    @Published var sprintDetailsWidth: Double? {
        didSet { defaults.set(sprintDetailsWidth, forKey: Key.sprintDetailsWidth) }
    }
    /// How wide you made a pull request's details beside the window's list, in points; nil for their usual width.
    @Published var pullRequestDetailsWidth: Double? {
        didSet { defaults.set(pullRequestDetailsWidth, forKey: Key.pullRequestDetailsWidth) }
    }
    /// What My Work's Board shows, with My Work Page on: your pull requests, as the Board did on the Pull Requests page, or
    /// your sprint work with them.
    @Published var myWorkShows: MyWorkShows {
        didSet { defaults.set(myWorkShows.rawValue, forKey: Key.myWorkShows) }
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
    /// Make Changes in Azure DevOps: your replies in pull requests' comment threads, and their statuses, from their details,
    /// each when you click it (`ADOWrite`). Off by default: BriefBar then writes nothing to Azure DevOps, and threads show
    /// neither.
    @Published var makesChanges: Bool {
        didSet { defaults.set(makesChanges, forKey: Key.makesChanges) }
    }
    /// The tags you added to pull requests, with Make Changes in Azure DevOps on, which adding one suggests: for each project,
    /// by its ID, the latest first. Turning the setting off forgets them.
    @Published var usedTags: UsedTags {
        didSet { Self.store(usedTags.isEmpty ? nil : usedTags, in: defaults, forKey: Key.usedTags) }
    }
    /// The model Fix Grammar corrects a reply with: Apple Intelligence, on this Mac, unless you chose one through Copilot.
    @Published var grammarModel: String {
        didSet { defaults.set(grammarModel, forKey: Key.grammarModel) }
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
    /// Where a work item's new session starts, unless you choose otherwise as you send it: in the Copilot app, where you
    /// can follow and steer it, or with the Copilot CLI, on its own. The app, until you choose; it can start there only
    /// while Send Prompts to Copilot Sessions is on and the app is on this Mac (`CopilotTasksStore.startsInApp`).
    @Published var copilotNewSessionsInApp: Bool {
        didSet { defaults.set(copilotNewSessionsInApp, forKey: Key.copilotNewSessionsInApp) }
    }
    /// Push and Reply, in a comment's Fix and in Fix All, as you last left it: on, a fix then commits, pushes and replies on
    /// the threads it fixed, as Push & Reply does (`CopilotSending.commentFix`); off, as it starts, it leaves its changes
    /// for you to check, then push with Push & Reply.
    @Published var copilotFixesPushAndReply: Bool {
        didSet { defaults.set(copilotFixesPushAndReply, forKey: Key.copilotFixesPushAndReply) }
    }
    /// The Copilot session you chose for each pull request's work, or a new session, and when: references only, never names
    /// (`PullRequestSessionChoice`).
    @Published var copilotPullRequestSessions: [PullRequestSessionChoice] {
        didSet { Self.store(copilotPullRequestSessions.isEmpty ? nil : copilotPullRequestSessions, in: defaults, forKey: Key.copilotPullRequestSessions) }
    }
    /// The prompts about pull requests' comment threads sent to the Copilot app's sessions, or copied for you to paste
    /// there: which session, which threads, what for and when, references only, never what they say (`SentPrompt`).
    @Published var copilotSentPrompts: [SentPrompt] {
        didSet { Self.store(copilotSentPrompts.isEmpty ? nil : copilotSentPrompts, in: defaults, forKey: Key.copilotSentPrompts) }
    }
    /// The tasks sent to Copilot: which work item, where and with which model, not titles or what Copilot wrote.
    @Published var copilotRuns: [CopilotRun] {
        didSet { Self.store(copilotRuns, in: defaults, forKey: Key.copilotRuns) }
    }
    /// The forks of Copilot sessions that BriefBar made and couldn't delete yet, by their sessions' IDs and their CLI's
    /// folder, nothing else: each is deleted before the next question, fork or task (`LeftoverForks`).
    private(set) var copilotForksToDelete: [LeftoverFork] {
        didSet { Self.store(copilotForksToDelete, in: defaults, forKey: Key.copilotForksToDelete) }
    }
    /// What the account signed in now has seen.
    @Published private(set) var seen: SeenState
    /// Where that account is from (`AccessToken.accountTenant`), so that after a restart, your own directory wanting you to
    /// sign in again isn't taken for someone else's sign-in.
    var accountOrigin: String? {
        get { defaults.string(forKey: Key.accountOrigin) }
        set { defaults.set(newValue, forKey: Key.accountOrigin) }
    }
    /// Your sign-in's directory, as BriefBar last read with it, whichever section did: so that after a restart, signing in
    /// to another directory, which makes that one the Azure CLI's default, doesn't read you there instead.
    var accountDirectory: String? {
        get { defaults.string(forKey: Key.accountDirectory) }
        set { defaults.set(newValue, forKey: Key.accountDirectory) }
    }
    /// The directory to ask the Azure CLI for your tokens in: the one kept, or, from builds that kept none, the directory
    /// of the account that saw your pull requests.
    var pinnedDirectory: String? {
        accountDirectory ?? seen.account.flatMap(AccessToken.tenant(ofAccount:))
    }
    /// When you last looked at each pull request that's listed only because someone sent it to you (`SeenState.name(of:)`),
    /// in memory only, like the links: in the preferences, it would say which pull requests people sent you.
    @Published private(set) var seenSentInChats: [String: Date] = [:]
    /// When you last removed each of those from Needs You, in memory only too.
    @Published private(set) var dismissedSentInChats: [String: Date] = [:]
    /// The comment threads you marked as read in each of those, and up to when (`SeenState.readThreads`), in memory only
    /// too.
    @Published private(set) var readSentInChats: [String: [Int: Date]] = [:]
    /// Which comment threads a pull request's details show: all of them, or only the active ones. The same for every pull
    /// request, and kept: All until you choose.
    @Published var commentFilter: PullRequestPanel.CommentFilter {
        didSet { defaults.set(commentFilter.rawValue, forKey: Key.commentFilter) }
    }
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
        pullRequestOrder = defaults.string(forKey: Key.pullRequestOrder).flatMap(PROrder.init(rawValue:)) ?? .status
        followMerges = defaults.object(forKey: Key.followMerges) as? Bool ?? true
        opensPullRequestsInBriefBar = defaults.bool(forKey: Key.opensPullRequestsInBriefBar)
        watchedPullRequests = Self.load([PullRequestLink].self, from: defaults, forKey: Key.watchedPullRequests) ?? []
        organizations = defaults.stringArray(forKey: Key.organizations) ?? []
        knownOrganizations = defaults.stringArray(forKey: Key.knownOrganizations) ?? []
        hasDiscovered = defaults.bool(forKey: Key.hasDiscovered)
        chatLinksEnabled = defaults.bool(forKey: Key.chatLinksEnabled)
        sprintTeam = Self.load(TeamRef.self, from: defaults, forKey: Key.sprintTeam)
        sprintJustMine = defaults.bool(forKey: Key.sprintJustMine)
        sprintDetailsWidth = Self.width(defaults.object(forKey: Key.sprintDetailsWidth))
        pullRequestDetailsWidth = Self.width(defaults.object(forKey: Key.pullRequestDetailsWidth))
        myWorkShows = defaults.string(forKey: Key.myWorkShows).flatMap(MyWorkShows.init(rawValue:)) ?? .pullRequests
        pinnedPipelines = Self.load([PipelineRef].self, from: defaults, forKey: Key.pinnedPipelines) ?? []
        copilotEnabled = defaults.bool(forKey: Key.copilotEnabled)
        makesChanges = defaults.bool(forKey: Key.makesChanges)
        usedTags = Self.load(UsedTags.self, from: defaults, forKey: Key.usedTags) ?? UsedTags()
        grammarModel = defaults.string(forKey: Key.grammarModel).flatMap { $0.isEmpty ? nil : $0 } ?? StorySummaries.appleIntelligenceModel
        copilotOptions = Self.load(CopilotRunOptions.self, from: defaults, forKey: Key.copilotOptions) ?? CopilotModel.standard
        copilotQuickOptions = Self.load(CopilotRunOptions.self, from: defaults, forKey: Key.copilotQuickOptions) ?? CopilotModel.quick
        copilotPrompt = defaults.string(forKey: Key.copilotPrompt)
        let pullRequestSessions = PullRequestSessionChoice.load(from: defaults, now: now)
        // Those that expired, or that another program wrote there, leave the preferences too.
        PullRequestSessionChoice.prune(to: pullRequestSessions, in: defaults)
        copilotPullRequestSessions = pullRequestSessions
        copilotRepositories = defaults.dictionary(forKey: Key.copilotRepositories) as? [String: String] ?? [:]
        copilotWorktreesFolder = defaults.string(forKey: Key.copilotWorktreesFolder)
        copilotNewSessionsInApp = defaults.object(forKey: Key.copilotNewSessionsInApp) as? Bool ?? true
        copilotFixesPushAndReply = defaults.bool(forKey: Key.copilotFixesPushAndReply)
        // Any program running as you can write the preferences: a run whose ID isn't a session's is left out, and so is a
        // fork's.
        copilotRuns = (Self.load([CopilotRun].self, from: defaults, forKey: Key.copilotRuns) ?? []).filter(\.isValid)
        copilotForksToDelete = (Self.load([LeftoverFork].self, from: defaults, forKey: Key.copilotForksToDelete) ?? []).filter(\.isValid)
        let sentPrompts = SentPrompt.load(from: defaults, now: now)
        // Those that are done with, or that another program wrote there, leave the preferences too.
        SentPrompt.prune(to: sentPrompts, in: defaults)
        copilotSentPrompts = sentPrompts
        chatLinks = ChatLinkState()
        // Where earlier builds kept the links, which any program running as you could read: gone, whatever the setting.
        defaults.removeObject(forKey: Key.chatLinks)
        commentFilter = defaults.string(forKey: Key.commentFilter).flatMap(PullRequestPanel.CommentFilter.init(rawValue:)) ?? .all

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

    /// Forgets what you've seen, with every account, where that account is from and its directory, and the pull requests
    /// people sent you, when Azure DevOps is turned off. Your organizations, and whether to look for pull requests sent in
    /// chats, stay.
    func forgetSeen() {
        defaults.removeObject(forKey: Key.seen)
        defaults.removeObject(forKey: Key.otherSeen)
        defaults.removeObject(forKey: Key.accountOrigin)
        defaults.removeObject(forKey: Key.accountDirectory)
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
    /// branches and sessions stay: they're your work. The forks still to delete stay too, to delete once it's on again.
    func forgetCopilotRuns() {
        copilotRuns = []
        copilotRepositories = [:]
        // And the sessions you chose for pull requests' work, and the prompts sent to sessions about their threads.
        copilotPullRequestSessions = []
        copilotSentPrompts = []
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

    /// A width kept in the preferences, in points; nil for anything that isn't one, which any program running as you
    /// could put there.
    private static func width(_ value: Any?) -> Double? {
        (value as? Double).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
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
            let key = SeenState.name(of: entry.key)
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
        max(seen.cutoff(for: key), seenSentInChats[SeenState.name(of: key)] ?? .distantPast)
    }

    /// When you last looked at a pull request yourself: opened it from BriefBar, saw its details or marked it seen. Nil when
    /// you never did, even though what came before BriefBar's first days counts as seen.
    func lastLooked(at key: PRKey) -> Date? {
        let name = SeenState.name(of: key)
        return [seen.seenAt[name], seenSentInChats[name]].compactMap { $0 }.max()
    }

    /// The Azure CLI account whose seen state is in use, once known: what you see and take off Needs You now is its own.
    var account: String? { seen.account }

    /// Takes your own pull requests off Needs You, as `dismiss` does, for `account`: the one signed in now, or another
    /// you've signed in with, whose state keeps it for when it signs in again. One account's comments never leave
    /// another's Needs You, and nothing changes for an account BriefBar doesn't remember, or can't tell from this one.
    func dismiss(_ entries: [(key: PRKey, date: Date)], for account: String?) {
        guard account != seen.account else {
            dismiss(entries)
            return
        }
        guard let account, var other = otherSeen[account] else { return }
        for entry in entries {
            other.dismiss([entry.key], at: entry.date)
        }
        guard other != otherSeen[account] else { return }
        otherSeen[account] = other
        persistOtherSeen()
    }

    /// Up to when the comments that wait on you in a pull request don't need you anymore: when you last removed it from
    /// Needs You, or sent them to Copilot.
    func dismissedCutoff(for key: PRKey) -> Date {
        max(seen.dismissedCutoff(for: key), dismissedSentInChats[SeenState.name(of: key)] ?? .distantPast)
    }

    /// The comment threads of a pull request you marked as read, by their IDs, and up to when, as far as BriefBar remembers:
    /// in the preferences, or in memory.
    func readThreads(of key: PRKey) -> [Int: Date] {
        seen.readThreads(of: key).merging(readSentInChats[SeenState.name(of: key)] ?? [:]) { max($0, $1) }
    }

    /// Marks one of a pull request's comment threads as read, up to `date`, the latest comment in it as you did, for
    /// `account`: the one signed in now, or another you've signed in with, whose state keeps it for when it signs in again,
    /// as `dismiss(_:for:)` does. One account's mark never takes a thread off another's Needs You, and nothing changes for
    /// an account BriefBar doesn't remember. For a pull request listed only because someone sent it to you
    /// (`sentInChat`), it's kept in memory only, as what you've seen of it, and only for the account signed in now.
    func markRead(_ thread: Int, of key: PRKey, upTo date: Date, for account: String?, sentInChat: Bool = false) {
        changeRead(of: key, for: account, sentInChat: sentInChat) { $0.markRead(thread, of: key, upTo: date) }
    }

    /// Puts a thread back as it was read before you marked it, as Mark as Unread does: up to `date`, or, for nil, not
    /// marked as read; for `account`, where `markRead` keeps it now (`sentInChat`). A pull request can move between the
    /// two since, as one you stop watching that someone also sent you does, into memory: the mark it had in the other
    /// goes too.
    func setRead(_ thread: Int, of key: PRKey, to date: Date?, for account: String?, sentInChat: Bool = false) {
        if account == seen.account {
            let name = SeenState.name(of: key)
            if !sentInChat, readSentInChats[name]?[thread] != nil {
                var inMemory = SeenState(baseline: seen.baseline, readThreads: readSentInChats.filter { $0.key == name })
                inMemory.setRead(thread, of: key, to: nil)
                readSentInChats[name] = inMemory.readThreads[name]
            }
            if sentInChat, seen.readThreads[name]?[thread] != nil {
                var updated = seen
                updated.setRead(thread, of: key, to: nil)
                seen = updated
                persistSeen()
            }
        }
        changeRead(of: key, for: account, sentInChat: sentInChat) { $0.setRead(thread, of: key, to: date) }
    }

    /// The comment threads of a pull request that `account` marked as read: the one signed in now, as `readThreads(of:)`
    /// has them, or another you've signed in with; nil for one BriefBar doesn't remember.
    func readThreads(of key: PRKey, for account: String?) -> [Int: Date]? {
        guard account != seen.account else { return readThreads(of: key) }
        return account.flatMap { otherSeen[$0] }?.readThreads(of: key)
    }

    private func changeRead(of key: PRKey, for account: String?, sentInChat: Bool, _ change: (inout SeenState) -> Void) {
        let name = SeenState.name(of: key)
        if sentInChat {
            guard account == seen.account else { return }
            // What an earlier build kept of it in the preferences, in memory first.
            keepSeenInMemory([key])
            var state = SeenState(baseline: seen.baseline, readThreads: readSentInChats.filter { $0.key == name })
            change(&state)
            var inMemory = readSentInChats
            inMemory[name] = state.readThreads[name]
            if inMemory != readSentInChats { readSentInChats = inMemory }
            return
        }
        guard account != seen.account else {
            var updated = seen
            change(&updated)
            guard updated != seen else { return }
            seen = updated
            persistSeen()
            return
        }
        guard let account, var other = otherSeen[account] else { return }
        change(&other)
        guard other != otherSeen[account] else { return }
        otherSeen[account] = other
        persistOtherSeen()
    }

    /// Moves what the preferences say you've seen of these pull requests, listed only because someone sent them to
    /// you, into memory: and when you removed them from Needs You, and the threads you marked as read there. Earlier builds
    /// kept that in the preferences.
    func keepSeenInMemory(_ keys: Set<PRKey>) {
        let names = keys.map { SeenState.name(of: $0) }.filter {
            seen.seenAt[$0] != nil || seen.dismissedAt[$0] != nil || seen.readThreads[$0] != nil
        }
        guard !names.isEmpty else { return }
        var seenInMemory = seenSentInChats
        var dismissedInMemory = dismissedSentInChats
        var readInMemory = readSentInChats
        var updated = seen
        for name in names {
            if let date = updated.seenAt.removeValue(forKey: name) {
                seenInMemory[name] = max(date, seenInMemory[name] ?? .distantPast)
            }
            if let date = updated.dismissedAt.removeValue(forKey: name) {
                dismissedInMemory[name] = max(date, dismissedInMemory[name] ?? .distantPast)
            }
            if let threads = updated.readThreads.removeValue(forKey: name) {
                readInMemory[name, default: [:]].merge(threads) { max($0, $1) }
            }
        }
        if seenInMemory != seenSentInChats { seenSentInChats = seenInMemory }
        if dismissedInMemory != dismissedSentInChats { dismissedSentInChats = dismissedInMemory }
        if readInMemory != readSentInChats { readSentInChats = readInMemory }
        seen = updated
        persistSeen()
    }

    /// Forgets pull requests that are no longer listed and were last seen over two months ago. When you took one off Needs
    /// You, and the threads you marked as read there, are forgotten with when you last looked at it, in the preferences and
    /// in memory alike (`SeenState.pruned`).
    func pruneSeen(keeping keys: Set<PRKey>, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-60 * 86_400)
        let inMemory = SeenState.pruned(
            seenAt: seenSentInChats, dismissedAt: dismissedSentInChats, readThreads: readSentInChats, keeping: keys, olderThan: cutoff
        )
        if inMemory.seenAt != seenSentInChats { seenSentInChats = inMemory.seenAt }
        if inMemory.dismissedAt != dismissedSentInChats { dismissedSentInChats = inMemory.dismissedAt }
        if inMemory.readThreads != readSentInChats { readSentInChats = inMemory.readThreads }
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
        if !readSentInChats.isEmpty { readSentInChats = [:] }
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
        if switched, !readSentInChats.isEmpty { readSentInChats = [:] }
        guard book.current != seen else { return switched }
        otherSeen = book.others
        seen = book.current
        persistSeen()
        persistOtherSeen()
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

    private func persistOtherSeen() {
        if let data = try? JSONEncoder().encode(otherSeen) {
            defaults.set(data, forKey: Key.otherSeen)
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
    static let pullRequestOrder = "ado.pullRequestOrder"
    static let followMerges = "ado.followMerges"
    static let opensPullRequestsInBriefBar = "ado.opensPullRequestsInBriefBar"
    static let watchedPullRequests = "ado.watchedPullRequests"
    static let organizations = "ado.organizations"
    static let knownOrganizations = "ado.knownOrganizations"
    static let hasDiscovered = "ado.hasDiscoveredOrganizations"
    static let seen = "ado.seenState"
    static let otherSeen = "ado.otherAccountsSeenState"
    /// Where the account BriefBar last read your pull requests with is from (`AccessToken.accountTenant`): a directory's
    /// ID, or an identity provider such as live.com.
    static let accountOrigin = "ado.accountOrigin"
    /// Your sign-in's directory, as BriefBar last read with it (`AccessToken.tenant`): a directory's ID.
    static let accountDirectory = "ado.accountDirectory"
    static let chatLinksEnabled = "ado.chatLinksEnabled"
    /// Where earlier builds kept the links sent in chats. Nothing writes it now: the app removes it at launch.
    static let chatLinks = "ado.chatLinks"
    static let sprintTeam = "ado.sprintTeam"
    static let sprintJustMine = "ado.sprintJustMine"
    static let sprintDetailsWidth = "ado.sprintDetailsWidth"
    static let pullRequestDetailsWidth = "ado.pullRequestDetailsWidth"
    static let myWorkShows = "ado.myWorkShows"
    /// Which comment threads a pull request's details show: `active` or `all`.
    static let commentFilter = "ado.commentFilter"
    static let pinnedPipelines = "ado.pinnedPipelines"
    static let copilotEnabled = "ado.copilot.enabled"
    static let makesChanges = "ado.makeChanges"
    static let usedTags = "ado.usedTags"
    static let grammarModel = "ado.grammar.model"
    static let copilotOptions = "ado.copilot.options"
    static let copilotQuickOptions = "ado.copilot.quickOptions"
    static let copilotPrompt = "ado.copilot.prompt"
    static let copilotPullRequestSessions = "ado.copilot.pullRequestSessions"
    static let copilotRepositories = "ado.copilot.repositories"
    static let copilotWorktreesFolder = "ado.copilot.worktreesFolder"
    /// Where a new session starts, unless you choose otherwise (`AppSettings.copilotNewSessionsInApp`).
    static let copilotNewSessionsInApp = "ado.copilot.newSessionsInApp"
    /// Push and Reply in a comment's Fix and in Fix All, as you last left it (`AppSettings.copilotFixesPushAndReply`).
    static let copilotFixesPushAndReply = "ado.copilot.fixesPushAndReply"
    static let copilotRuns = "ado.copilot.runs"
    static let copilotForksToDelete = "ado.copilot.forksToDelete"
    static let copilotSentPrompts = "ado.copilot.sentPrompts"
}

/// The forks BriefBar couldn't delete yet are kept with its runs, so that none is left behind when it quits first.
extension AppSettings: LeftoverForks {
    func leftoverForks() async -> [LeftoverFork] {
        copilotForksToDelete
    }

    func keepLeftoverFork(_ fork: LeftoverFork) async {
        guard fork.isValid, !copilotForksToDelete.contains(fork) else { return }
        copilotForksToDelete.append(fork)
    }

    func dropLeftoverFork(_ fork: LeftoverFork) async {
        copilotForksToDelete.removeAll { $0 == fork }
    }
}

extension BriefBarUI.WidgetSize {
    /// How wide a widget needs to be for pull requests, at this size.
    var width: CGFloat { self == .compact ? 290 : 330 }
}
