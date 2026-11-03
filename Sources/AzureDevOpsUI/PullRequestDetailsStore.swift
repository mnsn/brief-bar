import AzureDevOpsCore
import BriefBarCore
import Combine
import Foundation

/// The pull request whose details show beside the list on the Pull Requests page of BriefBar's window, the pages opened
/// over them, and where in them to take you. What they show is what the list read already, so they follow it as it
/// refreshes: nothing more is read for them. It's where a pull request opens from anywhere else in BriefBar: from the
/// window's other pages, and, once you chose to Open Pull Requests in BriefBar, from the menu bar, widgets and
/// notifications; or else in Azure DevOps.
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
        /// Its Files, the files its change touched.
        case files
        /// A file of its change, in its Files: its row.
        case file(FileChange.ID)
        /// Their top, where the pull request's title is.
        case top

        /// Where a build or a check is: its run, or else its name.
        static func of(_ line: PullRequestPanel.CheckLine) -> Place {
            line.buildId.map { .run($0) } ?? .check(line.run.name)
        }

        /// Where an item of what's left leads: for builds that failed, the first required one that failed and can be looked
        /// into, which opens (`PullRequestPanel.build(openedBy:)`); for anything else with a part of its own, that part,
        /// only to scroll there. Nil for an item without one, such as a draft.
        static func of(_ item: PRReadiness.Item, in panel: PullRequestPanel) -> Place? {
            if let line = panel.build(openedBy: item) { return .of(line) }
            return PullRequestPanel.section(of: item).map(Place.section)
        }

        /// What the details scroll to for it: its part, its thread, its file's row, or the row of the first build or check it
        /// names; nil for a build or a check they don't have.
        func anchor(in checks: [PullRequestPanel.CheckLine]) -> Anchor? {
            switch self {
            case .thread(let id): .thread(id)
            case .section(let section): .section(section)
            case .files: .files
            case .file(let id): .file(id)
            case .top: .top
            case .run, .check: checks.first { Place.of($0) == self }.map { .check($0.id) }
            }
        }

        /// What they scroll to for it, as `anchor(in:)` says: for a thread they don't have, their comments; for a build or a
        /// check they don't have, such as a run that isn't one a policy queued last, their builds and checks; for its merge
        /// conflicts, once it has none, their top; and for a file their Files don't list, as one a push took out of the
        /// change, or while they don't list any, their Files.
        func anchor(in panel: PullRequestPanel, files: ChangedFiles? = nil) -> Anchor {
            switch self {
            case .thread(let id): panel.threads.contains(id) ? .thread(id) : .section(.comments)
            case .section(.conflicts): panel.hasConflicts ? .section(.conflicts) : .top
            case .section(let section): .section(section)
            case .files: .files
            case .file(let id): files?.file(id) == nil ? .files : .file(id)
            case .top: .top
            case .run, .check: anchor(in: panel.checks) ?? .section(.checks)
            }
        }

        /// Where a link BriefBar made leads in a pull request: one of its threads, or one of its runs.
        init(_ place: PullRequestPlace) {
            switch place {
            case .thread(let id): self = .thread(id)
            case .run(let id): self = .run(id)
            }
        }

        /// What a pull request's row is about, for its details to show there when it's opened from anywhere but beside the
        /// list: the comment that needs you or that you answered, or the run after its merge, where its link leads; else,
        /// for one that's failing, the first of its builds and checks that failed. Nil for their top, which starts with
        /// what's left.
        static func about(_ item: PRSnapshot, record: PRRecord?) -> Place? {
            if let place = item.place { return Place(place) }
            guard item.group == .failing else { return nil }
            return PullRequestPanel(item, record: record).checks.first { $0.run.state == .failing }.map(Place.of)
        }

        /// The thread it is, if it's one.
        var thread: Int? {
            if case .thread(let id) = self { id } else { nil }
        }
    }

    /// When you last looked at a pull request, and up to when what waited on you there doesn't anymore, since you removed
    /// it from Needs You or sent it to Copilot; and when you last looked at it yourself, without BriefBar's first days.
    struct Cutoffs: Equatable {
        var seen: Date
        var dismissed: Date
        /// When you last opened it, saw its details or marked it seen; nil when you never did.
        var looked: Date? = nil
    }

    /// Something in the details to scroll to, and to point out: one of their parts, a thread, or a build's or a check's
    /// row, by its ID (`PullRequestPanel.CheckLine.id`), which no other row has; or a file's row in their Files.
    enum Anchor: Hashable {
        case section(PullRequestPanel.Section)
        case thread(Int)
        case check(String)
        case files
        case file(FileChange.ID)
        case top
    }

    /// A file of the pull request's change whose page shows in its details, in place of their parts, where on it to go,
    /// one of its comment threads, and where in the details it opened from, to go back to. Files are told apart as Git tells
    /// them, by their paths' bytes.
    struct OpenFile: Equatable {
        /// Such as "/src/PaymentsClient.cs".
        var path: String
        var thread: Int?
        /// Where in the details it opened from, such as a thread in their comments; nil for its row in their Files.
        var from: Place? = nil
        /// Or the first or the last of its open threads, as its page shows them, going on to them from another file's.
        var comment: Edge? = nil
        /// Which of the change it shows: what the Files showed as it opened from them, all of it from a comment, which
        /// the Files may not have, and as before going on to another file.
        var scope: ChangeScope = .whole

        enum Edge: Equatable {
            case first, last
        }

        var id: FileChange.ID { FileChange.ID(path: path) }

        /// "PaymentsClient.cs".
        var name: String { (path as NSString).lastPathComponent }

        static func == (lhs: OpenFile, rhs: OpenFile) -> Bool {
            lhs.id == rhs.id && lhs.thread == rhs.thread && lhs.from == rhs.from && lhs.comment == rhs.comment
                && lhs.scope == rhs.scope
        }
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
    /// The thread they were taken to, which their trail names after the pull request, "!4102 › PaymentsClient.cs:41",
    /// until they go somewhere else: another place in them, their top, a page over them, or another pull request.
    @Published private(set) var trailThread: Int?
    /// The file of its change whose page shows, in place of their parts; nil while none does.
    @Published private(set) var file: OpenFile?
    /// Which of its changes its Files show: all of it, or what changed since you last looked. Until another pull request
    /// shows.
    @Published var scope: ChangeScope = .whole
    /// Whether a file's page fills the page, over the list, rather than sharing it with the list. Until they close.
    @Published var fillsPage = false

    /// Sees a pull request, as opening it from the list does: the source's.
    var markSeen: (PRSnapshot) -> Void = { _ in }
    /// Opens a pull request in Azure DevOps, which sees it too, at the comment its row says: the source's.
    var openInAzureDevOps: (PRSnapshot) -> Void = { _ in }
    /// Opens a link in Azure DevOps, such as the page of a pull request the list doesn't have: the source's.
    var openLink: (URL) -> Void = { _ in }
    /// Whether a pull request opens in BriefBar's window from the menu bar, a widget or a notification, rather than in Azure
    /// DevOps: Open Pull Requests in BriefBar, the source's.
    var opensInBriefBar: () -> Bool = { false }
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
    /// does; opens the rest in Azure DevOps, as the list does, unless you chose to Open Pull Requests in BriefBar.
    func use(_ list: PRStore) {
        markSeen = { [weak list] item in list?.markSeen(item) }
        openInAzureDevOps = { [weak list] item in list?.open(item) }
        openLink = { [weak list] link in list?.openLink(link) }
        opensInBriefBar = { [weak list] in list?.settings.opensPullRequestsInBriefBar ?? false }
        readRecord = { [weak list] key in list?.record(for: key) }
        cutoffs = { [weak list] key in
            list.map { Cutoffs(seen: $0.seenCutoff(for: key), dismissed: $0.dismissedCutoff(for: key), looked: $0.lastLooked(at: key)) }
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
        if item.key != selected?.key {
            before = cutoffs(item.key)
            scope = .whole
        }
        pages = []
        file = nil
        selected = item
        record = keeping(readRecord(item.key))
        isListed = listed.contains { $0.key == item.key }
        self.place = place
        trailThread = place?.thread
        markSeen(item)
    }

    /// When you last looked at the pull request that shows, before its details showed it: what changed since then is what
    /// its Files can show. Nil when you never did.
    var lastLooked: Date? {
        before?.looked
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

    /// Where in its details a pull request's row is about (`Place.about`), from what the list read of it.
    func about(_ item: PRSnapshot) -> Place? {
        Place.about(item, record: readRecord(item.key))
    }

    /// The pull request as the list has it now, for what was kept of it a while, such as a line of a brief: as it was then
    /// once the list doesn't have it.
    private func current(_ item: PRSnapshot) -> PRSnapshot {
        listed.first { $0.key == item.key } ?? item
    }

    /// From the menu bar, a widget or the brief: a pull request's details in BriefBar's window, at what its row is about,
    /// once you chose to Open Pull Requests in BriefBar, while a window has the Pull Requests page; or else Azure DevOps,
    /// at the comment its row says. Either sees it.
    func open(_ item: PRSnapshot) {
        let item = current(item)
        if opensInBriefBar(), reveal(item, at: about(item)) { return }
        openInAzureDevOps(item)
    }

    /// From another page of BriefBar's window, such as the Overview: its details on the Pull Requests page, at what its row
    /// is about; or Azure DevOps, when no window has that page.
    func showDetails(_ item: PRSnapshot) {
        let item = current(item)
        if reveal(item, at: about(item)) { return }
        openInAzureDevOps(item)
    }

    /// From a page that names a pull request by its key, such as the Pipelines page: opens it in Azure DevOps as its row
    /// does, at the comment that needs you or the run after its merge, which sees it, while the list has it; or else its
    /// link.
    func openInAzureDevOps(_ key: PRKey, link: URL) {
        if let item = listed.first(where: { $0.key == key }) {
            openInAzureDevOps(item)
        } else {
            openLink(link)
        }
    }

    /// What a notification is about, from Notification Center or the window's Notifications page: the details of its pull
    /// request, which the list has, where its link leads, its own thread or run, or else at what its row is about. False,
    /// showing nothing, when they can't show: for the caller to open its link.
    /// - Parameter key: its pull request's key, as the notification keeps it (`PRKey.description`).
    func reveal(notification key: String?, link: URL?) -> Bool {
        guard let key = key.flatMap(PRKey.init(description:)), let item = listed.first(where: { $0.key == key }) else { return false }
        return reveal(item, at: link.flatMap(PullRequestPlace.init(link:)).map(Place.init) ?? about(item))
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

    /// Takes the details to a place in them, from the pages over them, and from a file's page, too.
    func go(to place: Place) {
        guard selected != nil else { return }
        pages = []
        file = nil
        self.place = place
        trailThread = place.thread
    }

    /// Back to the top of the details, where the trail starts: the thread it named leaves it.
    func goToTop() {
        go(to: .top)
    }

    /// The details went where they were asked to.
    func reached(_ place: Place) {
        if self.place == place { self.place = nil }
    }

    /// Shows a file's page in the details, in place of their parts: from their Files, from another file's page, at the first
    /// or last of its open threads (`comment`) going on to them from another file's, or, at one of its comment threads, to
    /// scroll to, from that thread in their comments, to go back to.
    /// - Parameter scope: which of the change it shows; by default, what another file's page showed, or else the Files.
    func open(
        file path: String, at thread: Int? = nil, from origin: Place? = nil, comment: OpenFile.Edge? = nil, scope: ChangeScope? = nil
    ) {
        guard selected != nil else { return }
        pages = []
        trailThread = nil
        place = nil
        // From another file's page, back goes where that one would have, and it shows the same change.
        file = OpenFile(path: path, thread: thread, from: origin ?? file?.from, comment: comment, scope: scope ?? file?.scope ?? self.scope)
    }

    /// Whether it shows a file's page of the pull request a page shows, by its reference: for whatever the page is over to go
    /// back from it first.
    func showsFile(of ref: ItemRef) -> Bool {
        file != nil && selected?.key.linkRef == ref
    }

    /// Back from a file's page to the details: where it opened from, or its row in their Files.
    func closeFile() {
        guard let file else { return }
        self.file = nil
        place = file.from ?? .file(file.id)
    }

    /// The file's page shows the file now at another path, such as one a push renamed: it's that one's from then on.
    func follow(file path: String) {
        file?.path = path
    }

    /// The file's page went to the thread it was asked to.
    func reachedThread(_ thread: Int) {
        if file?.thread == thread { file?.thread = nil }
    }

    /// The file's page went to its first or last open thread, as it was asked to: it doesn't again.
    func reachedComment(_ edge: OpenFile.Edge) {
        if file?.comment == edge { file?.comment = nil }
    }

    /// Shows the page of something linked to the pull request over its details, to come back from: one that shows
    /// already, under the one on top, by going back to it; the pull request itself, by going back to its details. A file's
    /// page stays under the pages, to come back to.
    func open(page ref: ItemRef) {
        guard let selected else { return }
        // A page opens from the details, not from the thread they were taken to.
        trailThread = nil
        if ref == selected.key.linkRef {
            pages = []
            file = nil
        } else if let index = pages.firstIndex(of: ref) {
            pages = Array(pages.prefix(through: index))
        } else {
            pages.append(ref)
        }
    }

    /// Back from the page on top, to the one under it, to a file's page under them, or to the details.
    func back() {
        if pages.isEmpty {
            closeFile()
        } else {
            pages.removeLast()
        }
    }

    /// Back to one of the pages that show, or, for nil, to the pull request's details under them, or to a file's page
    /// under them.
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

    /// Whether ‹ goes anywhere: back from a page, or from a file's page.
    var canGoBack: Bool { !pages.isEmpty || file != nil }

    func close() {
        selected = nil
        before = nil
        record = nil
        isListed = false
        pages = []
        place = nil
        trailThread = nil
        file = nil
        scope = .whole
        fillsPage = false
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
