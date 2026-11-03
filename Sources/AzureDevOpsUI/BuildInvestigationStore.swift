import AzureDevOpsCore
import BriefBarCore
import Foundation

/// The builds you look into in a pull request's details, and what's read of them. A failed or running build opens under
/// its row there, and only then is its run read, through the investigator (`BuildInvestigator`), with a few GETs. It keeps
/// what it read for a while, and opening the run again asks it again, so what it keeps answers while it's fresh, and the
/// run is read anew once it isn't: what was read before shows meanwhile. A run whose check changed since, as when it
/// finished or runs again, is read anew, and one whose pull request has other commits, or another target branch, is asked
/// for again, which revises what's kept, or reads it for that branch: at once while it's open, or as it opens. Only one
/// pull request's builds are open at a time, wherever its details show, beside the list or as a page: opening one of
/// another's folds them, and so does the details beside the list showing another pull request, or closing, for the one
/// they showed; what was read for them here goes. What's read of the builds that fold stays for the last few
/// (`foldedKept`), and a run its checks don't list any more, such as one a newer run replaced, goes.
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

        /// Its check says the run finished: it passed, failed, or passed and expired since.
        var finished: Bool {
            switch state {
            case .passed?, .failed?, .expired?: true
            case .running?, .queued?, .notRun?, .pending?, .notApplicable?, nil: false
            }
        }
    }

    /// Reads one of a pull request's builds: anew rather than what's kept of it (`again`), and knowing whether its check
    /// says it finished (`finished`), which what was kept while it was still going isn't. Through the investigator, or, in
    /// tests, as they say.
    typealias Reader = @Sendable (_ buildId: Int, _ pullRequest: PullRequest, _ again: Bool, _ finished: Bool) async throws
        -> BuildInvestigation

    /// A read asked for while another of the same run is under way, which the investigator would share: it starts once
    /// that one is done.
    private struct Queued {
        var pullRequest: PullRequest
        var check: Check?
        var again: Bool
    }

    /// A read under way: only the latest of a run answers.
    private struct Reading {
        var id = UUID()
        var task: Task<Void, Never>
    }

    /// How many folded builds keep what's read of them, to show at once as they open again.
    static let foldedKept = 5

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
    private var reading: [Int: Reading] = [:]
    /// The reads to start once those under way are done, by run.
    private var queued: [Int: Queued] = [:]
    /// The builds that folded, the latest last.
    private var folded: [Int] = []
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
            self.reader = { buildId, pullRequest, again, finished in
                try await investigator.investigation(buildId: buildId, of: pullRequest, refresh: again, finished: finished)
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
        folded.removeAll { $0 == buildId }
        read(buildId, of: pr, check: check, again: Stamp(check: check, pullRequest: pr).runChanged(since: looks[buildId]?.readFor))
    }

    /// Folds a run: what's read of it stays, for the last few that folded.
    func collapse(_ buildId: Int, of key: PRKey) {
        guard pullRequest == key, expanded.remove(buildId) != nil else { return }
        folded.removeAll { $0 == buildId }
        folded.append(buildId)
        prune()
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
        // As it was read, or is being read: nothing more to read, unless a read was asked for since, for something else.
        guard look.readFor != stamp || queued[buildId] != nil else { return }
        read(buildId, of: pr, check: check, again: stamp.runChanged(since: look.readFor))
    }

    /// The runs a pull request's builds and checks list now: the others, such as a run a newer one replaced, fold and go,
    /// with what's read of them, and their reads stop.
    func retain(_ listed: Set<Int>, of key: PRKey) {
        guard pullRequest == key else { return }
        let gone = Set(looks.keys).union(expanded).union(reading.keys).subtracting(listed)
        guard !gone.isEmpty else { return }
        for id in gone {
            reading.removeValue(forKey: id)?.task.cancel()
            queued[id] = nil
            looks[id] = nil
        }
        expanded.subtract(gone)
        folded.removeAll { gone.contains($0) }
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
            if !again, looks[buildId]?.readFor == stamp {
                // What's being read is what it's asked for now, as when its pull request is retargeted and back: a read
                // asked for since, for something else, isn't needed any more, but one asked for anew still is, for this.
                queued[buildId] = queued[buildId]?.again == true ? Queued(pullRequest: pr, check: check, again: true) : nil
            } else {
                queued[buildId] = Queued(pullRequest: pr, check: check, again: again || queued[buildId]?.again == true)
            }
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
            finish(buildId, read: nil, generation: generation, read.map { .success($0) } ?? .failure(.notFound))
        case .live:
            let reader = reader
            let id = UUID()
            let finished = stamp.finished
            reading[buildId] = Reading(id: id, task: Task { [weak self] in
                let result: Result<BuildInvestigation, ADOError>
                do {
                    result = .success(try await reader(buildId, pr, again, finished))
                } catch let error as ADOError {
                    result = .failure(error)
                } catch {
                    result = .failure(.network(error.localizedDescription))
                }
                self?.finish(buildId, read: id, generation: generation, result)
            })
        }
    }

    /// The details show a pull request, or none: another's builds fold, and what was read of them, or is being read, goes.
    func show(_ key: PRKey?) {
        guard key != pullRequest else { return }
        letGo()
        pullRequest = key
    }

    /// Details stopped showing a pull request, as when they show another or close: its builds fold, and what was read of
    /// them goes, unless another's opened since.
    func close(_ key: PRKey) {
        guard pullRequest == key else { return }
        show(nil)
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
        await reading[buildId]?.task.value
    }

    /// Folds every run and lets go of what was read here; reads under way don't answer.
    private func letGo() {
        for current in reading.values { current.task.cancel() }
        reading = [:]
        queued = [:]
        generation += 1
        expanded = []
        folded = []
        looks = [:]
    }

    /// Lets go of what's read of the builds that folded, but for the last `foldedKept`, and those being read.
    private func prune() {
        var excess = folded.count - Self.foldedKept
        guard excess > 0 else { return }
        var dropped: Set<Int> = []
        for id in folded where excess > 0 && reading[id] == nil {
            dropped.insert(id)
            excess -= 1
        }
        folded.removeAll { dropped.contains($0) }
        for id in dropped { looks[id] = nil }
    }

    /// What a read found, unless another was asked for since, or what it was for went: it shows, or why it couldn't be
    /// read; then a read asked for meanwhile starts.
    /// - Parameter id: the read's, for one under way; nil for one done at once, the demo's.
    private func finish(_ buildId: Int, read id: UUID?, generation: Int, _ result: Result<BuildInvestigation, ADOError>) {
        guard generation == self.generation, id == nil || reading[buildId]?.id == id else { return }
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
        } else {
            prune()
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
