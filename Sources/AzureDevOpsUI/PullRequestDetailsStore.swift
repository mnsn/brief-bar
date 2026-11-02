import AzureDevOpsCore
import BriefBarCore
import Combine
import Foundation

/// The pull request whose details show beside the list on the Pull Requests page of BriefBar's window, the pages opened
/// over them, and where in them to take you. What they show is what the list read already, so they follow it as it
/// refreshes: nothing more is read for them.
@MainActor
final class PullRequestDetailsStore: ObservableObject {
    /// Somewhere in a pull request's details: one of its comment threads, one of its builds or checks, or one of their
    /// parts.
    enum Place: Hashable {
        /// A comment thread, by its ID.
        case thread(Int)
        /// A build that validates it, or a run after its merge, by its ID, as the Pipelines page knows it.
        case run(Int)
        /// A check without a run, such as a status another service posts, by its name: the first of that name.
        case check(String)
        case section(PullRequestPanel.Section)

        /// Where a build or a check is: its run, or else its name.
        static func of(_ line: PullRequestPanel.CheckLine) -> Place {
            line.buildId.map { .run($0) } ?? .check(line.run.name)
        }

        /// What the details scroll to for it: its part, its thread, or the row of the first build or check it names;
        /// nil for a build or a check they don't have.
        func anchor(in checks: [PullRequestPanel.CheckLine]) -> Anchor? {
            switch self {
            case .thread(let id): .thread(id)
            case .section(let section): .section(section)
            case .run, .check: checks.first { Place.of($0) == self }.map { .check($0.id) }
            }
        }
    }

    /// When you last looked at a pull request, and up to when what waited on you there doesn't anymore, since you removed
    /// it from Needs You or sent it to Copilot.
    struct Cutoffs: Equatable {
        var seen: Date
        var dismissed: Date
    }

    /// Something in the details to scroll to, and to point out: one of their parts, a thread, or a build's or a check's
    /// row, by its ID (`PullRequestPanel.CheckLine.id`), which no other row has.
    enum Anchor: Hashable {
        case section(PullRequestPanel.Section)
        case thread(Int)
        case check(String)
    }

    /// The pull request that shows, as the list has it now, or had it last once it's not listed; nil while none does.
    @Published private(set) var selected: PRSnapshot?
    /// What the list read of it, its threads, policies and reviewers, as it is now, or was last once it's not listed. The
    /// list doesn't read a closed one's threads and policies: one that closes while it shows keeps those it read last.
    @Published private(set) var record: PRRecord?
    /// Whether the list still has it.
    @Published private(set) var isListed = false
    /// The pages of work items, pull requests and Copilot sessions opened over its details from what's linked to it, the
    /// latest last: ‹ goes back through them.
    @Published private(set) var pages: [ItemRef] = []
    /// Where its details take you once they show, until they have.
    @Published private(set) var place: Place?

    /// Sees a pull request, as opening it from the list does: the source's.
    var markSeen: (PRSnapshot) -> Void = { _ in }
    /// A pull request's cutoffs, and how the list would have one had you last looked at it at a time: the source's.
    var cutoffs: (PRKey) -> Cutoffs? = { _ in nil }
    var classify: (PRRecord, Date) -> PRSnapshot? = { _, _ in nil }
    /// What the list read of a pull request it has: the source's.
    var readRecord: (PRKey) -> PRRecord? = { _ in nil }
    /// Whether a window shows the Pull Requests page, and opening it there: the source's.
    var hasPage: () -> Bool = { false }
    var openPage: () -> Void = {}

    /// The list, as it was last.
    private var listed: [PRSnapshot] = []
    /// Who's signed in to the Azure CLI, as the list last told.
    private var account: String?
    /// The cutoffs of the pull request that shows, from before its details showed it.
    private var before: Cutoffs?
    /// The list's changes, followed.
    private var subscriptions: Set<AnyCancellable> = []

    /// Shows what the list read, following it as it refreshes, and sees what it shows there, as opening it from the list
    /// does.
    func use(_ list: PRStore) {
        markSeen = { [weak list] item in list?.markSeen(item) }
        readRecord = { [weak list] key in list?.record(for: key) }
        cutoffs = { [weak list] key in
            list.map { Cutoffs(seen: $0.seenCutoff(for: key), dismissed: $0.dismissedCutoff(for: key)) }
        }
        classify = { [weak list] record, seen in list?.snapshot(of: record, seenAt: seen) }
        subscriptions = []
        list.$items
            .sink { [weak self] items in MainActor.assumeIsolated { self?.itemsChanged(items) } }
            .store(in: &subscriptions)
        // Once a refresh is listed, not before: one it leaves out keeps what was read of it with its last row.
        list.refreshed
            .sink { [weak self] in MainActor.assumeIsolated { self?.recordsChanged() } }
            .store(in: &subscriptions)
    }

    /// Shows a pull request's details, from their top or at a place in them, without what was open over another's. It's
    /// seen, as opening it is.
    func show(_ item: PRSnapshot, at place: Place? = nil) {
        // Shown again, it's still the same look at it.
        if item.key != selected?.key { before = cutoffs(item.key) }
        pages = []
        selected = item
        record = keeping(readRecord(item.key))
        isListed = listed.contains { $0.key == item.key }
        self.place = place
        markSeen(item)
    }

    /// From anywhere: shows a pull request's details on the Pull Requests page, in BriefBar's window. False, showing
    /// nothing, when no window shows that page, for the caller to open it in Azure DevOps instead.
    @discardableResult
    func reveal(_ item: PRSnapshot, at place: Place? = nil) -> Bool {
        guard hasPage() else { return false }
        show(item, at: place)
        openPage()
        return true
    }

    /// The same, for a pull request the list has: false when it hasn't, too.
    @discardableResult
    func reveal(_ key: PRKey, at place: Place? = nil) -> Bool {
        guard let item = listed.first(where: { $0.key == key }) else { return false }
        return reveal(item, at: place)
    }

    /// What needs you on the pull request that shows, as when its details showed it, the rest as it is now: seeing it
    /// there doesn't fold a resolved thread whose comment was new then, or make what was new old, while they show it.
    /// Answering it does, and once you've removed it from Needs You or sent it to Copilot, what you've seen is seen, as in
    /// the list. Any other's, as its row has it.
    func pendingEvents(of item: PRSnapshot, record: PRRecord?) -> [PREvent] {
        guard item.key == selected?.key, let before, let record, let current = cutoffs(item.key) else { return item.pendingEvents }
        let seen = current.dismissed == before.dismissed ? before.seen : current.seen
        // One the list wouldn't have even so has nothing that needs you, such as one sent in a chat once you've removed it
        // from Needs You: its row, kept as it was last, still says what did.
        return classify(record, seen)?.pendingEvents ?? []
    }

    /// Takes the details to a place in them, from the pages over them too.
    func go(to place: Place) {
        guard selected != nil else { return }
        pages = []
        self.place = place
    }

    /// The details went where they were asked to.
    func reached(_ place: Place) {
        if self.place == place { self.place = nil }
    }

    /// Shows the page of something linked to the pull request over its details, to come back from: one that shows
    /// already, under the one on top, by going back to it; the pull request itself, by going back to its details.
    func open(page ref: ItemRef) {
        guard let selected else { return }
        if ref == selected.key.linkRef {
            pages = []
        } else if let index = pages.firstIndex(of: ref) {
            pages = Array(pages.prefix(through: index))
        } else {
            pages.append(ref)
        }
    }

    /// Back from the page on top, to the one under it or to the details.
    func back() {
        guard !pages.isEmpty else { return }
        pages.removeLast()
    }

    /// Back to one of the pages that show, or, for nil, to the pull request's details under them.
    func back(toPage index: Int?) {
        guard let index else {
            pages = []
            return
        }
        guard pages.indices.contains(index) else { return }
        pages = Array(pages.prefix(through: index))
    }

    /// Takes the pages away: when Show Links goes off, which they come from.
    func closePages() {
        pages = []
    }

    /// Whether ‹ goes anywhere.
    var canGoBack: Bool { !pages.isEmpty }

    func close() {
        selected = nil
        before = nil
        record = nil
        isListed = false
        pages = []
        place = nil
    }

    /// The list refreshed: the details follow the pull request as it is now. One the list doesn't have anymore, such as
    /// one done a while ago, stays as it was last, until you close it.
    func itemsChanged(_ items: [PRSnapshot]) {
        listed = items
        guard let selected else { return }
        let fresh = items.first { $0.key == selected.key }
        if (fresh != nil) != isListed { isListed = fresh != nil }
        guard let fresh else { return }
        if fresh != selected { self.selected = fresh }
        recordsChanged()
    }

    /// The list read its pull requests again, which may change what it read of the one that shows without changing its
    /// row, such as an optional build: what's kept of it follows, while the list has it, for once it doesn't anymore.
    /// Then it stays as it was, even while the list still reads it, as one sent in a chat that you've seen.
    func recordsChanged() {
        guard isListed, let selected, let read = keeping(readRecord(selected.key)), read != record else { return }
        record = read
    }

    /// What the list read of a pull request, with the threads and policies it read of it last, when it shows already and
    /// they're not there anymore: once it's closed, the list doesn't read them.
    private func keeping(_ read: PRRecord?) -> PRRecord? {
        guard var read else { return nil }
        if read.details == nil, let record, record.id == read.id { read.details = record.details }
        return read
    }

    /// Someone signed in to the Azure CLI, as the list tells. When it's someone else than before, what shows was read as
    /// the last one: it closes.
    func accountChanged(_ account: String?) {
        guard let account else { return }
        defer { self.account = account }
        guard let known = self.account, known != account else { return }
        close()
    }

    /// Stops for good, when Azure DevOps is turned off.
    func stop() {
        close()
        listed = []
        account = nil
    }
}
