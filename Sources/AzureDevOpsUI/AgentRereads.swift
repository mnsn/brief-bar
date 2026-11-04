import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Combine
import Foundation

/// Reads again, sooner than its next refresh, what Copilot sessions say they just changed in Azure DevOps
/// (`changed_in_azure_devops`), with Updates from Copilot Sessions on: only what BriefBar reads anyway, in the organizations
/// it reads. Your pull requests' lists, with the named ones' details, and their tags that the lists don't carry, as their
/// details show (`TagChanges.changedElsewhere`); with Show Links on, their work items and the sprint's pull requests; the
/// sprint, while something shows it; and the work item whose details show. What comes within `gathering` is one pass, and
/// passes are `spacing` apart at least, so that agents can't make BriefBar read Azure DevOps more often than opening its
/// panel again and again does (`PRStore.refreshIfStale`); and the engines' own caps hold (`PulseEngine.reread`,
/// `LinkEngine.reread`). Turning Updates from Copilot Sessions off or on forgets what waits for its pass, as it forgets
/// what sessions asked before (`SessionUpdates.setOn`).
@MainActor
final class AgentRereads {
    /// How long a pass waits for more after the first request, so that a burst of calls is one pass.
    static let gathering: TimeInterval = 3
    /// The least time between two passes.
    static let spacing: TimeInterval = 30

    /// What a pass reads again.
    struct Pass: Equatable {
        var pullRequests: Set<PRKey> = []
        var workItems: Set<WorkItemKey> = []

        var isEmpty: Bool { pullRequests.isEmpty && workItems.isEmpty }
    }

    private let updates: SessionUpdates
    private let organizations: () -> [String]
    private let read: (Pass) -> Void
    private let now: () -> Date
    private let gathering: TimeInterval
    private let spacing: TimeInterval
    private var pending = Pass()
    private var lastPass: Date?
    private var scheduled: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []

    /// - Parameters:
    ///   - organizations: the organizations BriefBar reads now.
    ///   - read: reads a pass's things again.
    init(
        updates: SessionUpdates, organizations: @escaping () -> [String], gathering: TimeInterval = AgentRereads.gathering,
        spacing: TimeInterval = AgentRereads.spacing, now: @escaping () -> Date = { Date() }, read: @escaping (Pass) -> Void
    ) {
        self.updates = updates
        self.organizations = organizations
        self.gathering = gathering
        self.spacing = spacing
        self.now = now
        self.read = read
    }

    /// With the source's stores, which it reads with. The organizations BriefBar reads are those you chose, those of the
    /// pull requests its lists have, which include the ones you watch and those sent to you from elsewhere, and the
    /// sprint's team's.
    convenience init(
        updates: SessionUpdates, store: PRStore, sprint: SprintStore?, workLinks: WorkLinksStore?, details: WorkItemDetailsStore?,
        tags: TagChanges?
    ) {
        let organizations = { [weak store, weak sprint] () -> [String] in
            guard let store else { return [] }
            return store.organizations + store.items.map(\.key.organization) + [sprint?.board?.team.organization].compactMap { $0 }
        }
        self.init(updates: updates, organizations: organizations) {
            [weak store, weak sprint, weak workLinks, weak details, weak tags] pass in
            store?.reread(pass.pullRequests)
            tags?.changedElsewhere(pass.pullRequests)
            if !pass.workItems.isEmpty { sprint?.refresh() }
            workLinks?.reread(pullRequests: pass.pullRequests, workItems: pass.workItems)
            details?.reloadIfShowing(pass.workItems)
        }
    }

    /// Hears what agents ask to read again, until it stops; and as Updates from Copilot Sessions goes off or on, forgets
    /// what waits for its pass.
    func started() -> Self {
        updates.rereads.sink { [weak self] refs in
            MainActor.assumeIsolated { self?.receive(refs) }
        }
        .store(in: &subscriptions)
        updates.$isOn.removeDuplicates().dropFirst().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.forgetWhatWaits() }
        }
        .store(in: &subscriptions)
        return self
    }

    func stop() {
        subscriptions = []
        forgetWhatWaits()
    }

    /// Calls off the pass that waits, and forgets what it would have read.
    private func forgetWhatWaits() {
        scheduled?.cancel()
        scheduled = nil
        pending = Pass()
    }

    /// What agents asked to read again: Azure DevOps' things in the organizations BriefBar reads, for the next pass.
    func receive(_ refs: [ItemRef]) {
        guard updates.isOn else { return }
        let organizations = Set(organizations().map { $0.lowercased() })
        for ref in refs where organizations.contains(ref.scope) {
            guard let number = ref.number else { continue }
            switch ref.kind {
            case .pullRequest: pending.pullRequests.insert(PRKey(ref.scope, number))
            case .workItem: pending.workItems.insert(WorkItemKey(ref.scope, number))
            case .gitHubPullRequest, .session: break
            }
        }
        guard !pending.isEmpty, scheduled == nil else { return }
        let delay = delay(at: now())
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.pass()
        }
    }

    /// How long the next pass waits from `date`: `gathering`, and until `spacing` after the last.
    func delay(at date: Date) -> TimeInterval {
        let earliest = lastPass.map { $0.addingTimeInterval(spacing) } ?? .distantPast
        return max(gathering, earliest.timeIntervalSince(date))
    }

    /// Reads what's pending again, unless Updates from Copilot Sessions was turned off meanwhile.
    func pass() {
        scheduled?.cancel()
        scheduled = nil
        let pass = pending
        pending = Pass()
        guard updates.isOn, !pass.isEmpty else { return }
        lastPass = now()
        read(pass)
    }
}
