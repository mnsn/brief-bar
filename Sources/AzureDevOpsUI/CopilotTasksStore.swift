import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Combine
import CopilotTasks

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

    var workItemURL: URL? {
        workItem.map { ADOEndpoint.workItemPage(organization: $0.organization, project: $0.project, id: $0.id) }
    }

    /// Whether it works on this pull request.
    func isOn(_ key: PRKey) -> Bool {
        onPullRequest?.matches(organization: key.organization, id: key.number) == true
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
            // Fixing the demo's failing pull request.
            CopilotTaskEntry(
                id: "1d6b2c7e-4f0a-4b8e-9c31-5a2e7d8f6b03", workItem: nil,
                onPullRequest: PullRequestReference(organization: DemoData.organization, project: "Storefront", repository: "shop-web",
                                                    id: 4088, sourceBranch: "delivery-estimates"),
                action: .fixBuild, options: CopilotModel.standard, startedAt: now.addingTimeInterval(-9 * 60),
                status: RunStatus(phase: .working, detail: "Run DeliveryEstimateTests"),
                pullRequest: URL(string: "https://dev.azure.com/\(DemoData.organization)/Storefront/_git/shop-web/pullrequest/4088")
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
    /// A work item's title, when the sprint shows it, for notifications.
    var title: (WorkItemReference) -> String? = { _ in nil }
    /// A pull request's title, when the list shows it, for notifications.
    var pullRequestTitle: (PullRequestReference) -> String? = { _ in nil }
    /// A task that takes care of a pull request's comments started, with what its prompt handed off and the prompt you sent:
    /// for the list, to take those comments off Needs You.
    var handedOff: (CommentHandOff, _ prompt: String) -> Void = { _, _ in }
    /// The sessions Show Links links to a work item or a pull request, and why: nothing while it's off.
    var linkedSessions: (ItemRef) -> [LinkedSession] = { _ in [] }
    /// Stands in for getting a task's worktree ready and starting Copilot, in tests, which start nothing.
    var launchForTests: ((CopilotLauncher.Request, _ id: String, _ now: Date) async throws -> CopilotRun)?
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
            shown.status = statuses[run.id] ?? next.status
            return shown
        }
        let waiting = pending.filter { entry in !runs.contains { $0.id == entry.id } }
        return (waiting + runs + demoEntries).sorted { $0.startedAt > $1.startedAt }
    }

    private func entry(for run: CopilotRun, status: RunStatus) -> CopilotTaskEntry {
        CopilotTaskEntry(
            id: run.id, workItem: run.workItem, onPullRequest: run.onPullRequest, action: run.action, options: run.options,
            startedAt: run.startedAt, status: status, pullRequest: run.pullRequest, run: run
        )
    }

    private var demoEntries: [CopilotTaskEntry] {
        mode == .demo ? CopilotTaskEntry.demo(now: Date()) : []
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

    /// The run a new task on a pull request goes on with: its latest one, ended, whose worktree is still there.
    func continuable(forPullRequest key: PRKey) -> CopilotRun? {
        guard let entry = latest(forPullRequest: key), !entry.status.phase.isActive, let run = entry.run,
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

    /// Your login shell's environment: the one asked for last, unless `fresh`.
    func environment(fresh: Bool = false) async -> [String: String] {
        if !fresh, let loginEnvironment { return loginEnvironment }
        let environment = await LoginEnvironment.load()
        loginEnvironment = environment
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
        send(task, prompt: PromptTemplate.render(settings.copilotPromptTemplate, item: task), options: options, repository: repository)
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
    func compose(
        _ pullRequest: TaskPullRequest, action: PullRequestAction, prompt: String, sessionPrompt: String? = nil, createdAt: Date? = nil,
        handOff: CommentHandOff? = nil
    ) {
        let key = PRKey(pullRequest.organization, pullRequest.id)
        CopilotComposer.shared.show(
            subject: .pullRequest(pullRequest, action), prompt: prompt, sessionPrompt: sessionPrompt, createdAt: createdAt,
            options: settings.copilotOptions, continuing: continuable(forPullRequest: key), handOff: handOff, store: self
        )
    }

    /// Starts Copilot on a work item or a pull request; or goes on with a session that's there already: an earlier run's,
    /// in its worktree, or one of the Copilot app's (`appRun(for:subject:options:)`), in the folder it works in. Once it
    /// has started, what `handOff` says its prompt took care of leaves Needs You.
    func send(
        _ subject: TaskSubject, prompt: String, options: CopilotRunOptions, repository: URL, continuing: CopilotRun? = nil,
        handOff: CommentHandOff? = nil
    ) {
        guard canSend, isOn else { return }
        // A second run in a session Copilot still works in would fork its history; one in a checkout it works in, for another
        // session, would mix their work up, as when two of the Copilot app's sessions share one.
        if let continuing, isWorking(inSession: continuing.id) || isWorking(inFolder: continuing.worktree) {
            Log.app.error("Didn't send a task to Copilot: it still works in that session or its folder")
            return
        }
        // An app's session's folder is no repository to start new work in.
        if continuing?.isAppSession != true {
            switch subject {
            case .workItem(let item): settings.copilotRepositories[item.reference.projectKey] = repository.path
            case .pullRequest(let pullRequest, _): settings.copilotRepositories[pullRequest.reference.repositoryKey] = repository.path
            }
        }
        let id = continuing?.id ?? UUID().uuidString.lowercased()
        let now = Date()
        var entry = CopilotTaskEntry(id: id, workItem: nil, options: options, startedAt: now, status: RunStatus(phase: .preparing, since: now))
        switch subject {
        case .workItem(let item):
            entry.workItem = item.reference
        case .pullRequest(let pullRequest, let action):
            entry.onPullRequest = pullRequest.reference
            entry.action = action
            entry.pullRequest = pullRequest.url
        }
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
        // Copilot works on its own, and nothing opens: say it's on it, now, rather than once its worktree is ready.
        notifyStarted(entry)
        let request = CopilotLauncher.Request(
            subject: subject, prompt: prompt, options: options, repository: repository,
            worktreesFolder: settings.copilotWorktreesFolder.map { URL(fileURLWithPath: $0, isDirectory: true) }, continuing: continuing
        )
        Task { [self] in
            do {
                // Again, as it starts: another of the app's sessions may have started a turn in the same checkout since the
                // window looked. The launcher looks once more right before Copilot starts, after its git commands.
                if let continuing, await anotherSessionRuns(inCheckoutOf: continuing.worktree, besides: id) {
                    throw LaunchError.sharedCheckout
                }
                let run: CopilotRun
                if let launchForTests {
                    run = try await launchForTests(request, id, now)
                } else {
                    // Asked again for each send, so a tool you've just installed is found.
                    let environment = await environment(fresh: true)
                    let launcher = CopilotLauncher(outputFolder: Self.outputFolder, environment: { environment }, appHome: appHome)
                    run = try await launcher.launch(request, id: id, now: now) { [weak self] status in
                        MainActor.assumeIsolated { self?.exited(id, status: status) }
                    }
                }
                startedHere.insert(id)
                pending.removeAll { $0.id == id }
                continuingFolders[id] = nil
                statuses[id] = nil
                if let index = settings.copilotRuns.firstIndex(where: { $0.id == id }) {
                    settings.copilotRuns[index] = run
                } else {
                    settings.copilotRuns.append(run)
                }
                Log.app.info("Sent a task to Copilot\(continuing == nil ? "" : ", going on with its session", privacy: .public)")
                if let handOff { handedOff(handOff, prompt) }
                refresh()
            } catch {
                Log.app.error("Couldn't send a task to Copilot: \(Self.kind(of: error), privacy: .public)")
                continuingFolders[id] = nil
                let status = RunStatus(phase: .failed, since: Date(), detail: String(describing: error))
                if let index = pending.firstIndex(where: { $0.id == id }) {
                    pending[index].status = status
                    notify(pending[index], status: status)
                }
                if continuing != nil {
                    // The earlier run stays as it ended; this send's failure is in its place until it's cleared.
                    statuses[id] = status
                }
            }
        }
    }

    /// The checkouts that tasks of BriefBar's work in now (`checkoutKey`): those of sends that go on with a session, while
    /// they get ready, and those of runs whose Copilot process still runs; and those of worktrees git removes now. A new
    /// task's worktree is its own.
    func busyFolders() -> Set<String> {
        var folders = Set(removingWorktrees.values.map(Self.checkoutKey))
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
    /// on. Whether a run's process still runs is checked first: once it's gone, its log and output are complete.
    func refresh() {
        guard mode == .live, isOn else {
            scheduleIfNeeded()
            return
        }
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
            var results: [(run: CopilotRun, status: RunStatus, pullRequest: URL?)] = []
            for run in runs {
                let events = run.events(in: copilotHome)
                if DetachedProgram.isRunning(run.process) || awaitsExit(of: run) {
                    // Working, whatever its log says for now; the log gives its current step.
                    let log = await monitor.log(id: run.id, events: events)
                    results.append((run, RunStatus.derive(log: log, isRunning: true, exitStatus: nil, stoppedByYou: false, output: nil), nil))
                    continue
                }
                let log = await monitor.log(id: run.id, events: events)
                let output = output(of: run)
                let needsLink = run.pullRequest == nil
                let found = await Task.detached { () -> (String?, URL?) in
                    let printed = LocalFile.tail(of: output, maxBytes: 8_192).map { String(decoding: $0, as: UTF8.self) }
                    guard needsLink else { return (printed, nil) }
                    let words = RunTranscript.lastWords(events: events)
                    let link = [words.summary, words.message, printed].compactMap { $0 }.lazy
                        .compactMap { RunTranscript.pullRequest(in: $0) }.first
                    return (printed, link)
                }.value
                let status = RunStatus.derive(
                    log: log, isRunning: false, exitStatus: exitStatuses[run.id], stoppedByYou: wasStoppedByYou(run.id),
                    output: found.0
                )
                results.append((run, status, found.1))
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

    private func apply(_ results: [(run: CopilotRun, status: RunStatus, pullRequest: URL?)]) {
        for result in results {
            if statuses[result.run.id] != result.status { statuses[result.run.id] = result.status }
            // Cleared while it was read.
            guard let index = settings.copilotRuns.firstIndex(where: { $0.id == result.run.id }) else { continue }
            var run = settings.copilotRuns[index]
            if run.pullRequest == nil, let pullRequest = result.pullRequest { run.pullRequest = pullRequest }
            if !result.status.phase.isActive, run.ended == nil {
                run.ended = result.status.phase
                Log.app.info("A task sent to Copilot ended: \(result.status.phase.rawValue, privacy: .public)")
                notify(entry(for: run, status: result.status), status: result.status)
            }
            if run != settings.copilotRuns[index] { settings.copilotRuns[index] = run }
        }
    }

    /// Every few seconds while something runs and the feature is on; not at all otherwise.
    private func scheduleIfNeeded() {
        let busy = mode == .live && isOn
            && (settings.copilotRuns.contains { $0.isValid && $0.ended == nil } || pending.contains { $0.status.phase.isActive })
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
        let subject = subject(of: entry)
        let heading: String
        let body: String
        var state = ItemState.done
        switch status.phase {
        case .finished where entry.action != nil:
            switch entry.action {
            case .review?: heading = "Copilot's review is ready"
            case .pushAndReply?: heading = "Copilot pushed and replied"
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
            return
        }
        notifier.post([BriefBarNotification(
            id: Self.notificationID(entry.id), source: .azureDevOps, state: state, title: heading, subtitle: subject, body: body,
            thread: "copilot", userInfo: (entry.pullRequest ?? entry.workItemURL).map { ["url": $0.absoluteString] } ?? [:]
        )])
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
            heading = "Copilot is fixing the comments"
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
        case .pushAndReply?:
            heading = "Copilot is pushing and replying"
            body = "It commits, pushes the branch and replies on the threads it addressed, as you."
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

    /// What BriefBar saved of the runs it started: what each printed. Called when Azure DevOps is turned off.
    nonisolated static func deleteOutput() {
        try? FileManager.default.removeItem(at: outputFolder)
    }

    func openPullRequest(_ entry: CopilotTaskEntry) {
        if let url = entry.pullRequest { AzureDevOps.open(url) }
    }

    func openWorkItem(_ entry: CopilotTaskEntry) {
        if let url = entry.workItemURL { AzureDevOps.open(url) }
    }

    func showWorktree(_ entry: CopilotTaskEntry) {
        guard let run = entry.run else { return }
        NSWorkspace.shared.activateFileViewerSelecting([run.worktree])
    }

    func showOutput(_ entry: CopilotTaskEntry) {
        guard let run = entry.run, run.isValid, !LocalFile.isLink(output(of: run)) else { return }
        NSWorkspace.shared.open(output(of: run))
    }

    /// Goes on with Copilot's session in Terminal, in its worktree, to ask for more or see what it did. `copilot` is
    /// found again, rather than taken from the preferences, which any program running as you can change. A session the
    /// Copilot app has open, or one of its own, goes on there instead, where its history is.
    func continueInTerminal(_ entry: CopilotTaskEntry) {
        guard let run = entry.run, run.isValid else { return }
        Task {
            let environment = await environment()
            let isOpen = AppSessions.isOpen(run.id, home: CopilotCLI.home(environment: environment)) || AppSessions.isOpen(run.id, home: appHome)
            if run.isAppSession == true || isOpen {
                Self.openInAppOrSay(run.id)
                return
            }
            guard let copilot = CopilotCLI.locate(environment: environment) else {
                NSAlert(error: LaunchError.copilotNotFound).runModal()
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
                NSWorkspace.shared.open(file)
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
            guard alert.runModal() == .alertFirstButtonReturn else { return }
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
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                do {
                    try await deleteWorktree(of: run, force: true)
                } catch let error as WorktreeInUse {
                    return Self.sayNotRemoved(error.reason)
                } catch {
                    NSAlert(error: error).runModal()
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
        alert.runModal()
    }
}

/// A worktree that Copilot works in now, which BriefBar doesn't remove.
struct WorktreeInUse: Error, Equatable {
    var reason: String
}
