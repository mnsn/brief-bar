import AzureDevOpsCore
import BriefBarCore
import Foundation

/// The builds you look into in a pull request's details, and what's read of them. A failed or running build opens under
/// its row there, and only then is its run read, through the investigator (`BuildInvestigator`), with a few GETs. It keeps
/// what it read for a while, and opening the run again asks it again, so what it keeps answers while it's fresh, and the
/// run is read anew once it isn't: what was read before shows meanwhile. A run whose check changed since, as when it
/// finished or runs again, is read anew, and one whose pull request has other commits, or another target branch, is asked
/// for again, which revises what's kept, or reads it for that branch: at once while it's open, or as it opens. Only the
/// pull request whose details show has builds open: showing another, or closing them, folds them and lets go of what was
/// read for them here.
@MainActor
final class BuildInvestigationStore: ObservableObject {
    /// What's read of a run, for its row.
    struct Look: Equatable {
        /// What was read last, which still shows while it's read again.
        var investigation: BuildInvestigation?
        var isReading = false
        /// Why it couldn't be read, the last time it was.
        var failure: ADOError?
        /// What it was read for last.
        var readFor: Stamp?
    }

    /// What a run is read for: its check, as the list reads it, which changes when the run finishes or runs again under the
    /// same ID; and its pull request's commits, merge and target branch, which say whether the run built its latest commit
    /// and what it's compared with.
    struct Stamp: Equatable {
        var state: Check.State?
        var completedAt: Date?
        var sourceCommit: String?
        var mergeCommit: String?
        var mergeStatus: String?
        var targetBranch: String

        init(check: Check?, pullRequest: PullRequest) {
            state = check?.state
            completedAt = check?.completedAt
            sourceCommit = pullRequest.sourceCommit
            mergeCommit = pullRequest.mergeCommit
            mergeStatus = pullRequest.mergeStatus
            targetBranch = pullRequest.targetBranch
        }

        /// Whether the run may have changed since it was read for `other`: it finished, or runs again. What the
        /// investigator keeps of it is from before, such as a run still going, which it keeps a while without a look.
        func runChanged(since other: Stamp?) -> Bool {
            guard let other else { return false }
            return state != other.state || completedAt != other.completedAt
        }
    }

    /// Reads one of a pull request's builds, or reads it anew rather than what's kept of it: through the investigator, or,
    /// in tests, as they say.
    typealias Reader = @Sendable (_ buildId: Int, _ pullRequest: PullRequest, _ again: Bool) async throws -> BuildInvestigation

    /// A read asked for while another of the same run is under way, which the investigator would share: it starts once
    /// that one is done.
    private struct Queued {
        var pullRequest: PullRequest
        var check: Check?
        var again: Bool
    }

    let mode: PRStore.Mode
    /// The pull request whose builds can be open; nil while no details show.
    @Published private(set) var pullRequest: PRKey?
    /// Its builds that are open, by run.
    @Published private(set) var expanded: Set<Int> = []
    /// What's read of them, by run.
    @Published private(set) var looks: [Int: Look] = [:]

    private let reader: Reader
    /// Forgets what the investigator keeps; and stops it for good.
    private let forgetKept: @Sendable () async -> Void
    private let stopReading: @Sendable () async -> Void
    private let now: () -> Date
    /// The reads under way, by run.
    private var reading: [Int: Task<Void, Never>] = [:]
    /// The reads to start once those under way are done, by run.
    private var queued: [Int: Queued] = [:]
    /// What reads are for: a read from before another pull request showed, or someone else signed in, is let go.
    private var generation = 0
    /// Who's signed in to the Azure CLI, which what's kept was read as, once known.
    private var account: String?
    /// Azure DevOps was turned off: nothing's read any more.
    private var isStopped = false

    /// - Parameter reader: how to read a build live; Azure DevOps, with `client`, through a `BuildInvestigator`, by default.
    init(mode: PRStore.Mode, client: ADOClient, now: @escaping () -> Date = Date.init, reader: Reader? = nil) {
        self.mode = mode
        self.now = now
        if let reader {
            self.reader = reader
            forgetKept = {}
            stopReading = {}
        } else {
            let investigator = BuildInvestigator(client: client)
            self.reader = { buildId, pullRequest, again in
                try await investigator.investigation(buildId: buildId, of: pullRequest, refresh: again)
            }
            forgetKept = { await investigator.forget() }
            stopReading = { await investigator.stop() }
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

    /// Opens a run under its row, and asks the investigator for it, which answers with what it keeps while that's fresh,
    /// and reads it otherwise; anew when its check changed since it was read. What was read before shows meanwhile.
    /// - Parameter check: the run's check, as the list has it now.
    func expand(_ buildId: Int, of pr: PullRequest, check: Check? = nil) {
        guard !isStopped else { return }
        show(pr.key)
        expanded.insert(buildId)
        read(buildId, of: pr, check: check, again: Stamp(check: check, pullRequest: pr).runChanged(since: looks[buildId]?.readFor))
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

    /// The list read a run's check, or its pull request, again: an open run read for something else is asked for again,
    /// anew when its check changed, as when it finished or runs again. One that's folded is as it opens.
    func changed(_ buildId: Int, of pr: PullRequest, check: Check?) {
        guard isExpanded(buildId, of: pr.key), let look = looks[buildId] else { return }
        let stamp = Stamp(check: check, pullRequest: pr)
        guard look.readFor != stamp else { return }
        read(buildId, of: pr, check: check, again: stamp.runChanged(since: look.readFor))
    }

    /// Asks the investigator for a run, while what was read of it before shows. While another read of it is under way,
    /// which the investigator would share, even to read it anew, one for something else waits for it, then reads.
    /// - Parameters:
    ///   - check: the run's check, as the list has it now: with the pull request, what it's read for.
    ///   - again: anew, rather than what the investigator keeps of it, as when you ask, or its check changed.
    func read(_ buildId: Int, of pr: PullRequest, check: Check? = nil, again: Bool = false) {
        guard !isStopped else { return }
        show(pr.key)
        let stamp = Stamp(check: check, pullRequest: pr)
        if reading[buildId] != nil {
            guard again || looks[buildId]?.readFor != stamp else { return }
            queued[buildId] = Queued(pullRequest: pr, check: check, again: again || queued[buildId]?.again == true)
            return
        }
        queued[buildId] = nil
        var look = looks[buildId] ?? Look()
        look.isReading = true
        look.readFor = stamp
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

    /// Stops for good, when Azure DevOps is turned off: what's read goes, the reads under way stop, and nothing is read any
    /// more.
    func stop() {
        isStopped = true
        letGo()
        pullRequest = nil
        account = nil
        Task { await stopReading() }
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
        queued = [:]
        generation += 1
        expanded = []
        looks = [:]
    }

    /// What a read found: it shows, or why it couldn't be read; then a read asked for meanwhile starts.
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
        if let next = queued.removeValue(forKey: buildId) {
            read(buildId, of: next.pullRequest, check: next.check, again: next.again)
        }
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
