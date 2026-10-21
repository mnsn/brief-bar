import BriefBarCore
import BriefBarUI
import Foundation
import NotificationCenterDB
import TeamsCore

/// Teams' command-line modes, mainly for checking what its lists would show.
package enum TeamsCommandLine: SourceCommandLine {
    package static let source = SourceID.teams
    package static var descriptionVersion: Int { TeamsSource.descriptionVersion }
    package static let flags = ["--diagnose", "--summaries"]
    package static let usage = """
        Microsoft Teams:
          --diagnose         Describe Notification Center's database and Teams' notifications by their
                             structure only, without names, messages or IDs, for an issue report
          --summaries        Summarize each unread chat in a sentence, with Apple's on-device model
          Run from Terminal, these read Notification Center with Terminal's Full Disk Access. Set
          BRIEFBAR_TEAMS_DB to read another Notification Center database, such as the demo data, and
          BRIEFBAR_TEAMS_STATE_DIR for the state that goes with it.
        """

    package static func run(_ options: CommandLineOptions) -> Int32? {
        if options.arguments.contains("--diagnose") {
            guard let storage = storage(options) else { return 1 }
            print(Diagnostics.report(paths: storage.paths, appVersion: AppIdentity.version))
            return 0
        }
        if options.arguments.contains("--summaries") {
            guard let storage = storage(options) else { return 1 }
            printSummaries(storage)
        }
        return nil
    }

    package static func dump(_ options: CommandLineOptions) -> Int32 {
        guard let storage = storage(options) else { return 1 }
        return printTable(storage.loadState(settings: trackerSettings))
    }

    package static func json(_ options: CommandLineOptions) -> [String: Any]? {
        guard let storage = storage(options) else { return nil }
        let (state, snapshot) = storage.loadState(settings: trackerSettings)
        let groups = ChatGroup.allCases
        return jsonObject(Output(
            access: snapshot.access.rawValue,
            problem: snapshot.problem.map { "\($0.title). \($0.message)" },
            counts: Dictionary(uniqueKeysWithValues: groups.map { ($0.rawValue, state.count($0)) }),
            unread: Dictionary(uniqueKeysWithValues: groups.map { ($0.rawValue, state.unread(in: $0).map(ChatOutput.init)) }),
            recent: Dictionary(uniqueKeysWithValues: groups.map { ($0.rawValue, state.recent(in: $0).map(ChatOutput.init)) })
        ))
    }

    /// Notification Center's database, read-only, or for the demo, only the one `BRIEFBAR_TEAMS_DB` names.
    private static func storage(_ options: CommandLineOptions) -> StorageMode? {
        let paths = NotificationPaths.default()
        if options.demo, paths.isSystemDatabase {
            fputs("There's no made-up Teams data: run make demo-data, or set \(NotificationPaths.databaseVariable).\n", stderr)
            return nil
        }
        return StorageMode.current(paths: paths).readOnly
    }

    /// The installed app's Keep Unread For, so the output matches its lists.
    static var trackerSettings: TrackerSettings {
        TrackerSettings(keepUnreadFor: AppSettings.KeepUnread.saved(in: AppIdentity.installedAppDefaults ?? .standard).interval)
    }

    private struct ChatOutput: Encodable {
        var name: String
        var kind: String
        var unread: Int
        var lastActivity: Date
        var latest: String?
        var link: String?

        init(_ conversation: ConversationSummary) {
            name = conversation.name
            kind = conversation.kind.rawValue
            unread = conversation.unreadCount
            lastActivity = conversation.lastActivity
            latest = (conversation.unread.last ?? conversation.latest)?.preview
            link = conversation.link?.absoluteString
        }
    }

    private struct Output: Encodable {
        var access: String
        var problem: String?
        var counts: [String: Int]
        var unread: [String: [ChatOutput]]
        var recent: [String: [ChatOutput]]
    }

    private static func printTable(_ loaded: (UnreadState, EngineSnapshot)) -> Int32 {
        let (state, snapshot) = loaded
        let now = Date()
        if let problem = snapshot.problem {
            print("! \(problem.title). \(problem.message)")
        }
        print(ChatGroup.allCases.map { "\($0.title): \(state.count($0)) unread" }.joined(separator: " · "))
        for group in ChatGroup.allCases {
            print("\nUNREAD \(group.title.uppercased())")
            for conversation in state.unread(in: group) {
                print(row(conversation, now: now))
            }
            let recent = state.recent(in: group)
            if !recent.isEmpty {
                print("RECENT \(group.title.uppercased())")
                for conversation in recent {
                    print(row(conversation, now: now))
                }
            }
        }
        return 0
    }

    private static func row(_ conversation: ConversationSummary, now: Date) -> String {
        let latest = (conversation.unread.last ?? conversation.latest)?.preview ?? ""
        let since = RelativeTime.short(conversation.unread.last?.deliveredAt ?? conversation.lastActivity, now: now)
        return "  " + [pad(conversation.name, 32), pad(conversation.unreadCount > 0 ? "\(conversation.unreadCount)" : "", 3),
                       pad(since, 4), String(latest.replacingOccurrences(of: "\n", with: " ").prefix(70))]
            .joined(separator: " ")
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        let clipped = text.count > width ? String(text.prefix(width - 1)) + "…" : text
        return clipped.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    /// Summarizes the unread chats one after the other, on this Mac, and prints how long each took.
    private static func printSummaries(_ storage: StorageMode) -> Never {
        let (state, snapshot) = storage.loadState(settings: trackerSettings)
        if let problem = snapshot.problem {
            print("! \(problem.title). \(problem.message)")
        }
        if let reason = Summarizer.unavailableReason {
            print(reason)
            exit(1)
        }
        let conversations = ChatGroup.allCases.flatMap { state.unread(in: $0) }
        if conversations.isEmpty {
            print("No unread chats.")
            exit(0)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        Task {
            for conversation in conversations {
                let started = ContinuousClock.now
                let result = await Summarizer.summarize(prompt: SummaryPrompt.prompt(for: conversation))
                let elapsed = (ContinuousClock.now - started).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))
                let text = switch result {
                case .done(let summary): summary
                case .failed(let reason): "(\(reason))"
                case .loading: ""
                }
                print("\(conversation.name) (\(conversation.unreadCount) unread, \(elapsed))\n  \(text)")
            }
            exit(0)
        }
        dispatchMain()
    }

    /// What `--watch` keeps running.
    nonisolated(unsafe) private static var watching: [Any] = []

    package static func watch(_ options: CommandLineOptions) {
        guard let storage = storage(options) else { exit(1) }
        let queue = DispatchQueue(label: "BriefBar.Teams.watch")
        let printer = WatchPrinter(storage: storage, settings: trackerSettings)
        let engine = NotificationEngine(paths: storage.paths) { snapshot in queue.async { printer.receive(snapshot) } }
        // Unread messages also expire with time alone.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(1))
        timer.setEventHandler { printer.report() }
        timer.resume()
        engine.start()
        setvbuf(stdout, nil, _IOLBF, 0)
        print("Watching \(storage.paths.database.path). Ctrl-C stops.")
        watching = [engine, timer, printer]
    }
}

/// Prints new unread messages and chats that were read. Confined to the watch queue.
private final class WatchPrinter: @unchecked Sendable {
    private var tracker: UnreadTracker
    private let settings: TrackerSettings
    private var problem: PulseProblem?
    private var previous: [String: ConversationSummary] = [:]
    private var counts: [ChatGroup: Int] = [:]
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(storage: StorageMode, settings: TrackerSettings) {
        let cached = storage.keyStore.map {
            UnreadCache(url: storage.paths.unreadFile, keyStore: $0).load(discardingUnreadable: false).conversations
        } ?? []
        tracker = UnreadTracker(launch: LaunchContext(state: StateStore(url: storage.paths.stateFile).load(),
                                                      cached: cached, launchedAt: Date()))
        self.settings = settings
    }

    func receive(_ snapshot: EngineSnapshot) {
        if snapshot.problem != problem {
            problem = snapshot.problem
            if let problem { line("! \(problem.title). \(problem.message)") }
        }
        if let notifications = snapshot.notifications {
            tracker.apply(notifications, now: Date())
        }
        report()
    }

    func report() {
        let now = Date()
        tracker.expire(now: now, settings: settings)
        let state = tracker.state(now: now, settings: settings)
        var current: [String: ConversationSummary] = [:]
        for group in ChatGroup.allCases {
            for conversation in state.unread(in: group) {
                current[conversation.id] = conversation
                let known = Set(previous[conversation.id]?.unread.map(\.key) ?? [])
                for message in conversation.unread where !known.contains(message.key) {
                    line("+ \(conversation.name) (\(group.title.lowercased())): \(message.preview.prefix(90))")
                }
            }
        }
        for (id, conversation) in previous where current[id] == nil {
            line("  read: \(conversation.name)")
        }
        let newCounts = Dictionary(uniqueKeysWithValues: ChatGroup.allCases.map { ($0, state.count($0)) })
        if newCounts != counts {
            line(ChatGroup.allCases.map { "\($0.title.lowercased()) \(newCounts[$0] ?? 0)" }.joined(separator: " · "))
            counts = newCounts
        }
        previous = current
    }

    private func line(_ text: String) {
        print("\(formatter.string(from: Date()))  \(text)")
    }
}
