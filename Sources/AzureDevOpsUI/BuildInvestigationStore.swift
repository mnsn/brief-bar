import AzureDevOpsCore
import BriefBarCore
import Foundation

/// The builds you look into in a pull request's details, and what's read of them. A failed or running build opens under
/// its row there, and only then is its run read (`BuildInvestigator`), with a few GETs; the investigator keeps what it read
/// for a while, so opening it again reads little. A run whose check changed since, as when it finished or runs again, is
/// read again as it opens, or at once while it's open. Only the pull request whose details show has builds open: showing
/// another, or closing them, folds them and lets go of what was read for them here.
@MainActor
final class BuildInvestigationStore: ObservableObject {
    /// What's read of a run, for its row.
    struct Look: Equatable {
        /// What was read last, which still shows while it's read again.
        var investigation: BuildInvestigation?
        var isReading = false
        /// Why it couldn't be read, the last time it was.
        var failure: ADOError?
        /// Its check, as the list had it when it was read last.
        var readFor: Stamp?
    }

    /// A run's check as the list reads it, which changes when the run finishes, or runs again under the same ID.
    struct Stamp: Equatable {
        var state: Check.State
        var completedAt: Date?

        init(_ check: Check) {
            state = check.state
            completedAt = check.completedAt
        }
    }

    /// Reads one of a pull request's builds, or reads it again rather than what's kept of it: through the investigator, or,
    /// in tests, as they say.
    typealias Reader = @Sendable (_ buildId: Int, _ pullRequest: PullRequest, _ again: Bool) async throws -> BuildInvestigation

    let mode: PRStore.Mode
    /// The pull request whose builds can be open; nil while no details show.
    @Published private(set) var pullRequest: PRKey?
    /// Its builds that are open, by run.
    @Published private(set) var expanded: Set<Int> = []
    /// What's read of them, by run.
    @Published private(set) var looks: [Int: Look] = [:]

    private let reader: Reader
    /// Forgets what the investigator keeps.
    private let forgetKept: @Sendable () async -> Void
    private let now: () -> Date
    /// The reads under way, by run.
    private var reading: [Int: Task<Void, Never>] = [:]
    /// What reads are for: a read from before another pull request showed, or someone else signed in, is let go.
    private var generation = 0
    /// Who's signed in to the Azure CLI, which what's kept was read as, once known.
    private var account: String?

    /// - Parameter reader: how to read a build live; Azure DevOps, with `client`, through a `BuildInvestigator`, by default.
    init(mode: PRStore.Mode, client: ADOClient, now: @escaping () -> Date = Date.init, reader: Reader? = nil) {
        self.mode = mode
        self.now = now
        if let reader {
            self.reader = reader
            forgetKept = {}
        } else {
            let investigator = BuildInvestigator(client: client)
            self.reader = { buildId, pullRequest, again in
                try await investigator.investigation(buildId: buildId, of: pullRequest, refresh: again)
            }
            forgetKept = { await investigator.forget() }
        }
    }

    /// Whether a run is open in a pull request's details.
    func isExpanded(_ buildId: Int, of key: PRKey) -> Bool {
        pullRequest == key && expanded.contains(buildId)
    }

    /// What's read of a run of a pull request's, while its details show.
    func look(_ buildId: Int, of key: PRKey) -> Look? {
        pullRequest == key ? looks[buildId] : nil
    }

    /// Opens a run under its row, and reads it, unless it's read already, or being read, for its check as it is now.
    /// - Parameter check: the run's check, as the list has it now.
    func expand(_ buildId: Int, of pr: PullRequest, check: Check? = nil) {
        show(pr.key)
        expanded.insert(buildId)
        let stamp = check.map(Stamp.init)
        guard let look = looks[buildId] else {
            read(buildId, of: pr, check: check)
            return
        }
        if look.readFor != stamp {
            // It finished, or runs again, since: what's kept of it is from before.
            read(buildId, of: pr, check: check, again: true)
        } else if look.investigation == nil, reading[buildId] == nil {
            read(buildId, of: pr, check: check)
        }
    }

    func collapse(_ buildId: Int, of key: PRKey) {
        guard pullRequest == key else { return }
        expanded.remove(buildId)
    }

    func toggle(_ buildId: Int, of pr: PullRequest, check: Check? = nil) {
        if isExpanded(buildId, of: pr.key) {
            collapse(buildId, of: pr.key)
        } else {
            expand(buildId, of: pr, check: check)
        }
    }

    /// The list read a run's check again: an open run whose check changed since it was read, as when it finished or runs
    /// again, is read again. One that's folded is read again as it opens.
    func checkChanged(_ buildId: Int, of pr: PullRequest, check: Check?) {
        guard isExpanded(buildId, of: pr.key), let look = looks[buildId], look.readFor != check.map(Stamp.init) else { return }
        read(buildId, of: pr, check: check, again: true)
    }

    /// Reads a run, while what was read of it before shows.
    /// - Parameters:
    ///   - check: the run's check, as the list has it now: what it's read for.
    ///   - again: rather than what the investigator keeps of it, as when you ask, or its check changed.
    func read(_ buildId: Int, of pr: PullRequest, check: Check? = nil, again: Bool = false) {
        show(pr.key)
        reading[buildId]?.cancel()
        reading[buildId] = nil
        var look = looks[buildId] ?? Look()
        look.isReading = true
        look.readFor = check.map(Stamp.init)
        looks[buildId] = look
        let generation = generation
        switch mode {
        case .demo:
            let read = DemoData.investigation(buildId: buildId, of: pr, now: now())
            finish(buildId, generation: generation, read.map { .success($0) } ?? .failure(.notFound))
        case .live:
            let reader = reader
            reading[buildId] = Task { [weak self] in
                let result: Result<BuildInvestigation, ADOError>
                do {
                    result = .success(try await reader(buildId, pr, again))
                } catch let error as ADOError {
                    result = .failure(error)
                } catch {
                    result = .failure(.network(error.localizedDescription))
                }
                // Asked for again meanwhile: that read answers.
                guard !Task.isCancelled else { return }
                self?.finish(buildId, generation: generation, result)
            }
        }
    }

    /// The details show a pull request, or none: another's builds fold, and what was read of them, or is being read, goes.
    func show(_ key: PRKey?) {
        guard key != pullRequest else { return }
        letGo()
        pullRequest = key
    }

    /// Someone signed in to the Azure CLI, as the pull requests' refresh tells. When it's someone else than before, nothing
    /// read as the last one stays.
    func accountChanged(_ account: String?) {
        guard let account else { return }
        defer { self.account = account }
        guard let known = self.account, known != account else { return }
        letGo()
        Task { await forgetKept() }
        Log.app.info("Signed in to the Azure CLI as another account: forgot the builds looked into")
    }

    /// Stops for good, when Azure DevOps is turned off, and forgets what it read.
    func stop() {
        letGo()
        pullRequest = nil
        account = nil
        Task { await forgetKept() }
    }

    /// For `--render`: opens a run and waits until it's read.
    func expandAndWait(_ buildId: Int, of pr: PullRequest, check: Check?) async {
        expand(buildId, of: pr, check: check)
        await reading[buildId]?.value
    }

    /// Folds every run and lets go of what was read here; reads under way don't answer.
    private func letGo() {
        for task in reading.values { task.cancel() }
        reading = [:]
        generation += 1
        expanded = []
        looks = [:]
    }

    private func finish(_ buildId: Int, generation: Int, _ result: Result<BuildInvestigation, ADOError>) {
        guard generation == self.generation else { return }
        reading[buildId] = nil
        var look = looks[buildId] ?? Look()
        look.isReading = false
        switch result {
        case .success(let investigation):
            look.investigation = investigation
            look.failure = nil
        case .failure(let error):
            // What was read before stays, with why it couldn't be read again.
            look.failure = error
            Log.app.error("Couldn't read a build: \(error.description, privacy: .public)")
        }
        looks[buildId] = look
    }

    // MARK: Saying what went wrong

    /// What to say when a run can't be read, but for signing in, which shows its own way.
    nonisolated static func message(for error: ADOError) -> String {
        switch error {
        case .notFound: return "Azure DevOps can't find this run. It may have been deleted, or moved where you can't see it."
        case .forbidden: return "You don't have access to this run."
        case .otherDirectory(let organization, _): return "\(organization) is in a directory your Azure CLI isn't signed in to."
        case .offline: return "You're offline."
        case .throttled: return "Azure DevOps asked BriefBar to slow down. Try again in a minute."
        default: return error.description
        }
    }
}
