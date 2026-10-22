import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Combine
import CopilotTasks

/// A task sent to Copilot, as its work item's row shows it: getting ready, working, or how it ended.
struct CopilotTaskEntry: Identifiable, Equatable {
    /// The ID of Copilot's session.
    var id: String
    var workItem: WorkItemReference
    var options: CopilotRunOptions
    var startedAt: Date
    var status: RunStatus
    var pullRequest: URL?
    /// Nil while its worktree is getting ready, and when it couldn't start.
    var run: CopilotRun?

    var workItemURL: URL {
        ADOEndpoint.workItemPage(organization: workItem.organization, project: workItem.project, id: workItem.id)
    }
}

extension WorkItem {
    /// What a task sent to Copilot needs to know about it.
    var copilotTask: TaskWorkItem {
        TaskWorkItem(organization: organization, project: project, id: id, type: type, title: title, url: webURL)
    }
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

    private let notifier: Notifier?
    private let monitor = RunMonitor()
    /// How each run's process ended, for those that ended while BriefBar ran.
    private var exitStatuses: [String: Int32] = [:]
    /// Runs started since BriefBar launched, whose exit it hears about, and since when each one's process is gone
    /// without BriefBar having heard yet.
    private var startedHere: Set<String> = []
    private var goneSince: [String: Date] = [:]
    private var stoppedByYou: Set<String> = []
    private var timer: Timer?
    private var isRefreshing = false
    private var cancellables: Set<AnyCancellable> = []
    /// Your login shell's environment, asked for again with each send.
    private var loginEnvironment: [String: String]?

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
        let runs = settings.copilotRuns.filter(\.isValid).map { run in
            CopilotTaskEntry(
                id: run.id, workItem: run.workItem, options: run.options, startedAt: run.startedAt,
                status: statuses[run.id] ?? RunStatus(phase: run.ended ?? .working), pullRequest: run.pullRequest, run: run
            )
        }
        return (pending + runs + demoEntries).sorted { $0.startedAt > $1.startedAt }
    }

    /// Made-up sends of the demo sprint's tasks: one that opened a pull request, and one still working.
    private var demoEntries: [CopilotTaskEntry] {
        guard mode == .demo else { return [] }
        let team = DemoData.team
        let now = Date()
        return [
            CopilotTaskEntry(
                id: "demo-finished", workItem: WorkItemReference(organization: team.organization, project: team.projectName, id: 5112),
                options: CopilotModel.standard, startedAt: now.addingTimeInterval(-41 * 60),
                status: RunStatus(phase: .finished, since: now.addingTimeInterval(-12 * 60),
                                  detail: "Coupon totals now round half up, with tests for every currency. Opened pull request 31."),
                pullRequest: URL(string: "https://dev.azure.com/\(team.organization)/\(team.projectName)/_git/storefront/pullrequest/31")
            ),
            CopilotTaskEntry(
                id: "demo-working", workItem: WorkItemReference(organization: team.organization, project: team.projectName, id: 5103),
                options: CopilotModel.quick, startedAt: now.addingTimeInterval(-6 * 60),
                status: RunStatus(phase: .working, detail: "Run the cart tests")
            ),
        ]
    }

    /// The latest send of a work item, for its row.
    func latest(for item: WorkItem) -> CopilotTaskEntry? {
        let reference = item.copilotTask.reference
        return entries.first { $0.workItem.matches(reference) }
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
                    // Copilot's logs are read only while the feature is on; turned back on, its runs are followed again.
                    self?.refresh()
                }
            }
            .store(in: &cancellables)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Sending

    /// Opens the composer, to check the prompt, the model and the repository before sending.
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
        guard canSend, isOn else { return }
        settings.copilotRepositories[item.reference.projectKey] = repository.path
        let id = UUID().uuidString.lowercased()
        let now = Date()
        pending.append(CopilotTaskEntry(
            id: id, workItem: item.reference, options: options, startedAt: now, status: RunStatus(phase: .preparing, since: now)
        ))
        let request = CopilotLauncher.Request(
            workItem: item, prompt: prompt, options: options, repository: repository,
            worktreesFolder: settings.copilotWorktreesFolder.map { URL(fileURLWithPath: $0, isDirectory: true) }
        )
        Task { [self] in
            // Asked again for each send, so a tool you've just installed is found.
            let environment = await environment(fresh: true)
            let launcher = CopilotLauncher(outputFolder: Self.outputFolder, environment: { environment })
            do {
                let run = try await launcher.launch(request, id: id, now: now) { [weak self] status in
                    MainActor.assumeIsolated { self?.exited(id, status: status) }
                }
                startedHere.insert(id)
                pending.removeAll { $0.id == id }
                settings.copilotRuns.append(run)
                Log.app.info("Sent a work item to Copilot")
                refresh()
            } catch {
                Log.app.error("Couldn't send a work item to Copilot: \(Self.kind(of: error), privacy: .public)")
                let status = RunStatus(phase: .failed, since: Date(), detail: String(describing: error))
                if let index = pending.firstIndex(where: { $0.id == id }) {
                    pending[index].status = status
                    notify(pending[index], status: status)
                }
            }
        }
    }

    /// What went wrong, without paths or names, for the log.
    private static func kind(of error: Error) -> String {
        switch error as? LaunchError {
        case .copilotNotFound?: return "the Copilot CLI isn't installed"
        case .git(.notARepository)?: return "not a git repository"
        case .git(.noOrigin)?: return "no origin remote"
        case .git(.failed)?: return "git failed"
        case .couldntStart?: return "Copilot couldn't start"
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
                    log: log, isRunning: false, exitStatus: exitStatuses[run.id], stoppedByYou: stoppedByYou.contains(run.id),
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
                notify(CopilotTaskEntry(
                    id: run.id, workItem: run.workItem, options: run.options, startedAt: run.startedAt, status: result.status,
                    pullRequest: run.pullRequest, run: run
                ), status: result.status)
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

    private func notify(_ entry: CopilotTaskEntry, status: RunStatus) {
        guard settings.notifications, let notifier, !stoppedByYou.contains(entry.id) else { return }
        let subject = title(entry.workItem).map { "\(entry.workItem.id): \($0)" } ?? "Work item \(entry.workItem.id)"
        let heading: String
        let body: String
        switch status.phase {
        case .finished:
            heading = entry.pullRequest != nil ? "Copilot opened a pull request" : "Copilot finished"
            body = Self.firstLine(status.detail) ?? (entry.pullRequest != nil ? "It's ready for review." : "It didn't say what it did.")
        case .failed:
            heading = "Copilot couldn't finish"
            body = Self.firstLine(status.detail) ?? "It reported an error."
        case .stopped:
            heading = "Copilot stopped"
            body = "It stopped before it finished."
        case .preparing, .working:
            return
        }
        notifier.post([BriefBarNotification(
            id: "copilot.\(entry.id)", source: .azureDevOps, title: heading, subtitle: subject, body: body, thread: "copilot",
            userInfo: ["url": (entry.pullRequest ?? entry.workItemURL).absoluteString]
        )])
    }

    nonisolated static func firstLine(_ text: String?) -> String? {
        text?.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    // MARK: A run's actions

    func stop(_ entry: CopilotTaskEntry) {
        guard let run = entry.run else { return }
        stoppedByYou.insert(run.id)
        DetachedProgram.stop(run.process)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
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
        AzureDevOps.open(entry.workItemURL)
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
    /// found again, rather than taken from the preferences, which any program running as you can change.
    func continueInTerminal(_ entry: CopilotTaskEntry) {
        guard let run = entry.run, run.isValid else { return }
        Task {
            guard let copilot = CopilotCLI.locate(environment: await environment()) else {
                NSAlert(error: LaunchError.copilotNotFound).runModal()
                return
            }
            let script = CopilotCommand.resumeScript(copilot: copilot, sessionId: run.id, directory: run.worktree, workItem: run.workItem.id)
            do {
                let directory = UserHome.url.appendingPathComponent("Library/Caches", isDirectory: true)
                    .appendingPathComponent(AppIdentity.bundleIdentifier, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent("Copilot \(run.workItem.id).command")
                try script.write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
                NSWorkspace.shared.open(file)
            } catch {
                Log.app.error("Couldn't open Copilot's session in Terminal: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Deletes the worktree's folder, after asking, and forgets the task. Its branch and pull request stay.
    func removeWorktree(_ entry: CopilotTaskEntry) {
        guard let run = entry.run, !entry.status.phase.isActive else { return }
        let alert = NSAlert()
        alert.messageText = "Remove the worktree for work item \(run.workItem.id)?"
        alert.informativeText = "BriefBar deletes \(run.worktree.path). Its branch, its pull request and Copilot's session stay."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            let git = await git()
            do {
                try await git.removeWorktree(at: run.worktree, of: run.repository)
            } catch {
                let alert = NSAlert()
                alert.messageText = "The worktree wasn't removed"
                alert.informativeText = "\(error)\n\nRemove it anyway, with any changes that aren't committed?"
                alert.addButton(withTitle: "Remove Anyway")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                do {
                    try await git.removeWorktree(at: run.worktree, of: run.repository, force: true)
                } catch {
                    NSAlert(error: error).runModal()
                    return
                }
            }
            clear(entry)
        }
    }
}
