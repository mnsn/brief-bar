import AppKit
import Combine
import BriefBarCore
import BriefBarUI
import CopilotCore

/// Main-thread view model: turns engine snapshots into the sorted, resolved session list, with the tasks BriefBar sent to
/// the Copilot CLI, which the app doesn't list.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [SessionSnapshot] = []
    @Published private(set) var counts = PhaseCounts()
    /// Reference time for relative labels; ticks every 15 s.
    @Published private(set) var now = Date()
    @Published private(set) var problem: String?
    @Published private(set) var hasLoaded = false
    /// The tasks in `sessions`, by their sessions' IDs: what their rows open, and their menus.
    @Published private(set) var tasks: [String: SentTask] = [:]

    private let settings: AppSettings
    /// Where the Copilot app's files are; nil for the demo without made-up data, which reads nothing.
    let paths: CopilotPaths?
    /// The tasks BriefBar sent to the Copilot CLI, as the source that sent them says.
    private let sentTasks: SentTasks?
    private var engine: SessionEngine?
    private var state = EngineSnapshot()
    private var ticker: Timer?
    private var cancellables: Set<AnyCancellable> = []
    /// Show Links: the engine reads where each session's work goes too.
    private var readsLinks = false

    init(settings: AppSettings, paths: CopilotPaths?, sentTasks: SentTasks? = nil) {
        self.settings = settings
        self.paths = paths
        self.sentTasks = sentTasks
    }

    var activeSessions: [SessionSnapshot] { sessions.filter { $0.phase != .idle } }

    func sessions(in phase: DisplayPhase) -> [SessionSnapshot] {
        sessions.filter { $0.phase == phase }
    }

    func start() {
        guard engine == nil, ticker == nil else { return }
        guard let paths else {
            problem = "There's no made-up Copilot data. Run make demo-data, or set \(CopilotPaths.directoryVariable)."
            hasLoaded = true
            return
        }
        let engine = SessionEngine(paths: paths) { [weak self] state in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.receive(state) }
            }
        }
        self.engine = engine
        engine.setReadsLinks(readsLinks)
        engine.start()

        settings.$keepEndedMinutes.map { _ in () }
            .merge(with: settings.$acknowledged.map { _ in () })
            .dropFirst(2)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.recompute() } }
            .store(in: &cancellables)

        // After the change: a @Published value emits before it's set.
        sentTasks?.$tasks.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.recompute() } }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.recompute() } }
            .store(in: &cancellables)

        let ticker = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recompute() }
        }
        ticker.tolerance = 3
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    /// Stops watching, and forgets what it read.
    func stop() {
        engine?.stop()
        engine = nil
        ticker?.invalidate()
        ticker = nil
        cancellables.removeAll()
        state = EngineSnapshot()
        sessions = []
        tasks = [:]
        counts = PhaseCounts()
        problem = nil
        hasLoaded = false
    }

    func refresh() {
        engine?.refresh()
    }

    /// Whether to read where each session's work goes too, for Show Links.
    func setReadsLinks(_ reads: Bool) {
        readsLinks = reads
        engine?.setReadsLinks(reads)
    }

    /// Opens the session in the Copilot app, or a task what it's for; opening a finished one also dismisses it.
    func open(_ session: SessionSnapshot) {
        if session.phase == .done || session.phase == .stopped {
            settings.acknowledge([session.id])
        }
        if let task = tasks[session.id] {
            task.open()
        } else {
            CopilotApp.open(sessionId: session.id)
        }
    }

    /// The task BriefBar sent that a row shows, rather than a session of the app's.
    func task(for id: String) -> SentTask? {
        tasks[id]
    }

    func clear(_ phase: DisplayPhase) {
        settings.acknowledge(sessions(in: phase).map(\.id))
    }

    func receive(_ state: EngineSnapshot) {
        self.state = state
        hasLoaded = true
        if problem != state.problem {
            problem = state.problem
            if let problem { Log.app.error("\(problem, privacy: .public)") }
        }
        recompute()
    }

    private func recompute() {
        let now = Date()
        let options = ResolverOptions(recentWindow: TimeInterval(settings.keepEndedMinutes * 60))
        var resolved = state.records.map {
            StatusResolver.snapshot(
                for: $0, now: now, options: options, view: state.view, acknowledgedAt: settings.acknowledged[$0.id]
            )
        }

        // A session the user is looking at in the Copilot app right now doesn't need highlighting.
        if CopilotApp.isFrontmost, let viewed = state.view.viewedSessionId,
           let index = resolved.firstIndex(where: { $0.id == viewed }),
           resolved[index].phase == .done || resolved[index].phase == .stopped {
            settings.acknowledge([viewed], at: now)
            resolved[index] = StatusResolver.snapshot(
                for: state.records[index], now: now, options: options, view: state.view, acknowledgedAt: now
            )
        }

        // The tasks BriefBar sent. Once you open one's session in the app, its database lists it, and then it's the app's;
        // without the database, every recent session folder is listed, the tasks' too, and those are the tasks'.
        let sent = sentTasks?.tasks ?? []
        if !state.listedByApp {
            let ids = Set(sent.map(\.id))
            resolved.removeAll { ids.contains($0.id) }
        }
        var shown: [String: SentTask] = [:]
        let listed = Set(resolved.map(\.id))
        for task in sent where !listed.contains(task.id) && shown[task.id] == nil {
            shown[task.id] = task
            resolved.append(Self.snapshot(of: task, now: now, options: options, acknowledgedAt: settings.acknowledged[task.id]))
        }

        let sorted = SessionOrdering.sorted(resolved)
        self.now = now
        // Before the sessions, which Show Links reads them with.
        if shown != tasks { tasks = shown }
        if sorted != sessions { sessions = sorted }
        let newCounts = PhaseCounts(sorted)
        if newCounts != counts { counts = newCounts }
    }

    /// A task BriefBar sent, as the list shows it with the sessions: running while it gets ready and works; once it ends,
    /// highlighted until you've seen it or Keep Finished Sessions For passes, as a session is. One you stopped yourself
    /// is idle at once.
    static func snapshot(of task: SentTask, now: Date, options: ResolverOptions, acknowledgedAt: Date?) -> SessionSnapshot {
        let reason: StatusReason
        switch task.stage {
        case .starting: reason = .starting
        case .working: reason = .working
        case .finished: reason = .finished
        case .failed: reason = .failed
        case .stopped: reason = .interrupted
        }
        let isSeen = task.stoppedByYou || acknowledgedAt.map { $0 >= (task.since ?? .distantPast) } == true
        return StatusResolver.snapshot(
            unlisted: task.id, name: task.name, place: task.place, reason: reason, detail: task.detail, since: task.since,
            now: now, options: options, isSeen: isSeen
        )
    }
}
