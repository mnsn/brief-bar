import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Combine
import CopilotTasks
import Foundation

/// Tells Pull Request Order what Azure DevOps shows, while it's on: the pull requests the list read, the ones Done keeps a
/// day included, merged or abandoned, for what BriefBar sees become of them; with their branches, repositories and
/// authors, what each means for you now, and how each looks and opens, as its row does; and what each one's stage is worked
/// out from (`stageFacts`), with the Copilot tasks BriefBar sent on it and the account it was read with, whose stages you
/// set apply. It reads nothing more from Azure DevOps for it. As the list doesn't read which branches are forks' or which
/// is a repository's default, a pull request that targets another's branch goes after it only when the same person opened
/// both.
@MainActor
final class PullRequestOrderFacts {
    private let order: PullRequestOrder
    private let store: PRStore
    private let settings: AppSettings
    /// Where a pull request shows in its details, on the window's Pull Requests page.
    private weak var details: PullRequestDetailsStore?
    /// The tasks BriefBar sent to Copilot, whose sessions on a pull request its stage follows.
    private weak var copilot: CopilotTasksStore?
    private var cancellables: Set<AnyCancellable> = []
    /// Whether the demo's stages were told since Pull Request Order turned on.
    private var toldDemoStages = false

    init(
        order: PullRequestOrder, store: PRStore, settings: AppSettings, details: PullRequestDetailsStore?,
        copilot: CopilotTasksStore? = nil
    ) {
        self.order = order
        self.store = store
        self.settings = settings
        self.details = details
        self.copilot = copilot
    }

    /// Starts telling, for the source to keep it.
    func started() -> PullRequestOrderFacts {
        start()
        return self
    }

    func start() {
        guard cancellables.isEmpty else { return }
        // After the change: a @Published value emits before it's set.
        order.$isOn.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in MainActor.assumeIsolated { self?.turned(on: on) } }
            .store(in: &cancellables)
        // Every refresh too: a pull request's branches can change without its row, such as when it's retargeted; and as the
        // tasks sent to Copilot go, which stages follow.
        let tasks = copilot.map { $0.objectWillChange.map { _ in () }.eraseToAnyPublisher() } ?? Empty().eraseToAnyPublisher()
        store.$items.map { _ in () }
            .merge(with: store.refreshed)
            .merge(with: settings.$showToReview.removeDuplicates().map { _ in () })
            // Watching one keeps the stage you set on it, rather than only in memory.
            .merge(with: settings.$watchedPullRequests.dropFirst().map { _ in () })
            .merge(with: tasks)
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.publish() } }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        order.withdraw(.azureDevOps)
    }

    private func turned(on: Bool) {
        if on {
            toldDemoStages = false
            tellDemo()
        }
        publish()
    }

    /// For `--render`: the demo's orders, and what the list read, once.
    func loadOnce() -> PullRequestOrderFacts {
        tellDemo()
        publish()
        return self
    }

    /// The demo's orders, as if its sessions had told them.
    /// The demo's stages, as if you'd set them, once its pull requests are listed, which they're set on.
    private func tellDemoStages() {
        guard store.mode == .demo, !toldDemoStages, !store.records.isEmpty else { return }
        toldDemoStages = true
        order.tellDemo(stages: DemoPullRequestOrder.stages(now: store.now))
    }

    private func tellDemo() {
        guard store.mode == .demo else { return }
        let now = store.now
        order.tellDemo(
            DemoPullRequestOrder.orders(now: now), evidence: DemoPullRequestOrder.evidence(now: now), focus: DemoPullRequestOrder.focus
        )
    }

    /// Tells what the list shows now, or, while Pull Request Order is off, nothing.
    func publish() {
        guard order.isOn else {
            order.withdraw(.azureDevOps)
            return
        }
        let showToReview = settings.showToReview
        let tasks = copilot.flatMap { $0.isOn ? $0.entries : nil } ?? []
        order.publish(
            .azureDevOps, pullRequests: Self.pullRequests(store.records, items: store.items, showToReview: showToReview),
            items: store.items.map { describe($0, showToReview: showToReview) },
            stages: Self.stages(store.records, items: store.items, tasks: tasks, watched: settings.watchedKeys),
            account: settings.account
        )
        tellDemoStages()
    }

    // MARK: What an order sees

    /// Every pull request the list read, as an order sees it, with what it means for you now, as its group counts it.
    static func pullRequests(_ records: [PRRecord], items: [PRSnapshot], showToReview: Bool) -> [OrderPullRequest] {
        let groups = Dictionary(items.map { ($0.key, $0.group) }, uniquingKeysWith: { first, _ in first })
        return records.compactMap { record in
            pullRequest(record.pullRequest, attention: groups[record.id]?.state(showToReview: showToReview))
        }
    }

    /// A pull request as an order sees it: in its repository, by its organization, project and repository IDs; nil for one
    /// in a state BriefBar doesn't know.
    static func pullRequest(_ pullRequest: PullRequest, attention: ItemState?) -> OrderPullRequest? {
        let state: PullRequestState
        switch pullRequest.status {
        case .active: state = pullRequest.isDraft ? .draft : .open
        case .completed: state = .merged
        case .abandoned: state = .closed
        case .other: return nil
        }
        let key = pullRequest.key
        return OrderPullRequest(
            ref: key.linkRef, repository: "\(key.organization)/\(pullRequest.projectId)/\(pullRequest.repositoryId)",
            sourceBranch: pullRequest.sourceBranch, targetBranch: pullRequest.targetBranch, author: pullRequest.author.id,
            state: state, attention: attention, createdAt: pullRequest.createdAt
        )
    }

    // MARK: What a stage is worked out from

    /// Each pull request's stage's facts, from what the list read of it, its row, and the tasks sent to Copilot on it, or
    /// that opened it, newest first.
    /// - Parameter watched: the pull requests you watch, which BriefBar keeps what you set on, as it keeps what you've seen
    ///   of them, while it keeps that of those only sent to you in a chat in memory.
    static func stages(
        _ records: [PRRecord], items: [PRSnapshot], tasks: [CopilotTaskEntry], watched: Set<PRKey> = []
    ) -> [ItemRef: StageFacts] {
        let rows = Dictionary(items.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var facts: [ItemRef: StageFacts] = [:]
        for record in records {
            let on = tasks.filter { $0.pullRequestKey == record.id }
            guard var fact = stageFacts(record, item: rows[record.id], tasks: on) else { continue }
            if fact.role == .sentToYou, watched.contains(record.id) { fact.role = .watching }
            facts[record.id.linkRef] = fact
        }
        return facts
    }

    /// What a pull request's stage is worked out from (`StageRules`), as Azure DevOps' lists read it: whose it is, where it
    /// stands, what's left before you can complete yours, as What's Left says it, and the votes on it, never who cast them;
    /// nil for one in a state BriefBar doesn't know.
    /// - Parameter tasks: the tasks sent to Copilot on it, or that opened it, newest first.
    static func stageFacts(_ record: PRRecord, item: PRSnapshot?, tasks: [CopilotTaskEntry]) -> StageFacts? {
        let pr = record.pullRequest
        let state: PullRequestState
        switch pr.status {
        case .active: state = pr.isDraft ? .draft : .open
        case .completed: state = .merged
        case .abandoned: state = .closed
        case .other: return nil
        }
        let me = record.me.lowercased()
        let others = pr.reviewers.filter { $0.person.id != me }
        let role: StageFacts.Role = switch record.role {
        case .author: .author
        case .reviewer: .reviewer
        case .linked: .sentToYou
        }
        var facts = StageFacts(
            role: role, state: state, autoComplete: pr.autoComplete, othersVoted: others.contains { $0.vote != .none },
            votes: StageFacts.digest(votes: others.map(\.vote.rawValue)), commit: pr.sourceCommit,
            sessions: tasks.prefix(3).compactMap(session),
            since: state.isOpen ? item?.since ?? pr.createdAt : pr.closedAt ?? item?.since
        )
        let sentInChat = item.flatMap { item in
            item.pendingEvents.contains { $0.kind == .sentInChat } ? item.chatSource.map(sent) : nil
        }
        switch record.role {
        case .author:
            let readiness = item?.readiness ?? PRReadiness(record)
            let left = readiness?.items ?? []
            facts.failure = left.first { $0.isRequired && $0.state == .failing }?.label
            facts.changesWanted = left.first { $0.kind == .changesRequested }?.label ?? Self.changesWanted(by: others)
            facts.isReady = readiness?.isReady ?? (item?.group == .ready)
            let reviews = left.filter { $0.kind == .approvals || $0.kind == .requiredReviewers }
            if !facts.isReady, facts.changesWanted == nil, !reviews.isEmpty, reviews.allSatisfy(\.isDone) {
                facts.leftAfterReviews = readiness?.left.first { $0.isRequired }?.label
            }
            // Someone, or a team, asked to review it besides you: who it waits for, as What's Left says it, the required
            // reviewers it names first.
            if others.contains(where: { $0.person.id != pr.author.id }) {
                let waiting = reviews.filter { !$0.isDone }
                facts.waitingFor = (waiting.first { $0.kind == .requiredReviewers } ?? waiting.first)?.label ?? "Waiting for reviewers"
            }
        case .reviewer:
            let mine = pr.reviewer(me)
            if mine?.vote.wantsChanges == true {
                facts.youWantChanges = "Waiting for \(pr.author.firstName)'s changes"
            } else if mine?.hasDeclined != true, mine.map({ $0.vote == Vote.none }) ?? true {
                facts.asksYou = sentInChat ?? "\(pr.author.firstName) asked you"
            }
        case .linked:
            // Only while what someone sent you still needs you: once you've answered it, it's not on your board.
            if item?.group == .needsYou { facts.asksYou = sentInChat }
        }
        return facts
    }

    /// "Priya wants changes", "Sam rejected it", "Changes requested", from the votes alone, for one whose details aren't
    /// read yet, as What's Left would say it.
    static func changesWanted(by reviewers: [Reviewer]) -> String? {
        let wanting = reviewers.filter { !$0.isGroup && $0.vote.wantsChanges }
        guard let first = wanting.first(where: { $0.vote == .rejected }) ?? wanting.first else { return nil }
        if wanting.count > 1 { return "Changes requested" }
        return first.vote == .rejected ? "\(first.person.firstName) rejected it" : "\(first.person.firstName) wants changes"
    }

    /// "Priya sent it in Teams".
    static func sent(_ source: ChatSource) -> String {
        let who = source.sender.flatMap { $0.split(separator: " ").first.map(String.init) } ?? "Someone"
        return "\(who) sent it in \(source.appName)"
    }

    /// A task sent to Copilot, as its pull request's stage needs it: at work while it gets ready or works, done once Copilot
    /// called it done, stopped otherwise; called "Copilot", as its row does.
    static func session(_ entry: CopilotTaskEntry) -> StageSession? {
        guard let ref = ItemRef.session(entry.id) else { return nil }
        let activity: StageSession.Activity = switch entry.status.phase {
        case .preparing, .working: .working
        case .finished: .finished
        case .failed, .stopped: .stopped
        }
        return StageSession(ref: ref, activity: activity, since: entry.status.since ?? entry.startedAt, name: "Copilot")
    }

    /// How a pull request looks, as its row says it, and what showing and opening it do: its details on the window's Pull
    /// Requests page, or Azure DevOps, as clicking its row does.
    private func describe(_ item: PRSnapshot, showToReview: Bool) -> LinkedItem {
        let key = item.key
        return LinkedItem(
            ref: key.linkRef, label: "!\(key.number)", title: item.title,
            symbol: item.group == .done ? "arrow.triangle.merge" : "arrow.triangle.pull", color: item.rowColor,
            state: item.group.state(showToReview: showToReview), status: item.group.title, place: item.repository,
            date: item.since,
            open: { [weak store] in
                // As it is when you click it.
                store?.open(store?.items.first { $0.key == key } ?? item)
            },
            url: item.url,
            show: { [weak details] in details?.reveal(key) ?? false }
        )
    }
}
