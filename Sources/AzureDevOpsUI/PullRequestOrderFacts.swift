import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Combine
import Foundation

/// Tells Pull Request Order what Azure DevOps shows, while it's on: the pull requests the list read, the ones Done keeps a
/// day included, merged or abandoned, for what BriefBar sees become of them; with their branches, repositories and
/// authors, what each means for you now, how each looks and opens, as its row does, and, with Show Links on too, the
/// stories each is for, by reference, with those stories and their tasks, for their titles. Only Show Links reads more
/// from Azure DevOps for it, the stories (`WorkLinksStore`). As the list doesn't read which branches are forks' or which
/// is a repository's default, a pull request that targets another's branch goes after it only when the same person opened
/// both.
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
    private var cancellables: Set<AnyCancellable> = []

    init(
        order: PullRequestOrder, store: PRStore, settings: AppSettings, details: PullRequestDetailsStore?,
        workLinks: WorkLinksStore? = nil, showWorkItem: ((WorkItem) -> Void)? = nil
    ) {
        self.order = order
        self.store = store
        self.settings = settings
        self.details = details
        self.workLinks = workLinks
        self.showWorkItem = showWorkItem
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
        // Every refresh too: a pull request's branches can change without its row, such as when it's retargeted.
        store.$items.map { _ in () }
            .merge(with: store.refreshed)
            .merge(with: settings.$showToReview.removeDuplicates().map { _ in () })
            .merge(with: workLinks?.$storiesRead.removeDuplicates().map { _ in () }.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher())
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.publish() } }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        order.withdraw(.azureDevOps)
    }

    private func turned(on: Bool) {
        if on { tellDemo() }
        publish()
    }

    /// For `--render`: the demo's orders, and what the list read, once.
    func loadOnce() -> PullRequestOrderFacts {
        tellDemo()
        publish()
        return self
    }

    /// The demo's orders, as if its sessions had told them, and the names Apple Intelligence would give its missions.
    private func tellDemo() {
        guard store.mode == .demo else { return }
        let now = store.now
        order.tellDemo(
            DemoPullRequestOrder.orders(now: now), evidence: DemoPullRequestOrder.evidence(now: now), focus: DemoPullRequestOrder.focus,
            names: DemoPullRequestOrder.names
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
        order.publish(
            .azureDevOps,
            pullRequests: Self.pullRequests(store.records, items: store.items, showToReview: showToReview, stories: stories),
            items: store.items.map { describe($0, showToReview: showToReview) } + stories.workItems.map(describe),
            readsStories: stories.areRead
        )
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
                seen?.stories = stories.byPullRequest[PRKey(record.id.organization.lowercased(), record.id.number)]
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
