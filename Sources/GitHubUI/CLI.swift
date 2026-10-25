import BriefBarCore
import BriefBarUI
import Foundation
import GitHubCore

/// GitHub's command-line modes, mainly for checking what its list would show.
package enum GitHubCommandLine: SourceCommandLine {
    package static let source = SourceID.github
    package static var descriptionVersion: Int { GitHubSource.descriptionVersion }
    package static let usage = """
        GitHub:
          Reads github.com with the GitHub CLI's sign-in (gh auth login), read-only.
          Set \(GitHubCLILocator.overrideVariable) to the gh to use, when it isn't on your PATH.
        """

    private struct Loaded: Sendable {
        var load: GitHubLoad?
        var problem: GitHubProblem?

        var items: [GitHubPRSnapshot] { load?.items ?? [] }
        var counts: GitHubGroupCounts { load?.counts ?? GitHubGroupCounts() }
    }

    /// The made-up pull requests, or yours: one read, as the app makes each refresh.
    private static func load(_ options: CommandLineOptions) -> Loaded {
        if options.demo { return Loaded(load: GitHubDemoData.load()) }
        let client = GitHubClient(tokens: GitHubCLITokenProvider())
        return wait {
            do {
                return Loaded(load: try await GitHubReader.load(client: client))
            } catch {
                return Loaded(problem: GitHubProblem.from(error))
            }
        }
    }

    package static func dump(_ options: CommandLineOptions) -> Int32 {
        let loaded = load(options)
        printTable(loaded)
        return loaded.problem == nil ? 0 : 1
    }

    private struct Output: Encodable {
        var login: String?
        var pullRequests: [GitHubPRSnapshot]
        var counts: GitHubGroupCounts
        /// By section, the counts by state that a menu-bar item can add up across sources.
        var states: [String: StateCounts]
        var notice: String?
        var moreThanShown: Bool
        var problem: String?
    }

    package static func json(_ options: CommandLineOptions) -> [String: Any]? {
        let loaded = load(options)
        return jsonObject(Output(
            login: loaded.load?.login, pullRequests: loaded.items, counts: loaded.counts,
            states: [SectionID.githubPullRequests.rawValue: loaded.counts.states], notice: loaded.load?.notice,
            moreThanShown: loaded.load?.moreThanShown ?? false, problem: loaded.problem?.message
        ))
    }

    private static func printTable(_ loaded: Loaded) {
        if let problem = loaded.problem { print("! \(problem.message)") }
        if let notice = loaded.load?.notice { print("! \(notice)") }
        if let login = loaded.load?.login { print("Signed in to the GitHub CLI as \(login)") }
        let counts = loaded.counts
        print(GitHubPRGroup.allCases.map { "\($0.rawValue) \(counts[$0])" }.joined(separator: " · "))
        let now = Date()
        print(row("GROUP", "STATUS", "SINCE", "PULL REQUEST", "TITLE"))
        for item in loaded.items {
            print(row(
                item.group.rawValue, item.headline, Elapsed.short(since: item.since, now: now), item.pullRequest.reference,
                item.pullRequest.title
            ))
        }
        if loaded.load?.moreThanShown == true { print("… and more on GitHub") }
    }

    private static func row(_ group: String, _ status: String, _ since: String, _ reference: String, _ title: String) -> String {
        [pad(group, 17), pad(status, 32), pad(since, 7), pad(reference, 36), String(title.prefix(70))].joined(separator: " ")
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        let clipped = text.count > width ? String(text.prefix(width - 1)) + "…" : text
        return clipped.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    /// What `--watch` keeps running.
    nonisolated(unsafe) private static var watching: [Any] = []

    package static func watch(_ options: CommandLineOptions) -> Bool {
        setvbuf(stdout, nil, _IOLBF, 0)
        if options.demo {
            printTable(load(options))
            return false
        }
        let queue = DispatchQueue(label: "BriefBar.GitHub.watch")
        let printer = GitHubWatchPrinter(client: GitHubClient(tokens: GitHubCLITokenProvider()))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 60, leeway: .seconds(5))
        timer.setEventHandler { printer.poll() }
        timer.resume()
        print("Watching your GitHub pull requests every minute — Ctrl-C to stop")
        watching = [timer, printer]
        return true
    }
}

/// Prints only the pull requests whose group or status changed.
private final class GitHubWatchPrinter: @unchecked Sendable {
    private let client: GitHubClient
    private let lock = NSLock()
    private var isPolling = false
    private var problem: String?
    private var previous: [String: GitHubPRSnapshot] = [:]
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(client: GitHubClient) {
        self.client = client
    }

    func poll() {
        guard lock.withLock({ () -> Bool in
            if isPolling { return false }
            isPolling = true
            return true
        }) else { return }
        let client = client
        Task {
            let result: Result<GitHubLoad, Error>
            do {
                result = .success(try await GitHubReader.load(client: client))
            } catch {
                result = .failure(error)
            }
            self.report(result)
        }
    }

    private func report(_ result: Result<GitHubLoad, Error>) {
        lock.withLock {
            defer { isPolling = false }
            let now = formatter.string(from: Date())
            switch result {
            case .failure(let error):
                let message = GitHubProblem.from(error).message
                if message != problem { Swift.print("\(now)  ! \(message)") }
                problem = message
            case .success(let load):
                problem = nil
                var current: [String: GitHubPRSnapshot] = [:]
                for item in load.items {
                    current[item.id] = item
                    let old = previous[item.id]
                    guard old?.group != item.group || old?.headline != item.headline else { continue }
                    Swift.print("\(now)  \(item.group.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)) \(item.headline): \(item.pullRequest.reference) \(item.pullRequest.title.prefix(70))")
                }
                for (id, old) in previous where current[id] == nil {
                    Swift.print("\(now)  gone             \(old.pullRequest.reference) \(old.pullRequest.title.prefix(70))")
                }
                previous = current
            }
        }
    }
}
