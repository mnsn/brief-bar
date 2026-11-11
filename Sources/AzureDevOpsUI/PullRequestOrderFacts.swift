import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Combine
import CopilotTasks
import Foundation

/// Tells Pull Request Order what Azure DevOps shows, while it's on: the pull requests the list read, the ones Done keeps a
/// day included, merged or abandoned, for what BriefBar sees become of them; with their branches, repositories and
/// authors, what each means for you now, how each looks and opens, as its row does; what each one's stage is worked out
/// from (`stageFacts`), with the Copilot tasks BriefBar sent on it and the account it was read with, whose stages you set
/// and choices for Up Next apply, and the organizations whose lists it read, which a pull request you chose has left once
/// they don't have it, unless it's one BriefBar reads by its link and hasn't yet; and, with Show Links on too, the stories
/// and work items each is for, by reference, with those stories and work items, for their titles. Only Show Links reads
/// more from Azure DevOps for it, the stories (`WorkLinksStore`). As the list doesn't read which branches are forks' or
/// which is a repository's default, a pull request that targets another's branch goes after it only when the same person
/// opened both.
@MainActor
final class PullRequestOrderFacts {
    private let order: PullRequestOrder
    private let store: PRStore
    private let settings: AppSettings
    /// Where a pull request shows in its details, on the window's Pull Requests page.
    private weak var details: PullRequestDetailsStore?
    /// The stories your pull requests are for, with Show Links on.
    private weak var workLinks: WorkLinksStore?
    /// Shows a story or a task in BriefBar's window, or opens it in Azure DevOps.
    private let showWorkItem: ((WorkItem) -> Void)?
    /// The tasks BriefBar sent to Copilot, whose sessions on a pull request its stage follows.
    private weak var copilot: CopilotTasksStore?
    private var cancellables: Set<AnyCancellable> = []
    /// Whether the demo's stages were told since Pull Request Order turned on.
    private var toldDemoStages = false

    init(
        order: PullRequestOrder, store: PRStore, settings: AppSettings, details: PullRequestDetailsStore?,
        workLinks: WorkLinksStore? = nil, showWorkItem: ((WorkItem) -> Void)? = nil, copilot: CopilotTasksStore? = nil
    ) {
        self.order = order
        self.store = store
        self.settings = settings
        self.details = details
        self.workLinks = workLinks
        self.showWorkItem = showWorkItem
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
        // Every refresh too, the first one with all it lists: a pull request's branches can change without its row, such as
        // when it's retargeted; and as the tasks sent to Copilot go, which stages follow.
        let tasks = copilot.map { $0.objectWillChange.map { _ in () }.eraseToAnyPublisher() } ?? Empty().eraseToAnyPublisher()
        store.$items.map { _ in () }
            .merge(with: store.refreshed)
            .merge(with: settings.$showToReview.removeDuplicates().map { _ in () })
            .merge(with: workLinks?.$storiesRead.removeDuplicates().map { _ in () }.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher())
            // Watching one keeps the stage you set on it, and what you change of its mission, in the preferences, rather
            // than only in memory.
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

    /// The demo's stages, as if you and its sessions had set them, once its pull requests are listed, which they're set on.
    private func tellDemoStages() {
        guard store.mode == .demo, !toldDemoStages, !store.records.isEmpty else { return }
        toldDemoStages = true
        order.tellDemo(stages: DemoPullRequestOrder.stages(now: store.now))
        order.tellDemo(sessionStages: DemoPullRequestOrder.sessionStages(now: store.now))
    }

    /// The demo's orders, as if its sessions had told them, your made-up changes to its missions, and the names Apple
    /// Intelligence would give them and the split it would suggest.
    private func tellDemo() {
        guard store.mode == .demo else { return }
        let now = store.now
        order.tellDemo(
            DemoPullRequestOrder.orders(now: now), evidence: DemoPullRequestOrder.evidence(now: now), focus: DemoPullRequestOrder.focus,
            changes: DemoPullRequestOrder.changes(now: now), names: DemoPullRequestOrder.names, split: DemoPullRequestOrder.split
        )
    }

    /// Tells what the list shows now, or, while Pull Request Order is off, nothing.
    func publish() {
        guard order.isOn else {
            order.withdraw(.azureDevOps)
            return
        }
        let showToReview = settings.showToReview
        let stories = workLinks?.storiesRead ?? WorkLinksStore.Stories()
        let tasks = copilot.flatMap { $0.isOn ? $0.entries : nil } ?? []
        order.publish(
            .azureDevOps,
            pullRequests: Self.pullRequests(store.records, items: store.items, showToReview: showToReview, stories: stories),
            items: store.items.map { describe($0, showToReview: showToReview) } + stories.workItems.map(describe),
            stages: Self.stages(
                store.records, items: store.items, tasks: tasks, watched: settings.watchedKeys, readAt: store.readTimes
            ),
            account: settings.account, inMemory: Self.sentInChats(store.records, watched: settings.watchedKeys),
            readsStories: stories.areRead, listed: store.isListing, listsRead: store.listedOrganizations,
            unreadLinks: Set(store.unreadLinks.map(\.linkRef))
        )
        tellDemoStages()
    }

    /// The pull requests listed only because someone sent them in a chat, not yours or ones you watch: what you change of
    /// their missions stays in memory, as what you've seen of them does (`AppSettings.seenSentInChats`).
    static func sentInChats(_ records: [PRRecord], watched: Set<PRKey>) -> Set<ItemRef> {
        Set(records.filter { $0.role == .linked && !watched.contains($0.id) }.map(\.id.linkRef))
    }

    // MARK: What an order sees

    /// Every pull request the list read, as an order sees it, with what it means for you now, as its group counts it, and,
    /// while they're read, the stories it's for.
    static func pullRequests(
        _ records: [PRRecord], items: [PRSnapshot], showToReview: Bool, stories: WorkLinksStore.Stories = WorkLinksStore.Stories()
    ) -> [OrderPullRequest] {
        let groups = Dictionary(items.map { ($0.key, $0.group) }, uniquingKeysWith: { first, _ in first })
        return records.compactMap { record in
            var seen = pullRequest(record.pullRequest, attention: groups[record.id]?.state(showToReview: showToReview))
            if stories.areRead {
                let key = PRKey(record.id.organization.lowercased(), record.id.number)
                seen?.stories = stories.byPullRequest[key]
                seen?.workItems = stories.workItemsByPullRequest[key]
            }
            return seen
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

    /// How a story or a task looks, as Show Links shows it, and what opening it does: it shows in BriefBar's window, or
    /// opens in Azure DevOps.
    private func describe(_ workItem: WorkItem) -> LinkedItem {
        var item = WorkLinksStore.item(workItem)
        if let showWorkItem { item.open = { showWorkItem(workItem) } }
        return item
    }

    // MARK: What a stage is worked out from

    /// Each pull request's stage's facts, from what the list read of it, its row, and the tasks sent to Copilot on it, or
    /// that opened it, newest first.
    /// - Parameters:
    ///   - watched: the pull requests you watch, which BriefBar keeps what you set on, as it keeps what you've seen of them,
    ///     while it keeps that of those only sent to you in a chat in memory.
    ///   - readAt: when what the list says of each was read (`PulseSnapshot.readTimes`, `StageFacts.readAt`): one kept as
    ///     it was while it couldn't be read keeps when it last was.
    static func stages(
        _ records: [PRRecord], items: [PRSnapshot], tasks: [CopilotTaskEntry], watched: Set<PRKey> = [], readAt: [PRKey: Date] = [:]
    ) -> [ItemRef: StageFacts] {
        let rows = Dictionary(items.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        // Newest first, as they come.
        var tasksOn: [PRKey: [CopilotTaskEntry]] = [:]
        for task in tasks {
            if let key = task.pullRequestKey { tasksOn[key, default: []].append(task) }
        }
        var facts: [ItemRef: StageFacts] = [:]
        for record in records {
            guard var fact = stageFacts(record, item: rows[record.id], tasks: tasksOn[record.id] ?? []) else { continue }
            if fact.role == .sentToYou, watched.contains(record.id) { fact.role = .watching }
            // One the lists still read but don't show, such as one sent to you in a chat once you answered it, has no stage
            // to show, but what you set on it still ends as it moves on.
            fact.isListed = rows[record.id] != nil
            fact.readAt = readAt[record.id]
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
        let cast = others.filter { $0.vote != .none }
        var facts = StageFacts(
            role: role, state: state, autoComplete: pr.autoComplete, othersVoted: !cast.isEmpty,
            votes: record.role == .author ? StageFacts.digest(votes: cast.map(\.vote.rawValue)) : Self.yourVote(pr.reviewer(me)),
            commit: pr.sourceCommit,
            sessions: tasks.compactMap(session),
            since: state.isOpen ? item?.since ?? pr.createdAt : pr.closedAt ?? item?.since
        )
        // Someone else's asks for its own reviews: its stage's menu says whose it is.
        if record.role != .author { facts.author = pr.author.firstName }
        let sentInChat = item.flatMap { item in
            item.pendingEvents.contains { $0.kind == .sentInChat } ? item.chatSource.map(sent) : nil
        }
        switch record.role {
        case .author:
            let readiness = item?.readiness ?? PRReadiness(record)
            let left = readiness?.items ?? []
            // What fails, as What's Left says it; before its details are read, or where they couldn't be, the merge the list
            // reports on its own.
            facts.failure = left.first { $0.isRequired && $0.state == .failing }?.label
                ?? (pr.hasConflicts ? "Merge conflicts" : pr.mergeProblem?.headline)
            facts.changesWanted = left.first { $0.kind == .changesRequested }?.label ?? Self.changesWanted(by: others)
            facts.isReady = readiness?.isReady ?? (item?.group == .ready)
            // Its reviews: approvals, the reviewers it requires, and any other reviewer policy, by its name. Without a
            // reviewer policy, What's Left wants someone's approval; with one that doesn't apply, nobody's review holds it up.
            let reviewerPolicies = Set((record.details?.checks ?? []).filter { $0.kind == .reviewers }.map(\.name))
            let reviews = left.filter { item in
                item.kind == .approvals || item.kind == .requiredReviewers
                    || (item.kind == .policy && reviewerPolicies.contains(item.label))
            }
            // Where BriefBar could read its policies, as they are now; else the votes alone, as What's Left's approval then
            // stands for one vote, whatever its policies want.
            let policiesRead = readiness?.isCurrent == true && record.details?.checksKnown == true
            facts.isApproved = Self.isApproved(pr, reviews: reviews, isCurrent: policiesRead)
            facts.approvedBy = Self.approvers(others.filter { !$0.isGroup && $0.vote.isApproval })
            // What's left once it's approved, but what its flags say: what fails, and changes someone wants.
            if facts.isApproved == true, !facts.isReady {
                facts.leftAfterReviews = readiness?.left.first {
                    $0.isRequired && $0.state != .failing && $0.kind != .changesRequested
                }?.label
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
            }
            // What brings it back to you, as Needs You has it, whatever your vote: someone sent it to you in a chat, or new
            // commits came since your vote. Else it asks you while you haven't voted or declined.
            if let sentInChat {
                facts.asksYou = sentInChat
            } else if item?.pendingEvents.contains(where: { $0.kind == .newCommits }) == true {
                facts.asksYou = "New commits by \(pr.author.firstName)"
            } else if mine?.hasDeclined != true, mine.map({ $0.vote == Vote.none }) ?? true {
                facts.asksYou = "\(pr.author.firstName) asked you"
            }
        case .linked:
            // Only while what someone sent you still needs you: once you've answered it, it's not on your board.
            if item?.group == .needsYou { facts.asksYou = sentInChat }
        }
        return facts
    }

    /// Whether the reviewers one of yours requires approved it, as What's Left says it: its approvals, the reviewers it
    /// requires and its other reviewer policies, all done. Never while a reviewer it requires hasn't approved, as one who
    /// wants changes, or rejected it, which What's Left says only as changes someone wants. One that requires nobody's
    /// review, as where its reviewer policy doesn't apply, isn't approved until someone approves it, which What's Left
    /// then counts. While what was read of its policies isn't current, after a push or a vote, or where BriefBar can't read
    /// them, only what its reviewers' votes tell: not approved while nobody approved it; else nil, as BriefBar can't tell.
    /// - Parameters:
    ///   - reviews: What's Left's items for its reviews, as last read.
    ///   - isCurrent: BriefBar read its policies, as it is now.
    static func isApproved(_ pr: PullRequest, reviews: [PRReadiness.Item], isCurrent: Bool) -> Bool? {
        if pr.reviewers.contains(where: { !$0.isGroup && $0.isRequired && !$0.vote.isApproval }) { return false }
        if isCurrent { return !reviews.isEmpty && reviews.allSatisfy(\.isDone) }
        return pr.reviewers.contains(where: \.vote.isApproval) ? nil : false
    }

    /// "Maria", "Maria and Priya", "Maria, Priya and Sam"; past three, "and 2 more": who approved it, by their first names;
    /// nil for nobody.
    static func approvers(_ reviewers: [Reviewer]) -> String? {
        let names = reviewers.map(\.person.firstName)
        guard let last = names.last else { return nil }
        if names.count > 3 { return names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more" }
        return names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last
    }

    /// Your own vote on someone else's pull request, as a set Teammate's review keeps it (`StageFacts.votes`): "10" once you
    /// approved it, "0d" once you declined; none while you're not one of its reviewers.
    static func yourVote(_ reviewer: Reviewer?) -> String {
        guard let reviewer else { return "" }
        return String(reviewer.vote.rawValue) + (reviewer.hasDeclined ? "d" : "")
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
    /// called it done, stopped otherwise; called "Copilot", as its row does. A review, Pre-review, writes nothing: it keeps
    /// someone else's yours to review while it runs.
    nonisolated static func session(_ entry: CopilotTaskEntry) -> StageSession? {
        guard let ref = ItemRef.session(entry.id) else { return nil }
        let activity: StageSession.Activity = switch entry.status.phase {
        case .preparing, .working: .working
        case .finished: .finished
        case .failed, .stopped: .stopped
        }
        return StageSession(
            ref: ref, activity: activity, since: entry.status.since ?? entry.startedAt, name: "Copilot", isReview: entry.action == .review
        )
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
