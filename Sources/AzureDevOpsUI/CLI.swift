import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Foundation

/// Azure DevOps' command-line modes, mainly for checking what its list would show.
package enum AzureDevOpsCommandLine: SourceCommandLine {
    package static let source = SourceID.azureDevOps
    package static var descriptionVersion: Int { AzureDevOpsSource.descriptionVersion }
    package static let flags = ["--orgs"]
    package static let usage = """
        Azure DevOps:
          --orgs             List your organizations, and the ones where you have pull requests
          --org <name>       Read this organization instead of the app's choice (repeatable)
          It signs in with the Azure CLI (az login) and only reads: every request is a GET. Set
          BRIEFBAR_AZ to the path of az to use another one.
        """

    struct Options {
        var demo = false
        var organizations: [String] = []

        init(_ options: CommandLineOptions) {
            demo = options.demo
            let arguments = options.arguments
            var index = 0
            while index < arguments.count {
                if arguments[index] == "--org", index + 1 < arguments.count {
                    organizations.append(arguments[index + 1])
                    index += 1
                }
                index += 1
            }
        }
    }

    package static func run(_ options: CommandLineOptions) -> Int32? {
        // The demo never uses the Azure CLI, your settings or Azure DevOps.
        guard options.arguments.contains("--orgs") else { return nil }
        return options.demo ? listDemoOrganizations() : listOrganizations()
    }

    package static func dump(_ options: CommandLineOptions) -> Int32 {
        let loaded = load(Options(options))
        printTable(loaded)
        return loaded.items.isEmpty && loaded.problem != nil ? 1 : 0
    }

    private struct Output: Encodable {
        var organizations: [String]
        var counts: GroupCounts
        var items: [PRSnapshot]
        var problem: String?
    }

    package static func json(_ options: CommandLineOptions) -> [String: Any]? {
        let loaded = load(Options(options))
        return jsonObject(Output(organizations: loaded.organizations, counts: GroupCounts(loaded.items), items: loaded.items,
                                 problem: loaded.problem))
    }

    package static func watch(_ options: CommandLineOptions) -> Bool {
        let options = Options(options)
        if options.demo {
            watchDemo()
            return false
        }
        startWatching(options)
        return true
    }

    // MARK: Loading

    struct Loaded {
        var organizations: [String]
        var items: [PRSnapshot]
        var problem: String?
    }

    /// The installed app's settings (read-only), so the output matches its list.
    private static var appDefaults: UserDefaults? { AppSettings.appDefaults }

    private static func classifierOptions() -> ClassifierOptions {
        let defaults = appDefaults
        let idleDays = defaults?.object(forKey: SettingsKey.idleDays) as? Int ?? 14
        let keepDoneHours = defaults?.object(forKey: SettingsKey.keepDoneHours) as? Int ?? 24
        return ClassifierOptions(
            inactiveAfter: idleDays > 0 ? TimeInterval(idleDays) * 86_400 : nil,
            keepDoneFor: TimeInterval(keepDoneHours > 0 ? keepDoneHours : 24) * 3_600
        )
    }

    private static func seenState() -> SeenState {
        appDefaults?.data(forKey: SettingsKey.seen).flatMap { try? JSONDecoder().decode(SeenState.self, from: $0) }
            ?? SeenState.firstRun()
    }

    static func resolve(_ snapshot: PulseSnapshot, seen: SeenState, options: ClassifierOptions, now: Date = Date()) -> [PRSnapshot] {
        PROrdering.sorted(snapshot.records.compactMap {
            PRClassifier.snapshot(for: $0, seenCutoff: seen.cutoff(for: $0.id), now: now, options: options)
        })
    }

    private static func load(_ options: Options) -> Loaded {
        if options.demo {
            let now = Date()
            let snapshot = DemoData.snapshot(now: now)
            return Loaded(organizations: snapshot.organizations,
                          items: resolve(snapshot, seen: DemoData.seenState(now: now), options: ClassifierOptions(), now: now))
        }
        let client = ADOClient(tokens: AzureCLITokenProvider())
        var organizations = options.organizations
        if organizations.isEmpty {
            organizations = appDefaults?.stringArray(forKey: SettingsKey.organizations) ?? []
        }
        if organizations.isEmpty {
            FileHandle.standardError.write(Data("No organizations chosen in the app yet: looking for yours…\n".utf8))
            let found: Result<OrganizationDiscovery.Found, ADOError> = wait {
                do {
                    return .success(try await OrganizationDiscovery.discover(client: client))
                } catch {
                    return .failure((error as? ADOError) ?? .network(error.localizedDescription))
                }
            }
            switch found {
            case .success(let found): organizations = found.withPullRequests
            case .failure(let error):
                return Loaded(organizations: [], items: [], problem: "Couldn't find your organizations: \(error.description)")
            }
        }
        let configuration = PulseEngine.Configuration(organizations: organizations, keepDoneFor: classifierOptions().keepDoneFor)
        let snapshot = wait { await PulseEngine.loadOnce(client: client, configuration: configuration) }
        return Loaded(
            organizations: organizations, items: resolve(snapshot, seen: seenState(), options: classifierOptions()),
            problem: snapshot.problem?.message
        )
    }

    // MARK: Output

    private static func printTable(_ loaded: Loaded) {
        if let problem = loaded.problem { print("! \(problem)") }
        let now = Date()
        let counts = GroupCounts(loaded.items)
        print(PRGroup.allCases.map { "\($0.countLabel) \(counts[$0])" }.joined(separator: " · "))
        print(row("GROUP", "STATUS", "SINCE", "PULL REQUEST", "DETAIL"))
        for item in loaded.items {
            print(row(
                item.group.rawValue, item.headline, Elapsed.short(since: item.since, now: now),
                "!\(item.key.number) \(item.title) [\(item.repository)]", item.detail ?? ""
            ))
        }
    }

    private static func row(_ group: String, _ status: String, _ since: String, _ title: String, _ detail: String) -> String {
        [pad(group, 9), pad(status, 30), pad(since, 7), pad(title, 50), String(detail.prefix(70))].joined(separator: " ")
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        let clipped = text.count > width ? String(text.prefix(width - 1)) + "…" : text
        return clipped.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    private static func listOrganizations() -> Int32 {
        let client = ADOClient(tokens: AzureCLITokenProvider())
        let result: Result<([String], OrganizationDiscovery.Probe), ADOError> = wait {
            do {
                let all = try await OrganizationDiscovery.memberships(client: client)
                return .success((all, await OrganizationDiscovery.probe(all, client: client)))
            } catch {
                return .failure((error as? ADOError) ?? .network(error.localizedDescription))
            }
        }
        switch result {
        case .success(let (all, probe)):
            let watched = Set(appDefaults?.stringArray(forKey: SettingsKey.organizations) ?? [])
            print("\(all.count) organizations; \(probe.withPullRequests.count) with pull requests (*); watched by the app (+)")
            for name in all {
                let mark = probe.withPullRequests.contains(name) ? "*" : probe.failures[name] != nil ? "?" : " "
                print("\(mark)\(watched.contains(name) ? "+" : " ") \(name)")
            }
            if let failure = probe.failures.min(by: { $0.key < $1.key }) {
                FileHandle.standardError.write(Data("Couldn't check \(probe.failures.count) (?), such as \(failure.key): \(failure.value.description)\n".utf8))
                return 1
            }
            return 0
        case .failure(let error):
            FileHandle.standardError.write(Data("\(error.description)\n".utf8))
            return 1
        }
    }

    private static func listDemoOrganizations() -> Int32 {
        print("1 organization; 1 with pull requests (*); watched by the app (+)")
        print("*+ \(DemoData.organization)")
        return 0
    }

    /// The made-up pull requests, then the demo's one change a second later, as `--watch` prints them.
    private static func watchDemo() {
        setvbuf(stdout, nil, _IOLBF, 0)
        print("Watching \(DemoData.organization), made-up pull requests")
        let now = Date()
        let printer = WatchPrinter(seen: DemoData.seenState(now: now), options: ClassifierOptions())
        let snapshot = DemoData.snapshot(now: now)
        printer.print(snapshot)
        Thread.sleep(forTimeInterval: 1)
        printer.print(DemoData.update(snapshot, at: Date()))
        print("That's all the demo does.")
    }

    /// What `--watch` keeps running.
    nonisolated(unsafe) private static var watching: [Any] = []

    private static func startWatching(_ options: Options) {
        let organizations = options.organizations.isEmpty
            ? appDefaults?.stringArray(forKey: SettingsKey.organizations) ?? []
            : options.organizations
        let printer = WatchPrinter(seen: seenState(), options: classifierOptions())
        let queue = DispatchQueue(label: "BriefBar.AzureDevOps.watch")
        let engine = PulseEngine(
            client: ADOClient(tokens: AzureCLITokenProvider()), configuration: PulseEngine.Configuration(organizations: organizations)
        ) { snapshot in queue.async { printer.print(snapshot) } }
        setvbuf(stdout, nil, _IOLBF, 0)
        print("Watching \(organizations.joined(separator: ", ")), refreshing every minute — Ctrl-C to stop")
        Task { await engine.start() }
        watching = [engine, printer]
    }

    /// Runs async work from the synchronous command line.
    static func wait<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box<T>()
        Task.detached {
            box.value = await body()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T?
    }
}

/// Prints only the pull requests whose status changed. Confined to the watch queue.
private final class WatchPrinter: @unchecked Sendable {
    private let seen: SeenState
    private let options: ClassifierOptions
    private var problem: String?
    private var previous: [String: PRSnapshot] = [:]
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(seen: SeenState, options: ClassifierOptions) {
        self.seen = seen
        self.options = options
    }

    func print(_ snapshot: PulseSnapshot) {
        guard !snapshot.isRefreshing else { return }
        let now = Date()
        let message = snapshot.problem?.message
        if message != problem {
            problem = message
            if let message { Swift.print("\(formatter.string(from: now))  ! \(message)") }
        }
        for item in AzureDevOpsCommandLine.resolve(snapshot, seen: seen, options: options, now: now) {
            let old = previous[item.id]
            previous[item.id] = item
            guard old == nil || old?.group != item.group || old?.headline != item.headline || old?.detail != item.detail else { continue }
            if old == nil, item.group == .idle { continue }
            let detail = item.detail.map { " — \($0.prefix(90))" } ?? ""
            Swift.print("\(formatter.string(from: now))  \(item.group.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) "
                + "\(item.headline): !\(item.key.number) \(item.title)\(detail)")
        }
    }
}
