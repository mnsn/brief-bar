import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Combine
import CopilotTasks
import Synchronization

/// A task sent to Copilot, as its work item's or pull request's row shows it: getting ready, working, or how it ended.
struct CopilotTaskEntry: Identifiable, Equatable {
    /// The ID of Copilot's session.
    var id: String
    /// The work item it's for, or nil for a pull request's.
    var workItem: WorkItemReference?
    /// The pull request it works on, and what for; nil for a work item's.
    var onPullRequest: PullRequestReference? = nil
    var action: PullRequestAction? = nil
    var options: CopilotRunOptions
    var startedAt: Date
    var status: RunStatus
    /// The pull request it opened, or the one it works on.
    var pullRequest: URL?
    /// Nil while its worktree is getting ready, and when it couldn't start.
    var run: CopilotRun?
    /// What of its pull request it took on, as its run keeps it (`CopilotRun.taken`): what it took on before too, while it
    /// goes on with a session whose changes aren't pushed.
    var taken: [TakenPart]? = nil
    /// The session it forked, when it works in a fork of one.
    var forkedFrom: String? = nil
    /// The Push & Reply tasks that ran in its session before it, as its run keeps them (`CopilotRun.pushes`).
    var pushes: [SessionPush]? = nil
    /// For one that fixes what it took on first (`fixesFirst`), finished: it pushed a commit of its own, as its run keeps
    /// once git in its checkout said so (`CopilotRun.pushed`). Its prompt has it stop before it pushes, as when the tests
    /// don't pass, and finish all the same.
    var pushSeen = false
    /// Its run fixes what it took on first, as the run keeps apart from what it took on, which Clear lets go of
    /// (`CopilotRun.fixes`); not a run it goes on with.
    var runFixes = false

    var workItemURL: URL? {
        workItem.map { ADOEndpoint.workItemPage(organization: $0.organization, project: $0.project, id: $0.id) }
    }

    /// Whether it works on this pull request.
    func isOn(_ key: PRKey) -> Bool {
        onPullRequest?.matches(organization: key.organization, id: key.number) == true
    }

    /// The Azure DevOps pull request it works on, or the one it opened.
    var pullRequestKey: PRKey? {
        if let onPullRequest { return PRKey(onPullRequest.organization, onPullRequest.id) }
        guard let ref = pullRequest.flatMap({ ItemRef.from(link: $0.absoluteString) }), ref.kind == .pullRequest, let number = ref.number
        else { return nil }
        return PRKey(ref.scope, number)
    }

    /// Where its pull request opens, as its menus say it (`ItemRef.Kind.whereItOpens`): "on GitHub" for one there, as a work
    /// item's task opens one where its repository lives; else "in Azure DevOps".
    var whereItsPullRequestOpens: String {
        let kind = pullRequest.flatMap { ItemRef.from(link: $0.absoluteString)?.kind }
        return (kind == .gitHubPullRequest ? ItemRef.Kind.gitHubPullRequest : .pullRequest).whereItOpens
    }

    /// "Open Pull Request in Azure DevOps", or "Open Pull Request on GitHub" for one there, for its menus.
    var openPullRequestTitle: String {
        "Open Pull Request \(whereItsPullRequestOpens)"
    }
}

extension CopilotTaskEntry {
    /// Made-up sends of the demo sprint's tasks, one that opened the demo's coupon pull request and one still working, and a
    /// fix of the demo's failing pull request. Their IDs are sessions', as a send's are.
    static func demo(now: Date) -> [CopilotTaskEntry] {
        let team = DemoData.team
        return [
            CopilotTaskEntry(
                id: "1d6b2c7e-4f0a-4b8e-9c31-5a2e7d8f6b01", workItem: WorkItemReference(organization: team.organization, project: team.projectName, id: 5112),
                options: CopilotModel.standard, startedAt: now.addingTimeInterval(-41 * 60),
                status: RunStatus(phase: .finished, since: now.addingTimeInterval(-12 * 60),
                                  detail: "Coupon totals now round half up, with tests for every currency. Opened pull request 4091."),
                pullRequest: URL(string: "https://dev.azure.com/\(team.organization)/\(team.projectName)/_git/payments-api/pullrequest/4091")
            ),
            CopilotTaskEntry(
                id: "1d6b2c7e-4f0a-4b8e-9c31-5a2e7d8f6b02", workItem: WorkItemReference(organization: team.organization, project: team.projectName, id: 5103),
                options: CopilotModel.quick, startedAt: now.addingTimeInterval(-6 * 60),
                status: RunStatus(phase: .working, detail: "Run the cart tests")
            ),
            // Fixing the demo's failing pull request: its shop-web CI build, which says so.
            CopilotTaskEntry(
                id: "1d6b2c7e-4f0a-4b8e-9c31-5a2e7d8f6b03", workItem: nil,
                onPullRequest: PullRequestReference(organization: DemoData.organization, project: "Storefront", repository: "shop-web",
                                                    id: 4088, sourceBranch: "delivery-estimates"),
                action: .fixBuild, options: CopilotModel.standard, startedAt: now.addingTimeInterval(-9 * 60),
                status: RunStatus(phase: .working, detail: "Run DeliveryEstimateTests"),
                pullRequest: URL(string: "https://dev.azure.com/\(DemoData.organization)/Storefront/_git/shop-web/pullrequest/4088"),
                taken: DemoData.demoPipelines["shop-web CI"].map { [TakenPart(.build($0), since: now.addingTimeInterval(-9 * 60))] }
            ),
        ]
    }
}

extension WorkItem {
    /// What a task sent to Copilot needs to know about it.
    var copilotTask: TaskWorkItem {
        TaskWorkItem(organization: organization, project: project, id: id, type: type, title: title, url: webURL)
    }
}

/// A session Show Links links to a work item or a pull request: by its ID, why, and whether only through a pull request.
struct LinkedSession: Equatable {
    var id: String
    var origins: [LinkOrigin]
    var isThrough: Bool
    /// When it began to tell BriefBar it's working on it, for one that says so (`SessionReport.workingOnBegan`).
    var began: Date? = nil
}

/// Main-thread view model for Send Work to Copilot: sends a work item to the Copilot CLI when you ask, then follows the
/// run from Copilot's own log of its session, until Copilot opens a pull request, and says how it went. Nothing runs
/// unless you send something, nothing is read while the feature is off, and a run goes on when BriefBar quits.
@MainActor
final class CopilotTasksStore: ObservableObject {
    /// Sends getting their worktree ready, and those that couldn't start: in memory only.
    @Published private(set) var pending: [CopilotTaskEntry] = []
    @Published private(set) var statuses: [String: RunStatus] = [:]

    let settings: AppSettings
    let mode: PRStore.Mode
    /// The app's, for the composer's window to look as Settings › Appearance says, and whether Pull Request Order is on.
    weak var services: AppServices?
    /// A work item's title, when the sprint shows it, for notifications.
    var title: (WorkItemReference) -> String? = { _ in nil }
    /// A pull request's title, when the list shows it, for notifications.
    var pullRequestTitle: (PullRequestReference) -> String? = { _ in nil }
    /// A task that takes care of a pull request's comments started, with what its prompt handed off and the prompt you sent:
    /// for the list, to take those comments off Needs You.
    var handedOff: (CommentHandOff, _ prompt: String) -> Void = { _, _ in }
    /// The sessions Show Links links to a work item or a pull request, and why: nothing while it's off.
    var linkedSessions: (ItemRef) -> [LinkedSession] = { _ in [] }
    /// Whether a pull request a task names can show in its details, on the window's Pull Requests page, and showing it
    /// there: whether it could. The source's.
    var canShowPullRequest: (PRKey) -> Bool = { _ in false }
    var showPullRequest: (PRKey) -> Bool = { _ in false }
    /// The branch a pull request merges into now, as the list last read it: a Push & Reply goes only while it's the one its
    /// prompt names, which BriefBar checks the session's merges against (`Git.checkPush(in:source:target:)`), however long
    /// its window was open. Nil when the list doesn't have it. The source's.
    var currentTarget: (PRKey) -> String? = { _ in nil }
    /// Whether a pull request is still open in your lists (`CopilotSending.isOpen`): one completed or abandoned, or that
    /// left them, gets no push from the Send to Copilot window, as from a comment's composer. The source's.
    var pullRequestIsOpen: (PRKey) -> Bool = { _ in true }

    /// Why nothing that pushes may go to a pull request from the Send to Copilot window: it isn't open in your lists anymore.
    /// Nil while it is, or for anything but a push.
    func closedProblem(_ pullRequest: TaskPullRequest?) -> String? {
        guard let pullRequest, !pullRequestIsOpen(PRKey(pullRequest.organization, pullRequest.id)) else { return nil }
        return CopilotSending.pullRequestGone
    }

    /// The branch a pull request merges into now (`currentTarget`), or, when the list doesn't have it, the one it merged
    /// into as the window wrote its prompt.
    func targetNow(of pullRequest: TaskPullRequest) -> String {
        currentTarget(PRKey(pullRequest.organization, pullRequest.id)).flatMap { $0.isEmpty ? nil : $0 } ?? pullRequest.targetBranch
    }

    /// The branch a Push & Reply's pull request merges into now, when the list has read another than the one its prompt
    /// names, and BriefBar checks what it would push against: `targetBranch`, as the window wrote the prompt. Nil while it
    /// merges into that one.
    func retargeted(_ pullRequest: TaskPullRequest) -> String? {
        let now = targetNow(of: pullRequest)
        return now == pullRequest.targetBranch ? nil : now
    }

    /// Why a Push & Reply mustn't go now (`retargeted`): its prompt, and the check of what the session would push, are for
    /// a branch the pull request no longer merges into. Nil while it merges into that one, or for anything but a push.
    func retargetProblem(_ pullRequest: TaskPullRequest?) -> String? {
        guard let pullRequest, let target = retargeted(pullRequest) else { return nil }
        return Self.retargetedMessage(target)
    }

    static func retargetedMessage(_ target: String) -> String {
        "The pull request merges into \(target) now, not the branch this prompt names, so nothing went. Close this window and open it again, for a prompt that names \(target)."
    }

    /// Reads the branch a pull request merges into from Azure DevOps, with one request: right before Git checks what a
    /// Push & Reply would push, and again after, since the list may not have read a retarget yet. Throws when it can't be
    /// read, and `PullRequestNotActive` once it was completed or abandoned. The source's.
    var readTarget: @MainActor (PRKey) async throws -> String = { _ in throw TargetUnread() }

    /// Nothing reads it, as in the demo.
    struct TargetUnread: Error, CustomStringConvertible {
        var description: String { "Azure DevOps isn't on." }
    }

    /// Reads a pull request again now, as `PRStore.reread(_:)` does, rather than at the list's next refresh. The source's.
    var rereadPullRequest: (PRKey) -> Void = { _ in }

    /// The branch a pull request merges into, as Azure DevOps says now (`readTarget`): what a Push & Reply's prompt has to
    /// name for it to go. When the list has read another, it reads the pull request again then (`rereadPullRequest`), rather
    /// than at its next refresh, so that the window, opened again, writes its prompt for this one. Throws when it can't be
    /// read, or Azure DevOps names none.
    func freshTarget(of pullRequest: TaskPullRequest) async throws -> String {
        let key = PRKey(pullRequest.organization, pullRequest.id)
        let target = try await readTarget(key)
        guard !target.isEmpty else { throw TargetUnread() }
        if let listed = currentTarget(key), !listed.isEmpty, listed != target { rereadPullRequest(key) }
        return target
    }

    /// Why a Push & Reply mustn't go, by its pull request as Azure DevOps says now (`freshTarget`): it merges into another
    /// branch than its prompt names, it was completed or abandoned, or BriefBar couldn't read it. Nil when it's open, and
    /// merges into the branch the prompt names.
    func freshTargetProblem(_ pullRequest: TaskPullRequest) async -> String? {
        do {
            let target = try await freshTarget(of: pullRequest)
            return target == pullRequest.targetBranch ? nil : Self.retargetedMessage(target)
        } catch let closed as PullRequestNotActive {
            return "\(closed), so nothing went."
        } catch {
            return "BriefBar couldn't read which branch the pull request merges into, so nothing went: \(error)"
        }
    }
    /// Stands in for getting a task's worktree ready and starting Copilot, in tests, which start nothing.
    var launchForTests: ((CopilotLauncher.Request, _ id: String, _ now: Date) async throws -> CopilotRun)?
    /// Says whether a session's checkout pushed a commit of its own to a pull request's branch since `start`, in git's place
    /// (`Git.pushedItsOwn(in:branch:since:)`), in tests.
    var pushedForTests: PushedItsOwn?
    typealias PushedItsOwn = @Sendable (_ folder: URL, _ branch: String, _ start: String) async -> Bool?
    /// Stands in for copying a prompt and opening a session in the Copilot app, in tests: whether it opened.
    var openForTests: ((_ sessionId: String, _ prompt: String) -> Bool)?
    /// Whether an app opens `ghapp://` links, in tests.
    var opensLinksForTests: Bool?
    /// Where the Copilot app's files are, in tests; `AppSessions.home()` otherwise.
    var appHomeForTests: URL?
    /// Stands in for git removing a task's worktree, in tests.
    var removeWorktreeForTests: ((CopilotRun, _ force: Bool) async throws -> Void)?
    /// Hears of each session whose log the search for mentions read, in tests.
    var mentionReadForTests: ((_ sessionId: String) -> Void)?
    /// Stands in for showing a session, in the Copilot app or in the terminal of the CLI that has it open, without copying
    /// anything, in tests: whether it opened.
    var showForTests: ((_ sessionId: String) -> Bool)?
    /// Whether the Copilot app holds a session, by the process that holds it, in tests.
    var appHoldsForTests: ((pid_t) -> Bool)?
    /// Where BriefBar's requests to its extension in the Copilot app's sessions go, in tests; `CopilotOutbox.standard`
    /// otherwise.
    var outboxForTests: CopilotOutbox?
    /// How long sending to a session waits for each step, in tests.
    var deliveryTimingForTests: SessionSender.Timing?
    /// The sessions BriefBar sends a prompt to now, through its extension in them (`deliver`): one at a time, each.
    @Published var delivering: Set<String> = []
    /// Where each session that BriefBar sends a prompt to now works, by the session's ID: no task starts there, and git
    /// removes no worktree there, until the prompt has gone or been taken back (`busyFolders`).
    var deliveringFolders: [String: URL] = [:]
    /// Azure DevOps was turned off, or BriefBar is quitting: a prompt on its way to a session goes no further.
    private(set) var hasStopped = false
    /// How the turn of each prompt sent to one of the Copilot app's sessions about pull requests stands, by the
    /// prompt (`SentPrompt.id`), as its session's log said last: in memory only, with what Copilot said.
    @Published var promptTurns: [String: SessionTurn] = [:]
    /// When each of those turns was first seen over, to tell an ended turn from one that only paused.
    var promptsOver: [String: Date] = [:]
    /// Each prompt copied for you to paste, as BriefBar copied it, with what it takes off Needs You, by the prompt
    /// (`SentPrompt.id`), until it's seen in a message sent the session, which says you pasted it (`followSentPrompts`): in
    /// memory only. One that BriefBar stops following first, or forgets, hands nothing off.
    var copiedPrompts: [String: (text: String, handOff: CommentHandOff?)] = [:]
    /// What something of a pull request is, for what's kept about it in memory.
    struct PartKey: Hashable {
        var pullRequest: PRKey
        var part: PullRequestPart
    }
    /// The words you last sent a fix of each thing of a pull request with, from its composer in place, with when, for Try
    /// Again to send them again only for that fix (`retryWords(for:of:)`): in memory only.
    var fixWords: [PartKey: FixWords] = [:]
    /// Words a fix was sent with, and when it took on what it's about: its task's start, or its prompt's `sentAt`, which
    /// tells that attempt from any other; what a session answered that it quoted, if it quoted that; for a thread's, the
    /// change suggested there that it applied as written, if it did; and whether it was to push and reply once done.
    struct FixWords: Equatable {
        var text: String
        var takenAt: Date
        var answer: CopilotAnswer? = nil
        var suggestion: CommentSuggestion? = nil
        var ships = false
    }
    /// What Clear let go of in the demo, whose made-up work is made anew each time: in memory only.
    var clearedInDemo: Set<PartKey> = []
    var isFollowingPrompts = false
    /// The sessions another prompt is being sent to, by how many sends: the turns of the prompts sent them before aren't
    /// followed meanwhile (`pauseFollowing`).
    var followingPaused: [String: Int] = [:]
    /// Reads the sessions' logs those prompts went to, only what's new each time.
    let promptMonitor = RunMonitor()

    /// Where the Copilot app keeps its sessions.
    var appHome: URL { appHomeForTests ?? AppSessions.home() }

    private let notifier: Notifier?
    private let monitor = RunMonitor()
    /// How each run's process ended, for those that ended while BriefBar ran.
    private var exitStatuses: [String: Int32] = [:]
    /// Runs started since BriefBar launched, whose exit it hears about, and since when each one's process is gone
    /// without BriefBar having heard yet.
    private var startedHere: Set<String> = []
    private var goneSince: [String: Date] = [:]
    private var timer: Timer?
    private var isRefreshing = false
    private var cancellables: Set<AnyCancellable> = []
    /// Your login shell's environment, asked for again with each send.
    private var loginEnvironment: [String: String]?
    /// Where each send that goes on with a session works, by the session's ID, while it gets ready: no other task goes there
    /// meanwhile.
    private var continuingFolders: [String: URL] = [:]
    /// The worktrees git removes now, by their task's session ID: no task goes there meanwhile.
    private var removingWorktrees: [String: URL] = [:]

    /// Where what each run prints goes: its last words, or why it couldn't start.
    nonisolated static let outputFolder = UserHome.url.appendingPathComponent("Library/Application Support/BriefBar/Copilot", isDirectory: true)

    init(settings: AppSettings, mode: PRStore.Mode, notifier: Notifier?) {
        self.settings = settings
        self.mode = mode
        self.notifier = notifier
        // The demo's preferences are thrown away; it shows made-up sends, and sends nothing.
        if mode == .demo { settings.copilotEnabled = true }
        settings.$copilotRuns.merge(with: settings.$copilotEnabled.map { _ in settings.copilotRuns })
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    var isOn: Bool { settings.copilotEnabled }
    /// The demo sends nothing.
    var canSend: Bool { mode == .live }
    /// BriefBar's prompts that change code end asking the session to tell BriefBar the pull request's stage once it pushed
    /// (`PromptTemplate.stageLine`): while Pull Request Order is on.
    var asksForStage: Bool { services?.pullRequestOrder.isOn == true }

    /// Every send, newest first.
    var entries: [CopilotTaskEntry] {
        let continued = Dictionary(pending.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let runs = settings.copilotRuns.filter(\.isValid).map { run in
            let status = statuses[run.id] ?? RunStatus(phase: run.ended ?? .working)
            guard let next = continued[run.id] else { return entry(for: run, status: status) }
            // A run being continued shows once, as what it's continued for, as the launcher will keep it: such as a pull
            // request's task in the session of the work item's task that opened it, while it gets ready, so the pull
            // request's row shows it, or why it couldn't start. The run stays as it was until then, for the next try.
            var shown = next
            shown.run = run
            if shown.onPullRequest != nil, shown.workItem == nil { shown.workItem = run.workItem }
            if shown.pullRequest == nil { shown.pullRequest = run.pullRequest }
            if shown.forkedFrom == nil { shown.forkedFrom = run.forkedFrom }
            shown.status = statuses[run.id] ?? next.status
            return shown
        }
        let waiting = pending.filter { entry in !runs.contains { $0.id == entry.id } }
        return (waiting + runs + demoEntries).sorted { $0.startedAt > $1.startedAt }
    }

    private func entry(for run: CopilotRun, status: RunStatus) -> CopilotTaskEntry {
        var entry = CopilotTaskEntry(
            id: run.id, workItem: run.workItem, onPullRequest: run.onPullRequest, action: run.action, options: run.options,
            startedAt: run.startedAt, status: status, pullRequest: run.pullRequest, run: run, taken: run.taken,
            forkedFrom: run.forkedFrom, pushes: run.pushes
        )
        entry.runFixes = run.fixes == true
        entry.pushSeen = entry.fixesFirst && run.pushed == true
        return entry
    }

    private var demoEntries: [CopilotTaskEntry] {
        mode == .demo ? CopilotTaskEntry.demo(now: Date()) : []
    }

    /// The demo's clone of the repository a send goes in, made up as the rest of its data is, so its composer shows what
    /// yours would.
    static func demoRepository(for subject: TaskSubject) -> GitRepository {
        let name: String
        switch subject {
        case .workItem: name = "shop-web"
        case .pullRequest(let pullRequest, _): name = pullRequest.repository
        }
        return GitRepository(root: UserHome.url.appendingPathComponent("Developer/\(name)", isDirectory: true), baseBranch: "main")
    }

    /// The latest send of a work item, for its row.
    func latest(for item: WorkItem) -> CopilotTaskEntry? {
        let reference = item.copilotTask.reference
        return entries.first { $0.workItem?.matches(reference) == true }
    }

    /// The latest task on a pull request, for its row.
    func latest(forPullRequest key: PRKey) -> CopilotTaskEntry? {
        entries.first { $0.isOn(key) }
    }

    /// The run a new task on a pull request goes on with: its latest one, ended, whose worktree is still there. Not a fork's,
    /// which works on the side, as the pull request's session doesn't (`lastTask(forPullRequest:)`).
    func continuable(forPullRequest key: PRKey) -> CopilotRun? {
        guard let entry = entries.first(where: { $0.isOn(key) && $0.forkedFrom == nil }), !entry.status.phase.isActive, let run = entry.run,
              FileManager.default.fileExists(atPath: run.worktree.path)
        else { return nil }
        return run
    }

    /// The clone chosen for this repository, or a known clone whose origin matches it.
    func repository(for pullRequest: TaskPullRequest, using git: Git) async throws -> GitRepository? {
        guard canSend, isOn else { return nil }
        if let path = settings.copilotRepositories[pullRequest.reference.repositoryKey] {
            return try await checkRepository(at: URL(fileURLWithPath: path, isDirectory: true), for: pullRequest, using: git)
        }
        for folder in knownRepositories {
            do {
                return try await checkRepository(at: folder, for: pullRequest, using: git)
            } catch {
                Log.app.debug("Skipping a known local clone: \(Self.kind(of: error), privacy: .public)")
            }
        }
        return nil
    }

    /// Remember a verified local clone immediately, even if the composer is later cancelled.
    func checkRepository(at folder: URL, for pullRequest: TaskPullRequest, using git: Git) async throws -> GitRepository {
        let repository = try await git.repository(at: folder, for: pullRequest)
        if canSend, isOn {
            settings.copilotRepositories[pullRequest.reference.repositoryKey] = repository.root.path
        }
        return repository
    }

    var activeCount: Int { entries.filter { $0.status.phase.isActive }.count }

    /// The repository a work item's project went in last.
    func repository(for item: TaskWorkItem) -> URL? {
        settings.copilotRepositories[item.reference.projectKey].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Every repository work went in, for the composer's menu.
    var knownRepositories: [URL] {
        Set(settings.copilotRepositories.values).sorted().map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Your login shell's environment: the one asked for last, unless `fresh`. One asked for by a task that's cancelled
    /// meanwhile, such as a window's that closed, isn't kept: its shell may have been stopped before it said it all.
    func environment(fresh: Bool = false) async -> [String: String] {
        if !fresh, let loginEnvironment { return loginEnvironment }
        let environment = await LoginEnvironment.load()
        if !Task.isCancelled { loginEnvironment = environment }
        return environment
    }

    /// Uses this environment instead of asking your login shell, for tests.
    func useEnvironment(_ environment: [String: String]) {
        loginEnvironment = environment
    }

    /// git as your shell finds it, with your environment: the Command Line Tools' `/usr/bin/git` asks to install them
    /// when they aren't.
    func git() async -> Git {
        let environment = await environment()
        return Git(executable: LoginEnvironment.which("git", in: environment) ?? URL(fileURLWithPath: "/usr/bin/git"), environment: environment)
    }

    /// What a run printed.
    func output(of run: CopilotRun) -> URL {
        run.output(in: Self.outputFolder)
    }

    // MARK: Lifecycle

    func start() {
        guard mode == .live else { return }
        // Published values arrive before they're set: read the setting on the next turn.
        settings.$copilotEnabled.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Off, nothing will say how the tasks still working end: the notifications that say they're working go.
                    if !self.isOn {
                        self.notifier?.remove(self.entries.filter(\.status.phase.isActive).map { Self.notificationID($0.id) })
                        self.copiedPrompts = [:]
                        self.fixWords = [:]
                    }
                    // Copilot's logs are read only while the feature is on; turned back on, its runs are followed again.
                    self.refresh()
                }
            }
            .store(in: &cancellables)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        hasStopped = true
        copiedPrompts = [:]
        fixWords = [:]
    }

    // MARK: Sending

    /// Opens the composer, to check the prompt, the model and the repository, or a session to go on with, before sending.
    func compose(_ item: WorkItem, options: CopilotRunOptions? = nil) {
        CopilotComposer.shared.show(item: item.copilotTask, options: options ?? settings.copilotOptions, store: self)
    }

    /// Sends with these options and the standard prompt, to the repository its project went in last; without one yet,
    /// the composer asks.
    func quickSend(_ item: WorkItem, options: CopilotRunOptions) {
        let task = item.copilotTask
        guard canSend, let repository = repository(for: task) else {
            compose(item, options: options)
            return
        }
        let prompt = PromptTemplate.ending(PromptTemplate.render(settings.copilotPromptTemplate, item: task), asksForStage: asksForStage)
        send(task, prompt: prompt, options: options, repository: repository)
    }

    func send(_ item: TaskWorkItem, prompt: String, options: CopilotRunOptions, repository: URL) {
        send(.workItem(item), prompt: prompt, options: options, repository: repository)
    }

    /// Opens the composer for a pull request, with its prompts for what to do, going on with its last task's session by
    /// default, or else with the session that likely opened it (`suggestedChoice`).
    /// - Parameters:
    ///   - prompt: for a task in a worktree of BriefBar's, detached at the pull request's latest commit.
    ///   - sessionPrompt: for a session that works wherever it is, such as one of the Copilot app's.
    ///   - createdAt: when the pull request was created, to tell which sessions were there before.
    ///   - handOff: what the prompt takes off Needs You once it's sent, as it was written.
    ///   - start: where it goes to begin with, rather than BriefBar's suggestion.
    ///   - parts: what of the pull request it takes on, its threads, builds or conflicts, for each to say what became of it.
    func compose(
        _ pullRequest: TaskPullRequest, action: PullRequestAction, prompt: String, sessionPrompt: String? = nil, createdAt: Date? = nil,
        handOff: CommentHandOff? = nil, start: ComposerStart? = nil, parts: [PullRequestPart] = []
    ) {
        let key = PRKey(pullRequest.organization, pullRequest.id)
        // Where it starts, once something chose it, rather than the last task's session: Push & Reply ships what's in the
        // session it starts in.
        CopilotComposer.shared.show(
            subject: .pullRequest(pullRequest, action), prompt: prompt, sessionPrompt: sessionPrompt, createdAt: createdAt,
            options: settings.copilotOptions, continuing: start == nil ? continuable(forPullRequest: key) : nil, handOff: handOff,
            session: start, parts: parts, store: self
        )
    }

    /// Starts Copilot on a work item or a pull request; or goes on with a session that's there already: an earlier run's,
    /// in its worktree, or one of the Copilot app's (`appRun(for:subject:options:)`), in the folder it works in; or forks
    /// one of BriefBar's own sessions, with its history, into a worktree of its own, where Copilot works on it while the
    /// session stays as it is (`CopilotLauncher.Request.forking`). Once it has started, what `handOff` says its prompt took
    /// care of leaves Needs You, and its run keeps what of the pull request it takes on (`CopilotRun.taken`).
    /// - Parameters:
    ///   - parts: what of the pull request it takes on: its comment threads, builds or conflicts.
    ///   - fixing: a Push & Reply that fixes the threads it takes on first, as a comment's Fix sent with Push and Reply on
    ///     does (`TakenPart.fixes`).
    /// - Returns: when it took them on, which is the task's, as its parts' `since`; nil when nothing starts.
    @discardableResult
    func send(
        _ subject: TaskSubject, prompt: String, options: CopilotRunOptions, repository: URL, continuing: CopilotRun? = nil,
        forking: CopilotRun? = nil, parts: [PullRequestPart] = [], handOff: CommentHandOff? = nil, fixing: Bool = false
    ) -> Date? {
        // Not once Azure DevOps stopped, as it may have while an inline Fix looked for where to send it.
        guard canSend, isOn, !hasStopped, continuing == nil || forking == nil else { return nil }
        // A second run in a session Copilot still works in would fork its history; one in a checkout it works in, for another
        // session, would mix their work up, as when two of the Copilot app's sessions share one. A fork works in a worktree
        // of its own, so the session it forks may be busy.
        if let continuing, isWorking(inSession: continuing.id) || isWorking(inFolder: continuing.worktree) {
            Log.app.error("Didn't send a task to Copilot: it still works in that session or its folder")
            return nil
        }
        // An app's session's folder is no repository to start new work in.
        if continuing?.isAppSession != true {
            switch subject {
            case .workItem(let item): settings.copilotRepositories[item.reference.projectKey] = repository.path
            case .pullRequest(let pullRequest, _): settings.copilotRepositories[pullRequest.reference.repositoryKey] = repository.path
            }
        }
        // A fork's ID is the CLI's to choose: until it's made, its send goes by one of BriefBar's, then by the fork's.
        let id = continuing?.id ?? UUID().uuidString.lowercased()
        let launched = LaunchedSession(id)
        let now = Date()
        var action: PullRequestAction?
        var target: String?
        var entry = CopilotTaskEntry(id: id, workItem: nil, options: options, startedAt: now, status: RunStatus(phase: .preparing, since: now))
        switch subject {
        case .workItem(let item):
            entry.workItem = item.reference
        case .pullRequest(let pullRequest, let what):
            entry.onPullRequest = pullRequest.reference
            entry.action = what
            entry.pullRequest = pullRequest.url
            action = what
            target = pullRequest.targetBranch.isEmpty ? nil : pullRequest.targetBranch
        }
        // What it keeps, with what the session it goes on with took on before, as that session is kept now.
        let keptRun = continuing.flatMap { continuing in settings.copilotRuns.first { $0.id == continuing.id } }
        let previous = keptRun ?? continuing
        let kept = CopilotRun.taken(
            goingOnWith: previous, on: entry.onPullRequest, taking: parts, for: action, at: now, target: target, fixing: fixing
        )
        entry.taken = kept
        // The pushes that ran there, as BriefBar kept its runs: not one of the app's sessions' only about to start.
        let pushes = CopilotRun.pushes(goingOnWith: keptRun, on: entry.onPullRequest)
        entry.pushes = pushes
        // Kept with the run apart from what it took on, which Clear lets go of, with where the branch was in its checkout as
        // it started, which the launcher reads, for whether it pushed once it's done.
        let fixesFirst = action == .pushAndReply && fixing
        entry.forkedFrom = forking?.id ?? continuing?.forkedFrom
        pending.removeAll { $0.id == id }
        pending.append(entry)
        if let continuing {
            continuingFolders[id] = continuing.worktree
            statuses[id] = entry.status
            // Going on with it: you're not stopping this one.
            if let index = settings.copilotRuns.firstIndex(where: { $0.id == id }) {
                settings.copilotRuns[index].stoppedByYou = nil
            }
            exitStatuses[id] = nil
            goneSince[id] = nil
        }
        // Copilot works on its own, and nothing opens: say it's on it, now, rather than once its worktree is ready. A fork,
        // once the CLI made it (`rekey`): the notification goes by its ID, for the one that says how it ended to replace.
        if forking == nil { notifyStarted(entry) }
        // Push & Reply goes only while the pull request merges into the branch its prompt names, which the launcher checks what
        // the session would push against: as Azure DevOps says right before git checks that, and again right before Copilot
        // starts, and as the list has read by the time each answer comes, since a GET may answer from before a retarget the
        // list has read meanwhile. Either one that says another branch, or that it was completed or abandoned, keeps Copilot
        // from starting.
        let pushing: TaskPullRequest? = if case .pullRequest(let pullRequest, .pushAndReply) = subject { pullRequest } else { nil }
        var askTarget: (@Sendable () async throws -> String)?
        if let pushing {
            askTarget = { [weak self] in
                guard let self else { throw CancellationError() }
                let target = try await self.freshTarget(of: pushing)
                // Completed or abandoned as the list has read meanwhile, though Azure DevOps answered from before.
                if await self.closedProblem(pushing) != nil { throw PullRequestNotActive(status: "") }
                guard target == pushing.targetBranch else { return target }
                return await self.retargeted(pushing) ?? target
            }
        }
        let request = CopilotLauncher.Request(
            subject: subject, prompt: prompt, options: options, repository: repository,
            worktreesFolder: settings.copilotWorktreesFolder.map { URL(fileURLWithPath: $0, isDirectory: true) }, continuing: continuing,
            forking: forking, targetNow: askTarget
        )
        // Going on with a session, its next turn may end before the run is known to have started: the turns of the prompts
        // sent it before aren't followed until then (`pauseFollowing`).
        if let continuing { pauseFollowing(continuing.id) }
        Task { [self] in
            defer { if let continuing { resumeFollowing(continuing.id) } }
            do {
                // Again, as it starts: another of the app's sessions may have started a turn in the same checkout since the
                // window looked. The launcher looks once more right before Copilot starts, after its git commands.
                if let continuing, await anotherSessionRuns(inCheckoutOf: continuing.worktree, besides: id) {
                    throw LaunchError.sharedCheckout
                }
                // Retargeted since the window wrote the prompt, or since you sent it.
                if let pushing, let target = retargeted(pushing) { throw LaunchError.retargeted(target) }
                var run: CopilotRun
                if let launchForTests {
                    run = try await launchForTests(request, id, now)
                } else {
                    // Asked again for each send, so a tool you've just installed is found.
                    let environment = await environment(fresh: true)
                    let launcher = CopilotLauncher(
                        outputFolder: Self.outputFolder, environment: { environment }, appHome: appHome, leftovers: settings
                    )
                    run = try await launcher.launch(request, id: id, now: now, forked: { [weak self] fork in
                        launched.id = fork
                        Task { @MainActor in self?.rekey(id, to: fork) }
                    }) { [weak self] status in
                        let id = launched.id
                        MainActor.assumeIsolated { self?.exited(id, status: status) }
                    }
                }
                rekey(id, to: run.id)
                // What it took on as it got ready, less what a pass ended meanwhile (`endWorkThatsOver`).
                if let entry = pending.first(where: { $0.id == run.id }) {
                    run.taken = entry.taken
                } else {
                    run.taken = kept
                }
                run.pushes = pushes
                if fixesFirst {
                    run.fixes = true
                } else {
                    run.head = nil
                }
                // Going on with one of the Copilot app's sessions: its turn is the next, after any prompt sent it before.
                if let continuing { overlap(promptsIn: continuing.id, before: now) }
                startedHere.insert(run.id)
                pending.removeAll { $0.id == run.id }
                continuingFolders[id] = nil
                statuses[run.id] = nil
                if let index = settings.copilotRuns.firstIndex(where: { $0.id == run.id }) {
                    settings.copilotRuns[index] = run
                } else {
                    settings.copilotRuns.append(run)
                }
                // On a pull request, in another session than the one you chose for its work: it takes that one's place.
                if case .pullRequest(let pullRequest, _) = subject {
                    settings.forgetChosenSession(for: PRKey(pullRequest.organization, pullRequest.id), supersededBy: run)
                }
                let how: String = continuing != nil ? ", going on with its session" : forking != nil ? ", in a fork of a session" : ""
                Log.app.info("Sent a task to Copilot\(how, privacy: .public)")
                if let handOff { handedOff(handOff, prompt) }
                refresh()
            } catch {
                Log.app.error("Couldn't send a task to Copilot: \(Self.kind(of: error), privacy: .public)")
                continuingFolders[id] = nil
                let status = RunStatus(phase: .failed, since: Date(), detail: String(describing: error))
                // By the fork's ID, once it was made, though it's deleted now: the send that made it.
                let current = launched.id
                if let index = pending.firstIndex(where: { $0.id == current || $0.id == id }) {
                    pending[index].status = status
                    notify(pending[index], status: status)
                }
                if continuing != nil {
                    // The earlier run stays as it ended; this send's failure is in its place until it's cleared.
                    statuses[id] = status
                }
            }
        }
        return now
    }

    /// Lets go of what the sends getting ready, or that couldn't start, took on, as `letsGo` says: what's over
    /// (`endWorkThatsOver`), or what Clear lets go of (`clear(_:of:)`). Each launches with what's left.
    func letGoPending(_ letsGo: (TakenPart, CopilotTaskEntry) -> Bool) {
        for index in pending.indices {
            guard let taken = pending[index].taken else { continue }
            let entry = pending[index]
            let kept = taken.filter { !letsGo($0, entry) }
            if kept.count != taken.count { pending[index].taken = kept }
        }
    }

    /// A fork's send, by the ID BriefBar gave it until the CLI made the fork, goes by the fork's from then on. Only then
    /// does it say it's working, by the fork's ID, which the notification that says how it ended, or stopping it, replaces.
    private func rekey(_ id: String, to fork: String) {
        guard fork != id else { return }
        var moved: CopilotTaskEntry?
        for index in pending.indices where pending[index].id == id {
            pending[index].id = fork
            moved = pending[index]
        }
        if let status = statuses.removeValue(forKey: id) { statuses[fork] = status }
        if let moved, moved.status.phase.isActive { notifyStarted(moved) }
    }

    /// The checkouts that tasks of BriefBar's work in now (`checkoutKey`): those of sends that go on with a session, while
    /// they get ready, and those of runs whose Copilot process still runs; and those of worktrees git removes now. A new
    /// task's worktree is its own.
    func busyFolders() -> Set<String> {
        var folders = Set((Array(removingWorktrees.values) + Array(deliveringFolders.values)).map(Self.checkoutKey))
        for entry in pending where entry.status.phase.isActive {
            if let folder = continuingFolders[entry.id] { folders.insert(Self.checkoutKey(folder)) }
        }
        for run in settings.copilotRuns where run.ended == nil && DetachedProgram.isRunning(run.process) {
            folders.insert(Self.checkoutKey(run.worktree))
        }
        return folders
    }

    /// Whether a task of BriefBar's works in the folder's checkout now, in any session (`busyFolders`).
    func isWorking(inFolder folder: URL) -> Bool {
        busyFolders().contains(Self.checkoutKey(folder))
    }

    /// A folder's path, to compare it with another's however each is written (`AppSessions.folderKey`).
    nonisolated static func folderKey(_ folder: URL) -> String {
        AppSessions.folderKey(folder)
    }

    /// The checkout a folder is in, to tell whether two sessions' work would mix (`AppSessions.checkoutKey`).
    nonisolated static func checkoutKey(_ folder: URL) -> String {
        AppSessions.checkoutKey(folder)
    }

    /// What went wrong, without paths or names, for the log.
    private static func kind(of error: Error) -> String {
        if let error = error as? GitError { return kind(of: LaunchError.git(error)) }
        switch error as? LaunchError {
        case .copilotNotFound?: return "the Copilot CLI isn't installed"
        case .git(.notARepository)?: return "not a git repository"
        case .git(.noOrigin)?: return "no origin remote"
        case .git(.wrongRepository)?: return "wrong local clone"
        case .git(.failed)?: return "git failed"
        case .couldntStart?: return "Copilot couldn't start"
        case .openInApp?: return "the Copilot app has the session open"
        case .sharedCheckout?: return "another session works in the checkout"
        case .cantFork?: return "the Copilot CLI didn't fork the session"
        case .foreignMerge?: return "the session holds a merge its target doesn't have"
        case .cantCheckPush?: return "couldn't check what it would push"
        case .retargeted?: return "the pull request's target changed"
        case .cantReadTarget?: return "couldn't read the pull request's target"
        case .notActive?: return "the pull request isn't active"
        case nil: return "unexpected error"
        }
    }

    private func exited(_ id: String, status: Int32) {
        exitStatuses[id] = status
        refresh()
    }

    // MARK: Following runs

    /// How long a process that BriefBar started may be gone before BriefBar stops waiting to hear how it ended.
    private static let exitGrace: TimeInterval = 10

    /// Reads the logs of runs still going, and of those whose end BriefBar hasn't looked at yet, while the feature is
    /// on. Whether a run's process still runs is checked first: once it's gone, its log and output are complete. As one
    /// that fixed what it took on first, then was to push and reply, finishes, git in its checkout says whether it pushed a
    /// commit of its own (`pushedItsOwn(_:)`), which its run keeps.
    func refresh() {
        guard mode == .live, isOn else {
            scheduleIfNeeded()
            return
        }
        // And the prompts sent to the Copilot app's sessions about pull requests, whose turns run there.
        followSentPrompts()
        guard !isRefreshing else { return }
        let runs = settings.copilotRuns.filter { $0.isValid && ($0.ended == nil || statuses[$0.id] == nil) }
        guard !runs.isEmpty else {
            scheduleIfNeeded()
            return
        }
        isRefreshing = true
        let monitor = monitor
        Task {
            let copilotHome = CopilotCLI.home(environment: await environment())
            var results: [Ended] = []
            for run in runs {
                let events = run.events(in: copilotHome)
                if DetachedProgram.isRunning(run.process) || awaitsExit(of: run) {
                    // Working, whatever its log says for now; the log gives its current step.
                    let log = await monitor.log(id: run.id, events: events)
                    let status = RunStatus.derive(
                        log: log, startedAt: run.launchedAt, isRunning: true, exitStatus: nil, stoppedByYou: false, output: nil
                    )
                    results.append(Ended(run: run, status: status))
                    continue
                }
                let log = await monitor.log(id: run.id, events: events)
                let output = output(of: run)
                let needsLink = run.pullRequest == nil
                let launchedAt = run.launchedAt
                let found = await Task.detached { () -> (String?, URL?) in
                    let printed = LocalFile.tail(of: output, maxBytes: 8_192).map { String(decoding: $0, as: UTF8.self) }
                    guard needsLink else { return (printed, nil) }
                    return (printed, RunTranscript.openedPullRequest(events: events, printed: printed, since: launchedAt))
                }.value
                let status = RunStatus.derive(
                    log: log, startedAt: run.launchedAt, isRunning: false, exitStatus: exitStatuses[run.id],
                    stoppedByYou: wasStoppedByYou(run.id), output: found.0
                )
                var pushed: Bool?
                if run.ended == nil, run.fixes == true, run.action == .pushAndReply, status.phase == .finished {
                    pushed = await pushedItsOwn(run)
                }
                results.append(Ended(run: run, status: status, pullRequest: found.1, pushed: pushed))
            }
            apply(results)
            isRefreshing = false
            scheduleIfNeeded()
        }
    }

    /// A run that BriefBar started is gone, but how it ended isn't known yet: that comes a moment later, unless
    /// something else collected it.
    private func awaitsExit(of run: CopilotRun) -> Bool {
        guard startedHere.contains(run.id), exitStatuses[run.id] == nil else { return false }
        let gone = goneSince[run.id] ?? Date()
        goneSince[run.id] = gone
        return Date().timeIntervalSince(gone) < Self.exitGrace
    }

    /// What `refresh` read of a run: its status, the pull request it opened, once found, and, for one that fixed what it
    /// took on first and finished, whether it pushed a commit of its own (`CopilotRun.pushed`).
    private struct Ended {
        var run: CopilotRun
        var status: RunStatus
        var pullRequest: URL? = nil
        var pushed: Bool? = nil
    }

    /// Whether a task that fixed what it took on first, then was to push and reply, pushed a commit of its own from its
    /// checkout since it started, as git there says now (`Git.pushedItsOwn(in:branch:since:)`): nil when git can't tell, or
    /// BriefBar didn't read where the branch was as it started (`CopilotRun.head`).
    private func pushedItsOwn(_ run: CopilotRun) async -> Bool? {
        guard let branch = run.onPullRequest?.sourceBranch, let start = run.head else { return nil }
        return await Self.pushedItsOwn(in: run.worktree, branch: branch, since: start, git: await git(), forTests: pushedForTests)
    }

    /// Whether a session's checkout pushed a commit of its own to a pull request's branch since `start`
    /// (`Git.pushedItsOwn(in:branch:since:)`), or what a test says in git's place (`pushedForTests`).
    nonisolated static func pushedItsOwn(
        in folder: URL, branch: String, since start: String, git: Git, forTests: PushedItsOwn?
    ) async -> Bool? {
        if let forTests { return await forTests(folder, branch, start) }
        return await git.pushedItsOwn(in: folder, branch: branch, since: start)
    }

    private func apply(_ results: [Ended]) {
        for result in results {
            if statuses[result.run.id] != result.status { statuses[result.run.id] = result.status }
            // Cleared while it was read.
            guard let index = settings.copilotRuns.firstIndex(where: { $0.id == result.run.id }) else { continue }
            var run = settings.copilotRuns[index]
            if run.pullRequest == nil, let pullRequest = result.pullRequest { run.pullRequest = pullRequest }
            if !result.status.phase.isActive, run.ended == nil {
                run.ended = result.status.phase
                // Whether it pushed, as git said in its checkout as it finished: once, whatever moves the branch since.
                if run.fixes == true, run.startedAt == result.run.startedAt { run.pushed = result.pushed }
                Log.app.info("A task sent to Copilot ended: \(result.status.phase.rawValue, privacy: .public)")
                notify(entry(for: run, status: result.status), status: result.status)
            }
            if run != settings.copilotRuns[index] { settings.copilotRuns[index] = run }
        }
    }

    /// Every few seconds while something runs and the feature is on; not at all otherwise.
    private func scheduleIfNeeded() {
        let busy = mode == .live && isOn
            && (settings.copilotRuns.contains { $0.isValid && $0.ended == nil } || pending.contains { $0.status.phase.isActive }
                || settings.copilotSentPrompts.contains(where: \.isFollowed))
        if busy, timer == nil {
            let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !busy {
            timer?.invalidate()
            timer = nil
        }
    }

    /// "4217: Show the order total in the cart", "!4071 Fix the checkout total": the pull request, for a task on the one
    /// its work item's task opened.
    func subject(of entry: CopilotTaskEntry) -> String {
        if let pullRequest = entry.onPullRequest {
            return "!\(pullRequest.id)" + (pullRequestTitle(pullRequest).map { " \($0)" } ?? "")
        }
        if let workItem = entry.workItem {
            return title(workItem).map { "\(workItem.id): \($0)" } ?? "Work item \(workItem.id)"
        }
        return "A task"
    }

    private func notify(_ entry: CopilotTaskEntry, status: RunStatus) {
        guard !status.phase.isActive, let notifier else { return }
        guard settings.notifications, !wasStoppedByYou(entry.id) else {
            // Nothing says how it ended, so the notification that says it's working goes.
            notifier.remove([Self.notificationID(entry.id)])
            return
        }
        guard let notification = Self.endedNotification(entry, status: status, subject: subject(of: entry)) else { return }
        notifier.post([notification])
    }

    /// How a task ended, what it did, and on what; nil while it's at it. Clicking it opens its pull request or work item.
    static func endedNotification(_ entry: CopilotTaskEntry, status: RunStatus, subject: String) -> BriefBarNotification? {
        let heading: String
        let body: String
        var state = ItemState.done
        switch status.phase {
        case .finished where entry.action != nil:
            switch entry.action {
            case .review?: heading = "Copilot's review is ready"
            case .pushAndReply? where entry.fixesFirst:
                // It says only that it fixed, as the line about the thread says whether it pushed: what Copilot said tells.
                let fixing = entry.taken?.filter { $0.ended == nil && $0.part.thread != nil }.count
                heading = fixing == 1 ? "Copilot finished fixing a comment" : "Copilot finished fixing the comments"
            case .pushAndReply?: heading = entry.onlyPushes ? "Copilot pushed" : "Copilot pushed and replied"
            default: heading = "Copilot's changes are ready"
            }
            body = Self.firstLine(status.detail)
                ?? (entry.action?.changesCode == true ? "Check them in its worktree, then Push & Reply." : "It didn't say what it did.")
        case .finished:
            heading = entry.pullRequest != nil ? "Copilot opened a pull request" : "Copilot finished"
            body = Self.firstLine(status.detail) ?? (entry.pullRequest != nil ? "It's ready for review." : "It didn't say what it did.")
        case .failed:
            heading = "Copilot couldn't finish"
            body = Self.firstLine(status.detail) ?? "It reported an error."
            state = .failing
        case .stopped:
            heading = "Copilot stopped"
            body = "It stopped before it finished."
            state = .failing
        case .preparing, .working:
            return nil
        }
        return BriefBarNotification(
            id: Self.notificationID(entry.id), source: .azureDevOps, state: state, title: heading, subtitle: subject, body: body,
            thread: "copilot", userInfo: (entry.pullRequest ?? entry.workItemURL).map { ["url": $0.absoluteString] } ?? [:]
        )
    }

    nonisolated static func firstLine(_ text: String?) -> String? {
        text?.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    /// Says Copilot is on it as you send it: it works on its own, and nothing opens. The notification that says how it
    /// ended takes this one's place.
    private func notifyStarted(_ entry: CopilotTaskEntry) {
        guard settings.notifications, let notifier else { return }
        notifier.post([Self.startedNotification(entry, subject: subject(of: entry))])
    }

    /// What Copilot does now, on what, and what it won't do. Clicking it shows the task with your Copilot sessions.
    static func startedNotification(_ entry: CopilotTaskEntry, subject: String) -> BriefBarNotification {
        let heading: String
        let body: String
        switch entry.action {
        case .fixComments?:
            // Fix, on one thread, or Fix Comments, on those that wait on you.
            let fixing = entry.taken?.filter { $0.ended == nil && $0.part.thread != nil }.count
            heading = fixing == 1 ? "Copilot is fixing a comment" : "Copilot is fixing the comments"
            body = "It works on its own in a worktree, and doesn't push or reply."
        case .fixBuild?:
            heading = "Copilot is fixing the build"
            body = "It works on its own in a worktree, and doesn't push."
        case .resolveConflicts?:
            heading = "Copilot is resolving the conflicts"
            body = "It merges the target branch in a worktree, and doesn't push."
        case .review?:
            heading = "Copilot is reviewing the pull request"
            body = "It drafts your review, and changes or posts nothing."
        case .pushAndReply? where entry.fixesFirst:
            // Fix, or Fix All, sent with Push and Reply on.
            let fixing = entry.taken?.filter { $0.ended == nil && $0.part.thread != nil }.count
            heading = fixing == 1 ? "Copilot is fixing a comment" : "Copilot is fixing the comments"
            body = "It works on its own, then commits, pushes the branch and replies on the threads it fixed, as you."
        case .pushAndReply?:
            heading = entry.onlyPushes ? "Copilot is pushing" : "Copilot is pushing and replying"
            body = entry.onlyPushes
                ? "It commits and pushes the branch, as you."
                : "It commits, pushes the branch and replies on the threads it addressed, as you."
        case nil:
            heading = "Copilot is working on it"
            body = "It works on its own in a new worktree, then opens a pull request."
        }
        var info = [taskKey: entry.id]
        if let url = entry.pullRequest ?? entry.workItemURL { info["url"] = url.absoluteString }
        return BriefBarNotification(
            id: notificationID(entry.id), source: .azureDevOps, state: .running, title: heading, subtitle: subject,
            body: body + " You'll hear when it's done.", thread: "copilot", userInfo: info
        )
    }

    /// A task's notification: the one that says it started, then the one that says how it ended, in its place.
    nonisolated static func notificationID(_ id: String) -> String {
        "copilot.\(id)"
    }

    /// A notification's key for the task it's about, as it starts.
    nonisolated static let taskKey = "copilotTask"

    // MARK: A run's actions

    func stop(_ entry: CopilotTaskEntry) {
        guard let run = entry.run else { return }
        // Kept with the run: after BriefBar restarts, it's still nothing to look at, nor to hear about.
        if let index = settings.copilotRuns.firstIndex(where: { $0.id == run.id }) {
            settings.copilotRuns[index].stoppedByYou = true
        }
        // Nothing takes the place of the notification that says it's working, so it goes now.
        notifier?.remove([Self.notificationID(run.id)])
        DetachedProgram.stop(run.process)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
    }

    /// You stopped it, as its run keeps.
    func wasStoppedByYou(_ id: String) -> Bool {
        settings.copilotRuns.contains { $0.id == id && $0.stoppedByYou == true }
    }

    /// Forgets it here, and deletes what it printed. Its worktree, branch and session stay.
    func clear(_ entry: CopilotTaskEntry) {
        pending.removeAll { $0.id == entry.id }
        settings.copilotRuns.removeAll { $0.id == entry.id }
        statuses[entry.id] = nil
        if let run = entry.run, run.isValid {
            try? FileManager.default.removeItem(at: output(of: run))
            let monitor = monitor
            Task { await monitor.forget(run.id) }
        } else if UUID(uuidString: entry.id) != nil {
            // A send that couldn't start may have printed why.
            try? FileManager.default.removeItem(at: Self.outputFolder.appendingPathComponent("\(entry.id.lowercased()).log"))
        }
    }

    /// Forgets every task that has ended.
    func clearEnded() {
        for entry in entries where !entry.status.phase.isActive { clear(entry) }
    }

    /// What BriefBar saved of the runs it started: what each printed; and its requests to its extension in the Copilot
    /// app's sessions, with their results, which hold its prompts, but not what the extensions that run say. Called when
    /// Azure DevOps is turned off. What it can't delete, it logs.
    nonisolated static func deleteOutput(in folder: URL = outputFolder, outbox: CopilotOutbox = .standard) {
        if !outbox.forget() {
            Log.app.error("Couldn't remove all of BriefBar's requests to the Copilot app's sessions, which hold its prompts")
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var isFolder: ObjCBool = false
        // The outbox stays, for what extensions say in it, only as a real folder in this one: a link goes, not what it
        // leads to.
        guard !LocalFile.isLink(folder), outbox.url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL,
              let kept = outbox.path.last, names.contains(kept), !LocalFile.isLink(outbox.url),
              FileManager.default.fileExists(atPath: outbox.url.path, isDirectory: &isFolder), isFolder.boolValue
        else {
            deleteSaved(folder)
            return
        }
        for name in names where name != kept {
            deleteSaved(folder.appendingPathComponent(name))
        }
    }

    /// Deletes a file, or a folder and what's in it, without following a link: a link goes, not what it leads to.
    private nonisolated static func deleteSaved(_ item: URL) {
        do {
            try FileManager.default.removeItem(at: item)
        } catch CocoaError.fileNoSuchFile {
            // Nothing was there.
        } catch {
            Log.app.error("Couldn't delete all that Copilot printed")
        }
    }

    func openPullRequest(_ entry: CopilotTaskEntry) {
        if let url = entry.pullRequest { AzureDevOps.open(url) }
    }

    func openWorkItem(_ entry: CopilotTaskEntry) {
        if let url = entry.workItemURL { AzureDevOps.open(url) }
    }

    func showWorktree(_ entry: CopilotTaskEntry) {
        guard let run = entry.run else { return }
        ThisMac.showInFinder([run.worktree])
    }

    func showOutput(_ entry: CopilotTaskEntry) {
        guard let run = entry.run, run.isValid, !LocalFile.isLink(output(of: run)) else { return }
        ThisMac.open(output(of: run))
    }

    /// Goes on with Copilot's session in Terminal, in its worktree, to ask for more or see what it did. `copilot` is
    /// found again, rather than taken from the preferences, which any program running as you can change. A session the
    /// Copilot app has open, or one of its own, goes on there instead, where its history is.
    func continueInTerminal(_ entry: CopilotTaskEntry) {
        guard let run = entry.run, run.isValid else { return }
        Task {
            let environment = await environment()
            // Copilot may have started working in it, or in its checkout, meanwhile: going on with it then would fork its
            // history or mix their work.
            if isWorking(inSession: run.id) || isWorking(inFolder: run.worktree) {
                let alert = NSAlert()
                alert.messageText = "The session didn't open in Terminal"
                alert.informativeText = "Copilot is working in it, or in its checkout, now. Continue in Terminal once that's done."
                NSApp.activate()
                ThisMac.ask(alert)
                return
            }
            let isOpen = AppSessions.isOpen(run.id, home: CopilotCLI.home(environment: environment)) || AppSessions.isOpen(run.id, home: appHome)
            if run.isAppSession == true || isOpen {
                Self.openInAppOrSay(run.id)
                return
            }
            guard let copilot = CopilotCLI.locate(environment: environment) else {
                ThisMac.ask(NSAlert(error: LaunchError.copilotNotFound))
                return
            }
            let script = CopilotCommand.resumeScript(copilot: copilot, sessionId: run.id, directory: run.worktree, subject: run.subjectName)
            do {
                let directory = UserHome.url.appendingPathComponent("Library/Caches", isDirectory: true)
                    .appendingPathComponent(AppIdentity.bundleIdentifier, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent("Copilot \(run.onPullRequest.map { "PR \($0.id)" } ?? run.workItem.map { String($0.id) } ?? "task").command")
                try script.write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
                ThisMac.open(file)
            } catch {
                Log.app.error("Couldn't open Copilot's session in Terminal: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Opens a task's session in the Copilot app: one of the app's own, that a task went on with.
    func openSessionInApp(_ entry: CopilotTaskEntry) {
        guard let run = entry.run, run.isValid else { return }
        Self.openInAppOrSay(run.id)
    }

    /// Deletes the worktree's folder, after asking, and forgets the task. Its branch and pull request stay. Never the
    /// folder of one of the Copilot app's sessions, which is the app's; nor one that's in use (`worktreeInUse`), as
    /// looked at again after each answer, right before git deletes it.
    func removeWorktree(_ entry: CopilotTaskEntry) {
        guard let run = entry.run, run.isAppSession != true, !entry.status.phase.isActive else { return }
        Task {
            if let reason = await worktreeInUse(run) { return Self.sayNotRemoved(reason) }
            let alert = NSAlert()
            alert.messageText = "Remove the worktree for \(run.subjectName)?"
            alert.informativeText = "BriefBar deletes \(run.worktree.path). Its branch, its pull request and Copilot's session stay."
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            guard ThisMac.ask(alert) == .alertFirstButtonReturn else { return }
            do {
                try await deleteWorktree(of: run)
            } catch let error as WorktreeInUse {
                return Self.sayNotRemoved(error.reason)
            } catch {
                let alert = NSAlert()
                alert.messageText = "The worktree wasn't removed"
                alert.informativeText = "\(error)\n\nRemove it anyway, with any changes that aren't committed?"
                alert.addButton(withTitle: "Remove Anyway")
                alert.addButton(withTitle: "Cancel")
                guard ThisMac.ask(alert) == .alertFirstButtonReturn else { return }
                do {
                    try await deleteWorktree(of: run, force: true)
                } catch let error as WorktreeInUse {
                    return Self.sayNotRemoved(error.reason)
                } catch {
                    ThisMac.ask(NSAlert(error: error))
                    return
                }
            }
            clear(entry)
        }
    }

    /// Why a task's worktree can't be removed now, or nil: Copilot works in its checkout for a task BriefBar sent, in its
    /// session or another, such as one of the app's sessions that a task went on with there; or one of the app's sessions
    /// runs a turn there, the task's own too, once you went on with it in the app.
    func worktreeInUse(_ run: CopilotRun) async -> String? {
        if let reason = taskInWorktree(run) { return reason }
        if await anotherSessionRuns(inCheckoutOf: run.worktree, besides: nil) { return Self.turnInWorktree }
        return nil
    }

    /// Deletes a task's worktree with git, unless it's in use (`worktreeInUse`), as looked at right before. From that
    /// look until git is done, its checkout is busy (`busyFolders`), so no task of BriefBar's starts there meanwhile.
    func deleteWorktree(of run: CopilotRun, force: Bool = false) async throws {
        if let reason = taskInWorktree(run) { throw WorktreeInUse(reason: reason) }
        // Before anything is awaited, so that nothing starts there between the look and git.
        removingWorktrees[run.id] = run.worktree
        defer { removingWorktrees[run.id] = nil }
        if await anotherSessionRuns(inCheckoutOf: run.worktree, besides: nil) { throw WorktreeInUse(reason: Self.turnInWorktree) }
        if let removeWorktreeForTests {
            try await removeWorktreeForTests(run, force)
        } else {
            try await git().removeWorktree(at: run.worktree, of: run.repository, force: force)
        }
    }

    /// Why a task's worktree can't be removed now, as BriefBar's own tasks say, or nil.
    private func taskInWorktree(_ run: CopilotRun) -> String? {
        if removingWorktrees[run.id] != nil { return "BriefBar is removing it already." }
        let checkout = Self.checkoutKey(run.worktree)
        if deliveringFolders.values.contains(where: { Self.checkoutKey($0) == checkout }) {
            return "BriefBar is sending a prompt to a session that works in it. Remove it once that's done."
        }
        if isWorking(inSession: run.id) || isWorking(inFolder: run.worktree) {
            return "Copilot is working in it for a task BriefBar sent. Remove it once that's done."
        }
        return nil
    }

    private static let turnInWorktree = "Copilot is working in it now, in a session of the Copilot app. Remove it once that's done."

    private static func sayNotRemoved(_ reason: String) {
        let alert = NSAlert()
        alert.messageText = "The worktree wasn't removed"
        alert.informativeText = reason
        NSApp.activate()
        ThisMac.ask(alert)
    }
}

/// A worktree that Copilot works in now, which BriefBar doesn't remove.
struct WorktreeInUse: Error, Equatable {
    var reason: String
}

/// The ID of a send's session, which the CLI chooses for a fork once it's made: what the launcher's callbacks go by.
private final class LaunchedSession: Sendable {
    private let current: Mutex<String>

    init(_ id: String) {
        current = Mutex(id)
    }

    var id: String {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }
}
