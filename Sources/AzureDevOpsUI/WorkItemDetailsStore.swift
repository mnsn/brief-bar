import AppKit
import AzureDevOpsCore
import BriefBarCore
import Combine

/// The work item whose details show beside the sprint, and what's read of it. A work item is read when you open it, and
/// again when the sprint shows that it changed while it shows; what's read is kept in memory for a quarter of an hour, so
/// going back and forth between work items doesn't read them again, and then forgotten, but for the details on screen.
@MainActor
final class WorkItemDetailsStore: ObservableObject {
    /// The work item that shows: as the sprint knows it at first, which shows at once, then as last read.
    @Published private(set) var selected: WorkItem?
    /// Its details, once read; while they're read again, the ones read before.
    @Published private(set) var details: WorkItemDetails?
    @Published private(set) var isLoading = false
    /// Why its details couldn't be read, the last time they were.
    @Published private(set) var failure: ADOError?
    /// The work items you went to from the details, to go back to: the latest last.
    @Published private(set) var history: [WorkItem] = []

    let mode: PRStore.Mode
    private let client: ADOClient
    private let now: () -> Date
    /// Whether a window shows the Sprint page, and opening it there: the source's.
    var hasPage: () -> Bool = { false }
    var openPage: () -> Void = {}

    private var board: SprintBoard?
    /// The team whose sprint showed last: another's closes the details.
    private var team: String?
    /// The windows that show the Sprint page on screen, where the details are: a work item that changes is read again
    /// only while one does, and once one does again.
    private var viewers: Set<String> = []
    private var cache: [WorkItemKey: WorkItemDetails] = [:]
    private var loading: (key: WorkItemKey, task: Task<Void, Never>?)?
    /// Forgets what was read a quarter of an hour ago, when it's due.
    private var expiry: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    /// What's read shows without being read again for this long, unless the sprint shows that it changed.
    static let freshFor: TimeInterval = 60
    /// And is kept, to show while it's read again, for this long, for this many work items. The details on screen stay
    /// while they show.
    static let keptFor: TimeInterval = 15 * 60
    static let keptCount = 30

    init(mode: PRStore.Mode, client: ADOClient, board: AnyPublisher<SprintBoard?, Never>, now: @escaping () -> Date = Date.init) {
        self.mode = mode
        self.client = client
        self.now = now
        board
            .receive(on: DispatchQueue.main)
            .sink { [weak self] board in MainActor.assumeIsolated { self?.boardChanged(board) } }
            .store(in: &cancellables)
    }

    /// Shows a work item from the sprint: where you came from before is forgotten.
    func show(_ item: WorkItem) {
        history = []
        select(item)
    }

    /// Shows a work item the details link to, such as a story's task, to come back from.
    func follow(_ item: WorkItem) {
        guard let selected, selected.key != item.key else { return }
        history.append(selected)
        select(item)
    }

    func back() {
        guard let previous = history.popLast() else { return }
        select(previous)
    }

    func close() {
        cancelLoading()
        selected = nil
        details = nil
        failure = nil
        history = []
    }

    /// From a list or a widget: shows the work item on the Sprint page, in BriefBar's window; in Azure DevOps when no
    /// window shows that page.
    func reveal(_ item: WorkItem) {
        guard hasPage() else {
            AzureDevOps.open(item.webURL)
            return
        }
        show(item)
        openPage()
    }

    /// Reads it again, now.
    func reload() {
        guard let selected else { return }
        load(selected)
    }

    /// Reads it again when what shows was read a while ago: when its page shows again.
    func refreshIfStale() {
        guard let selected, loading == nil, !isFresh(cache[selected.key], for: selected) else { return }
        load(selected)
    }

    func openInAzureDevOps() {
        guard let selected else { return }
        AzureDevOps.open(selected.webURL)
    }

    /// A window started or stopped showing the Sprint page on screen.
    func setVisible(_ visible: Bool, for viewer: String) {
        if visible {
            viewers.insert(viewer)
            refreshIfStale()
        } else {
            viewers.remove(viewer)
            // What shows is forgotten in time too, now.
            if viewers.isEmpty { scheduleExpiry() }
        }
    }

    /// Forgets what was read a quarter of an hour ago or more: the work items read before, and the one that shows, but
    /// while it shows on screen.
    func expire() {
        let date = now()
        cache = cache.filter { date.timeIntervalSince($0.value.readAt) < Self.keptFor }
        if viewers.isEmpty, let details, date.timeIntervalSince(details.readAt) >= Self.keptFor {
            close()
        }
        scheduleExpiry()
    }

    /// The work items whose details are kept, for tests.
    var keptWorkItems: Set<WorkItemKey> { Set(cache.keys) }

    /// Stops for good, when Azure DevOps is turned off, and forgets what it read.
    func stop() {
        close()
        cache = [:]
        board = nil
        viewers = []
        expiry?.cancel()
        expiry = nil
        cancellables.removeAll()
    }

    /// For `--render`: the work item's details, read once, and waited for.
    func loadOnce(_ item: WorkItem) async {
        show(item)
        while let task = loading?.task {
            await task.value
            // A read that ended without finishing: don't wait on it again.
            if loading?.task == task { break }
        }
    }

    // MARK: Reading

    private func select(_ item: WorkItem) {
        let item = board?.item(item.key) ?? item
        let key = item.key
        if selected?.key != key {
            cancelLoading()
            failure = nil
        }
        let cached = cache[key].flatMap { now().timeIntervalSince($0.readAt) < Self.keptFor ? $0 : nil }
        selected = Self.newest(item, cached?.item)
        details = cached
        if loading?.key != key, !isFresh(cached, for: item) {
            load(item)
        }
    }

    private func isFresh(_ details: WorkItemDetails?, for item: WorkItem) -> Bool {
        guard let details else { return false }
        if Self.isNewer(item.changedAt, than: details.item.changedAt) { return false }
        return now().timeIntervalSince(details.readAt) < Self.freshFor
    }

    private func load(_ item: WorkItem) {
        cancelLoading()
        let key = item.key
        isLoading = true
        switch mode {
        case .demo:
            let read = DemoData.workItemDetails(organization: item.organization, id: item.id, now: now())
                ?? WorkItemDetails(item: item, readAt: now())
            loading = (key, nil)
            finish(key, .success(read))
        case .live:
            let client = self.client
            let task = Task { [weak self] in
                let result: Result<WorkItemDetails, ADOError>
                do {
                    result = .success(try await WorkItemDetailsReader.read(
                        client: client, organization: item.organization, project: item.project, id: item.id
                    ))
                } catch let error as ADOError {
                    result = .failure(error)
                } catch {
                    result = .failure(.network(error.localizedDescription))
                }
                // Another work item, or none, shows now.
                guard !Task.isCancelled else { return }
                self?.finish(key, result)
            }
            loading = (key, task)
        }
    }

    private func finish(_ key: WorkItemKey, _ result: Result<WorkItemDetails, ADOError>) {
        guard loading?.key == key else { return }
        loading = nil
        isLoading = false
        switch result {
        case .success(let read):
            remember(read)
            defer { scheduleExpiry() }
            guard selected?.key == key else { return }
            details = read
            failure = nil
            selected = Self.newest(board?.item(key) ?? selected, read.item)
        case .failure(let error):
            guard selected?.key == key else { return }
            failure = error
            Log.app.error("Couldn't read a work item's details: \(error.description, privacy: .public)")
        }
    }

    private func cancelLoading() {
        loading?.task?.cancel()
        loading = nil
        isLoading = false
    }

    /// Wakes when the oldest of what's kept is a quarter of an hour old: what's read before, and what shows while it isn't
    /// on screen.
    private func scheduleExpiry() {
        expiry?.cancel()
        expiry = nil
        var dates = cache.values.map(\.readAt)
        if viewers.isEmpty, let details { dates.append(details.readAt) }
        guard let oldest = dates.min() else { return }
        let delay = max(oldest.addingTimeInterval(Self.keptFor).timeIntervalSince(now()), 1)
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.expire()
        }
    }

    private func remember(_ read: WorkItemDetails) {
        let date = now()
        cache[read.key] = read
        cache = cache.filter { date.timeIntervalSince($0.value.readAt) < Self.keptFor }
        if cache.count > Self.keptCount {
            for old in cache.values.sorted(by: { $0.readAt < $1.readAt }).prefix(cache.count - Self.keptCount) {
                cache[old.key] = nil
            }
        }
    }

    /// The sprint refreshed: what shows of the work item follows it, and its details are read again when it changed since,
    /// while they're on screen; otherwise once they are. Another team's sprint closes them. The sprint's store calls it
    /// through `init`'s publisher.
    func boardChanged(_ board: SprintBoard?) {
        self.board = board
        guard let board else { return }
        if let team, team != board.team.id, selected != nil {
            close()
        }
        team = board.team.id
        guard let selected, let fresh = board.item(selected.key) else { return }
        let newest = Self.newest(fresh, selected)
        if newest != selected { self.selected = newest }
        if !viewers.isEmpty, let details, loading?.key != fresh.key, Self.isNewer(fresh.changedAt, than: details.item.changedAt) {
            load(fresh)
        }
    }

    /// The one that changed last; the sprint's, which knows its team's states, when neither did. One that doesn't say when
    /// it changed, such as a linked work item that couldn't be read, gives way to what's read. The details guess the
    /// category of the state, so they keep the sprint's while the state is the same.
    static func newest(_ sprint: WorkItem?, _ read: WorkItem?) -> WorkItem? {
        guard let read else { return sprint }
        guard let sprint else { return read }
        if sprint.changedAt != nil || read.changedAt == nil {
            guard isNewer(read.changedAt, than: sprint.changedAt) else { return sprint }
        }
        var item = read
        if item.state == sprint.state { item.category = sprint.category }
        if item.rank == nil { item.rank = sprint.rank }
        return item
    }

    private static func isNewer(_ date: Date?, than other: Date?) -> Bool {
        guard let date, let other else { return false }
        return date > other
    }

    // MARK: Saying what went wrong

    /// What to say when a work item's details can't be read, but for signing in, which shows its own way.
    static func message(for error: ADOError) -> String {
        switch error {
        case .notFound: return "Azure DevOps can't find this work item. It may have been deleted, or moved where you can't see it."
        case .forbidden: return "You don't have access to this work item."
        case .offline: return "You're offline."
        case .throttled: return "Azure DevOps asked BriefBar to slow down. Try again in a minute."
        default: return error.description
        }
    }
}
