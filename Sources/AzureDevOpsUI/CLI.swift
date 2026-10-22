import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Foundation
import NotificationCenterDB

/// Azure DevOps' command-line modes, mainly for checking what its list would show.
package enum AzureDevOpsCommandLine: SourceCommandLine {
    package static let source = SourceID.azureDevOps
    package static var descriptionVersion: Int { AzureDevOpsSource.descriptionVersion }
    package static let flags = ["--orgs", "--chats", "--sprint", "--teams", "--pipelines"]
    package static let usage = """
        Azure DevOps:
          --orgs             List your organizations, and the ones where you have pull requests
          --chats            List the pull request links in every app's notifications in Notification
                             Center: run it from Terminal, which needs Full Disk Access. Started as an
                             app, BriefBar refuses it
          --sprint           Print your team's current sprint: its stories and bugs, with their tasks
            --team <name>    …of this team instead of the app's choice
            --mine           …only your stories and tasks
          --teams            List your teams, and which have a sprint going on today
          --pipelines        Print the pipelines pinned in the app: their latest runs and stages
            --search <text> --project <name>   Find pipelines to pin in a project instead
              --status       …and show how the first five are doing
          --org <name>       Read this organization instead of the app's choice (repeatable)
          It signs in with the Azure CLI (az login) and only reads: every request is a GET. Set
          BRIEFBAR_AZ to the path of az to use another one. --dump, --json and --watch leave out pull
          requests sent in chats, which only the app keeps, in memory: --chats lists the links.
        """

    struct Options {
        var demo = false
        var organizations: [String] = []
        var team: String?
        var mine = false
        var search: String?
        var project: String?
        var status = false

        init(_ options: CommandLineOptions) {
            demo = options.demo
            let arguments = options.arguments
            mine = arguments.contains("--mine")
            status = arguments.contains("--status")
            var index = 0
            while index < arguments.count {
                let value = index + 1 < arguments.count ? arguments[index + 1] : nil
                switch (arguments[index], value) {
                case ("--org", let value?):
                    organizations.append(value)
                    index += 1
                case ("--team", let value?):
                    team = value
                    index += 1
                case ("--search", let value?):
                    search = value
                    index += 1
                case ("--project", let value?):
                    project = value
                    index += 1
                default:
                    break
                }
                index += 1
            }
        }
    }

    package static func run(_ options: CommandLineOptions) -> Int32? {
        // The demo never uses the Azure CLI, your settings, Azure DevOps or Notification Center.
        if options.arguments.contains("--orgs") {
            return options.demo ? listDemoOrganizations() : listOrganizations()
        }
        if options.arguments.contains("--chats") {
            return options.demo ? listDemoChatLinks() : listChatLinks()
        }
        let work = Options(options)
        if options.arguments.contains("--sprint") {
            return WorkCLI.sprint(work)
        }
        if options.arguments.contains("--teams") {
            return WorkCLI.teams(work)
        }
        if options.arguments.contains("--pipelines") {
            return work.search != nil ? WorkCLI.searchPipelines(work) : WorkCLI.pipelines(work)
        }
        return nil
    }

    package static func dump(_ options: CommandLineOptions) -> Int32 {
        let loaded = load(Options(options))
        printTable(loaded)
        return loaded.items.isEmpty && loaded.problem != nil ? 1 : 0
    }

    private struct Output: Encodable {
        var organizations: [String]
        var counts: GroupCounts
        /// By section, the counts by state that a menu-bar item can add up across sources.
        var states: [String: StateCounts]
        var items: [PRSnapshot]
        var problem: String?
    }

    package static func json(_ options: CommandLineOptions) -> [String: Any]? {
        let loaded = load(Options(options))
        let counts = GroupCounts(loaded.items)
        // To Review needs you only while the app shows it in the menu bar. The demo never reads your settings.
        let showToReview = !options.demo && appDefaults?.bool(forKey: SettingsKey.showToReview) == true
        return jsonObject(Output(
            organizations: loaded.organizations, counts: counts,
            states: [SectionID.azureDevOpsPullRequests.rawValue: counts.states(showToReview: showToReview)],
            items: loaded.items, problem: loaded.problem
        ))
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
    static var appDefaults: UserDefaults? { AppSettings.appDefaults }

    /// The organizations to read: `--org`, or the app's.
    static func organizations(_ options: Options) -> [String] {
        options.organizations.isEmpty ? appDefaults?.stringArray(forKey: SettingsKey.organizations) ?? [] : options.organizations
    }

    private static func classifierOptions() -> ClassifierOptions {
        let defaults = appDefaults
        let idleDays = defaults?.object(forKey: SettingsKey.idleDays) as? Int ?? 14
        let keepDoneHours = defaults?.object(forKey: SettingsKey.keepDoneHours) as? Int ?? 24
        return ClassifierOptions(
            inactiveAfter: idleDays > 0 ? TimeInterval(idleDays) * 86_400 : nil,
            keepDoneFor: TimeInterval(keepDoneHours > 0 ? keepDoneHours : 24) * 3_600
        )
    }

    /// What the app's accounts have seen.
    private static func seenBook() -> SeenBook {
        let decoder = JSONDecoder()
        return SeenBook(
            current: appDefaults?.data(forKey: SettingsKey.seen).flatMap { try? decoder.decode(SeenState.self, from: $0) }
                ?? SeenState.firstRun(),
            others: appDefaults?.data(forKey: SettingsKey.otherSeen).flatMap { try? decoder.decode([String: SeenState].self, from: $0) }
                ?? [:]
        )
    }

    /// Without pull requests sent in chats: only the app finds those, and keeps them in memory.
    static func resolve(_ snapshot: PulseSnapshot, seen: SeenState, options: ClassifierOptions, now: Date = Date()) -> [PRSnapshot] {
        PROrdering.sorted(snapshot.records.compactMap { record in
            PRClassifier.snapshot(for: record, seenCutoff: seen.cutoff(for: record.id), now: now, options: options)
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
            organizations: organizations,
            items: resolve(snapshot, seen: seenBook().state(for: snapshot.account), options: classifierOptions()),
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

    static func pad(_ text: String, _ width: Int) -> String {
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

    /// What `--chats` finds: every pull request link in the stored notifications, with who sent it where.
    private static func listChatLinks() -> Int32 {
        let database = ChatLinkDatabase.url()
        switch DatabaseAccess.check(database) {
        case .denied:
            FileHandle.standardError.write(Data("""
                Can't read Notification Center's database: give Terminal Full Disk Access in System Settings › \
                Privacy & Security › Full Disk Access, then quit and reopen Terminal and run this again.

                """.utf8))
            return 1
        case .missing:
            FileHandle.standardError.write(Data("There's no Notification Center database at \(database.path).\n".utf8))
            return 1
        case .granted:
            break
        }
        let records: [StoredRecord]
        do {
            records = try NotificationDatabase.loadEveryApp(at: database).records
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            return 1
        }
        let links = ChatLinkScanner.scan(records)
        let apps = Set(records.map(\.bundleIdentifier)).count
        print("\(records.count) notifications from \(apps) apps; \(links.count) links to pull requests")
        printChatLinks(links)
        return 0
    }

    /// The made-up links in the demo, without reading Notification Center.
    private static func listDemoChatLinks() -> Int32 {
        let links = DemoData.records(now: Date()).flatMap(\.chatLinks)
        print("Made-up notifications; \(links.count) links to pull requests")
        printChatLinks(links)
        return 0
    }

    private static func printChatLinks(_ links: [ChatLink]) {
        let now = Date()
        for link in links.sorted(by: { $0.sentAt > $1.sentAt }) {
            print([pad(Elapsed.short(since: link.sentAt, now: now), 7), pad(link.appName, 10), pad(link.sender ?? "", 28),
                   "\(link.key)  \(link.messageURL == nil ? "" : "(message link)")"].joined(separator: " "))
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
        let printer = WatchPrinter(seen: SeenBook(current: DemoData.seenState(now: now)), options: ClassifierOptions())
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
        let printer = WatchPrinter(seen: seenBook(), options: classifierOptions())
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
    private var seen: SeenBook
    private let options: ClassifierOptions
    private var problem: String?
    private var previous: [String: PRSnapshot] = [:]
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(seen: SeenBook, options: ClassifierOptions) {
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
        // Once, so an account's first run starts when it was first seen.
        if let account = snapshot.account { seen.signIn(account, now: now) }
        for item in AzureDevOpsCommandLine.resolve(snapshot, seen: seen.current, options: options, now: now) {
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
