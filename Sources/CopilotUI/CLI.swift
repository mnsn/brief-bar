
import BriefBarCore
import BriefBarUI
import CopilotCore
import Foundation

/// Copilot's command-line modes, mainly for checking what its list would show.
package enum CopilotCommandLine: SourceCommandLine {
    package static let source = SourceID.copilot
    package static var descriptionVersion: Int { CopilotSource.descriptionVersion }
    package static let usage = """
        GitHub Copilot:
          Set BRIEFBAR_COPILOT_DIR to read another Copilot data directory, such as the demo data
          that make demo-data writes to build/demo/copilot.
        """

    /// Your `~/.copilot`, or for the demo, only what `BRIEFBAR_COPILOT_DIR` names.
    private static func paths(_ options: CommandLineOptions) -> CopilotPaths? {
        if options.demo {
            guard let paths = CopilotPaths.overridden() else {
                fputs("There's no made-up Copilot data: run make demo-data, or set \(CopilotPaths.directoryVariable).\n", stderr)
                return nil
            }
            return paths
        }
        return CopilotPaths.default()
    }

    package static func dump(_ options: CommandLineOptions) -> Int32 {
        guard let paths = paths(options) else { return 1 }
        let state = SessionEngine.loadOnce(paths: paths)
        printTable(resolve(state, now: Date()), problem: state.problem)
        return 0
    }

    private struct Output: Encodable {
        var sessions: [SessionSnapshot]
        var counts: PhaseCounts
        var problem: String?
    }

    package static func json(_ options: CommandLineOptions) -> [String: Any]? {
        guard let paths = paths(options) else { return nil }
        let state = SessionEngine.loadOnce(paths: paths)
        let sessions = resolve(state, now: Date())
        return jsonObject(Output(sessions: sessions, counts: PhaseCounts(sessions), problem: state.problem))
    }

    static func resolve(_ state: EngineSnapshot, now: Date) -> [SessionSnapshot] {
        SessionOrdering.sorted(state.records.map {
            StatusResolver.snapshot(for: $0, now: now, view: state.view)
        })
    }

    private static func printTable(_ sessions: [SessionSnapshot], problem: String?) {
        if let problem { print("! \(problem)") }
        let now = Date()
        let counts = PhaseCounts(sessions)
        print("needs you \(counts.needsYou) · running \(counts.running) · done \(counts.done) · stopped \(counts.stopped) · idle \(counts.idle)")
        print(row("PHASE", "STATUS", "SINCE", "SESSION", "DETAIL"))
        for session in sessions {
            let name = session.projectName.map { "\(session.displayName) [\($0)]" } ?? session.displayName
            print(row(
                session.phase.rawValue, session.headline, Elapsed.short(since: session.since, now: now),
                name, session.detail ?? ""
            ))
        }
    }

    private static func row(_ phase: String, _ status: String, _ since: String, _ name: String, _ detail: String) -> String {
        [pad(phase, 9), pad(status, 24), pad(since, 7), pad(name, 46), String(detail.prefix(70))].joined(separator: " ")
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        let clipped = text.count > width ? String(text.prefix(width - 1)) + "…" : text
        return clipped.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    /// What `--watch` keeps running.
    nonisolated(unsafe) private static var watching: [Any] = []

    package static func watch(_ options: CommandLineOptions) {
        guard let paths = paths(options) else { exit(1) }
        let queue = DispatchQueue(label: "BriefBar.Copilot.watch")
        let printer = WatchPrinter()
        let engine = SessionEngine(paths: paths) { state in queue.async { printer.print(state) } }
        // Statuses also change with time alone, e.g. "done" turns "idle" after an hour.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { printer.refresh() }
        timer.resume()
        engine.start()
        setvbuf(stdout, nil, _IOLBF, 0)
        print("Watching \(engine.paths.root.path) — Ctrl-C to stop")
        watching = [engine, timer, printer]
    }
}

/// Prints only the sessions whose displayed status changed. Confined to the watch queue.
private final class WatchPrinter: @unchecked Sendable {
    private var latest: EngineSnapshot?
    private var problem: String?
    private var previous: [String: SessionSnapshot] = [:]
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    func print(_ state: EngineSnapshot) {
        latest = state
        report(state)
    }

    /// Resolves the latest state again at the current time.
    func refresh() {
        if let latest { report(latest) }
    }

    private func report(_ state: EngineSnapshot) {
        let now = Date()
        if state.problem != problem {
            problem = state.problem
            if let problem { Swift.print("\(formatter.string(from: now))  ! \(problem)") }
        }
        for session in CopilotCommandLine.resolve(state, now: now) {
            let old = previous[session.id]
            previous[session.id] = session
            guard old == nil || old?.phase != session.phase || old?.headline != session.headline
                || old?.detail != session.detail
            else { continue }
            if old == nil, session.phase == .idle { continue }
            let detail = session.detail.map { " — \($0.prefix(90))" } ?? ""
            Swift.print("\(formatter.string(from: now))  \(session.phase.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(session.headline): \(session.displayName)\(detail)")
        }
    }
}
