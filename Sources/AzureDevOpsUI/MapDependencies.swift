import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Combine
import SwiftUI

/// The dependencies Azure DevOps links between work items, for My Work's Map, and those you link there or take away, with
/// **Make Changes in Azure DevOps** on: what a line stands for, or every line Azure DevOps doesn't link yet
/// (`WorkMap.links(of:)`, `unlinked`), each when you click it (`ADOWrite.addDependency`, `removeDependency`), one change at a
/// time, a dependency after another. Show Links reads them with the sprint's work items' links (`LinkEngine`) and tells them
/// here (`told`). For each dependency, BriefBar reads the later work item's links first, with its revision: one it links
/// already, or doesn't, needs nothing more; else the change goes only while the work item is still at that revision. Each
/// one done shows at once, and Show Links reads the sprint again (`changed`). The line at the top of the Map says what it's
/// doing, what it did, with Undo, which takes back what BriefBar changed and nothing else, or why it stopped, with Try Again
/// for the rest. A change goes as whom BriefBar read the sprint as. The demo changes only its made-up links, and reads
/// nothing. Show Links tells here too the work items' parents, the parents it read for the Map and the Related links it read
/// (`parents`, `parentItems`, `related`), which the Map only shows: your work items' parents above them, and related work
/// boxed together.
@MainActor
final class MapDependencies: ObservableObject {
    /// Dependencies to link, or take away.
    struct Change: Equatable {
        var dependencies: [WorkDependency]
        /// What they are, in words: "Task 5106 waits for Task 5104", "3 dependencies".
        var words: String
        var unlinks: Bool
        /// Undo's, which takes back what the last change did.
        var isUndo = false
        /// Whose sign-in it goes as: whom BriefBar read the sprint as when you clicked; nil while that's not known, as in the
        /// demo. Signed in as someone else since, nothing goes as them (`ADOClient.send(_:as:)`).
        var account: String?

        /// Undo's: those of them BriefBar changed, `written`, back; in words of their own where they're fewer.
        func back(_ written: [WorkDependency]) -> Change {
            let words = written.count == dependencies.count ? words : MapDependencyText.count(written.count)
            return Change(dependencies: written, words: words, unlinks: !unlinks, isUndo: true, account: account)
        }
    }

    /// What a change is doing, or what became of it, as the line at the top of the Map says.
    enum Line: Equatable {
        case sending(Change)
        /// Azure DevOps has them as you asked: those BriefBar changed, `written`, Undo takes back, unless it's Undo's; none
        /// were, where Azure DevOps had them so already.
        case changed(Change, written: [WorkDependency])
        /// It stopped once `done` of them were done, `written` of those by BriefBar, or may not have: why. Try Again sends the
        /// rest, where it may help.
        case failed(Change, ADOWriteProblem, done: Int, written: [WorkDependency])
    }

    /// What Azure DevOps links, as Show Links read it last, with what BriefBar changed since.
    @Published private(set) var known: Set<WorkDependency> = []
    /// The parent of each work item Show Links read with its parent: the sprint's, your linked ones, and the parents the Map
    /// climbs to.
    @Published private(set) var parents: [WorkItemKey: WorkItemKey] = [:]
    /// The parents the Map climbs to, as Show Links read them (`WorkLinks.mapParents`). My Work shows them as it reads any
    /// work item (`StateChanges.item`); they're here so the Map draws again as one is read, or its title or state changes,
    /// though no work item's parent did, as when the top one is read: it has none.
    @Published private(set) var parentItems: [WorkItemKey: WorkItem] = [:]
    /// The Related links Azure DevOps has between the sprint's work items and others, as Show Links read them last.
    @Published private(set) var related: Set<RelatedWork> = []
    @Published private(set) var line: Line?

    let settings: AppSettings
    private weak var sprint: SprintStore?
    /// Sends a change to Azure DevOps, as whom it was asked for as, if it's still wanted as it goes (`ADOClient.send(_:as:
    /// while:)`): the client's; a test's stand-in. Never in the demo.
    var send: (ADOWrite, String?, @escaping @Sendable () async -> Bool) async throws -> ADOWrite.Answer
    /// Reads a work item's links as they are now, with its revision: a GET. Never in the demo.
    var read: (WorkItemKey) async throws -> ADOWorkItemLinks
    /// Tells Show Links a dependency is linked now, or isn't, for it to read the sprint again, showing it so meanwhile.
    var changed: (WorkDependency, Bool) -> Void = { _, _ in }
    /// Asks Show Links to read the sprint again, after a change that Azure DevOps may have made though it didn't say.
    var reread: () -> Void = {}
    var now: () -> Date = Date.init
    /// The change on its way, which turning the setting off, Azure DevOps stopping or someone else signing in calls off
    /// (`forgetAll`): one that hasn't gone never does.
    private var inFlight: Task<ADOWrite.Answer, Error>?
    /// How many times what was going on was called off (`forgetAll`).
    private var generation = 0
    /// How many times what was going on ended, as someone else signed in or Azure DevOps stopped.
    private var lifetime = 0
    private var isStopped = false
    /// Whom the sprint was last read as (`SprintStore.account`).
    private var account: String?
    private var cancellables: Set<AnyCancellable> = []

    init(sprint: SprintStore, settings: AppSettings, client: ADOClient) {
        self.sprint = sprint
        self.settings = settings
        send = { try await client.send($0, as: $1, while: $2) }
        read = { key in try await client.get(ADOEndpoint.workItem(organization: key.organization, id: key.id), as: ADOWorkItemLinks.self) }
        sprint.$account.removeDuplicates()
            .sink { [weak self] account in
                MainActor.assumeIsolated { self?.accountChanged(account) }
            }
            .store(in: &cancellables)
        // Turned off, the Map offers nothing to link, and what a change did goes, Undo with it; one on its way that hasn't gone
        // yet is called off.
        settings.$makesChanges.removeDuplicates().dropFirst()
            .sink { [weak self] on in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.objectWillChange.send()
                    if !on { self.forgetAll(turnedOff: true) }
                }
            }
            .store(in: &cancellables)
    }

    /// What Show Links read: the dependencies, with what BriefBar changed since it read the sprint; and the parents, those it
    /// read for the Map and the Related links, which the Map only shows.
    func told(
        _ dependencies: Set<WorkDependency>, parents: [WorkItemKey: WorkItemKey], parentItems: [WorkItemKey: WorkItem],
        related: Set<RelatedWork>
    ) {
        if dependencies != known { known = dependencies }
        if parents != self.parents { self.parents = parents }
        if parentItems != self.parentItems { self.parentItems = parentItems }
        if related != self.related { self.related = related }
    }

    // MARK: What you can do

    /// Why the Map can't link or unlink now, for its buttons' tooltips: with Make Changes in Azure DevOps off, or while a
    /// change is on its way; nil when it can.
    var held: String? {
        if !settings.makesChanges { return MapDependencyText.turnOn }
        if isBusy { return MapDependencyText.wait }
        return nil
    }

    /// A change is on its way: no other starts meanwhile.
    var isBusy: Bool {
        if case .sending? = line { return true }
        return false
    }

    /// Links these dependencies in Azure DevOps, as you clicked, saying what they are in these words.
    func link(_ dependencies: [WorkDependency], words: String) async {
        await send(Change(dependencies: dependencies, words: words, unlinks: false, account: sprint?.account))
    }

    /// Takes these dependencies away in Azure DevOps.
    func unlink(_ dependencies: [WorkDependency], words: String) async {
        await send(Change(dependencies: dependencies, words: words, unlinks: true, account: sprint?.account))
    }

    /// What Undo sends: what BriefBar changed of the last change, back, once Azure DevOps has it all, with its Try Agains,
    /// while Make Changes in Azure DevOps is on; nothing where BriefBar changed nothing, as Azure DevOps had it so already;
    /// not once you dismissed it, made another, or quit.
    var undoable: Change? {
        guard case .changed(let change, let written)? = line, !change.isUndo, !written.isEmpty, settings.makesChanges, !isStopped
        else { return nil }
        return change.back(written)
    }

    /// Takes back the last change, as Undo does, without asking: it's what you just did, undone.
    func undo() async {
        guard let back = undoable else { return }
        await send(back)
    }

    /// Sends what a change that stopped didn't do, as Try Again does: Undo then takes back what both changed.
    func retry() async {
        guard case .failed(let change, let problem, let done, let written)? = line, Self.retries(problem) else { return }
        await send(change, from: done, written: written)
    }

    /// Whether Try Again may help a change that stopped: not when Azure DevOps refused it, nor when a work item isn't there.
    static func retries(_ problem: ADOWriteProblem) -> Bool {
        switch problem {
        case .notAllowed, .closed, .gone, .refused, .notListed: false
        default: true
        }
    }

    /// Dismisses what the line at the top of the Map says, but while a change is on its way.
    func dismiss() {
        guard !isBusy else { return }
        line = nil
    }

    // MARK: Changing

    /// Sends a change's dependencies from `start` on, one after another, after those an earlier try did, BriefBar changing
    /// `earlier` of them.
    private func send(_ change: Change, from start: Int = 0, written earlier: [WorkDependency] = []) async {
        guard !isStopped, !isBusy, settings.makesChanges, let sprint, start < change.dependencies.count else { return }
        let generation = generation, lifetime = lifetime
        let demo = sprint.mode == .demo
        line = .sending(change)
        var done = start
        var written = earlier
        do {
            for dependency in change.dependencies[start...] {
                // Called off, nothing more is read or sent.
                guard generation == self.generation, lifetime == self.lifetime else { throw CancellationError() }
                if try await apply(dependency, unlinks: change.unlinks, as: change.account, demo: demo, in: generation) {
                    written.append(dependency)
                }
                done += 1
            }
        } catch is CancellationError {
            // Called off before it went, as the setting was turned off while it waited, or someone else signed in: the line
            // says nothing more.
            guard lifetime == self.lifetime, case .sending(change)? = line else { return }
            line = nil
            return
        } catch {
            // Someone else signed in, or Azure DevOps stopped, as it went: it was the last one's, and does nothing more.
            guard lifetime == self.lifetime else { return }
            let sent = error as? Unsettled
            let problem = ADOWriteProblem(sent?.error ?? error, now: now())
            // Azure DevOps may have made it, though it didn't say: the sprint, read again, shows how it stands. Undo still
            // takes back only what it said it made.
            if sent != nil, problem.mayHaveGone { reread() }
            guard generation == self.generation else {
                if case .sending(change)? = line { line = nil }
                return
            }
            line = .failed(change, problem, done: done, written: written)
            SpokenText.announce(MapDependencyText.failed(change) + " " + problem.sentence(change.unlinks ? .removeDependency : .addDependency))
            return
        }
        guard lifetime == self.lifetime else { return }
        guard generation == self.generation else {
            if case .sending(change)? = line { line = nil }
            return
        }
        line = .changed(change, written: written)
        SpokenText.announce(MapDependencyText.changed(change, wrote: !written.isEmpty) + (undoable == nil ? "" : " Undo takes it back."))
    }

    /// Links a dependency, or takes it away: as the later work item's links are now, read first, nothing where they're as
    /// asked already; else the change, only while that work item is still at the revision read. It shows at once, either
    /// way, but where someone else signed in, or Azure DevOps stopped, meanwhile. Returns whether BriefBar changed it.
    private func apply(
        _ dependency: WorkDependency, unlinks: Bool, as account: String?, demo: Bool, in generation: Int
    ) async throws -> Bool {
        guard !demo else {
            let wasSo = known.contains(dependency) != unlinks
            mark(dependency, linked: !unlinks)
            return !wasSo
        }
        let lifetime = lifetime
        let links = try await read(dependency.after)
        guard generation == self.generation, lifetime == self.lifetime else { throw CancellationError() }
        let index = links.predecessorIndex(dependency.before.id, in: dependency.after.organization)
        let write: ADOWrite
        switch (index, unlinks) {
        case (nil, false):
            write = .addDependency(dependency.after, waitsFor: dependency.before.id, revision: links.revision)
        case (let index?, true):
            write = .removeDependency(dependency.after, waitsFor: dependency.before.id, index: index, revision: links.revision)
        default:
            // Linked already, or taken away already, as by someone else meanwhile.
            mark(dependency, linked: !unlinks)
            return false
        }
        do {
            _ = try await dispatch(write, as: account, in: generation) { [weak self] in
                await self?.isStillWanted() ?? false
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Unsettled(error: error)
        }
        // It went, as the last one's: what's known now is someone else's, or nothing.
        guard lifetime == self.lifetime else { return true }
        mark(dependency, linked: !unlinks)
        return true
    }

    /// A change that failed once it was sent, which Azure DevOps may have made all the same, as when it didn't answer in time.
    private struct Unsettled: Error {
        var error: Error
    }

    /// A dependency is linked now, or isn't: so it shows at once, and Show Links reads it again.
    private func mark(_ dependency: WorkDependency, linked: Bool) {
        if linked { known.insert(dependency) } else { known.remove(dependency) }
        changed(dependency, linked)
    }

    /// Whether a change on its way still goes, as it's about to, once its token came: while you can make changes.
    private func isStillWanted() -> Bool {
        settings.makesChanges && !isStopped
    }

    /// Sends a change, while you can make changes and nothing called it off since it was asked for (`generation`), as whom
    /// it was asked for as, in a task that's called off as they go (`forgetAll`): before it goes it never does, and throws
    /// `CancellationError`; once it's gone, it settles all the same.
    private func dispatch(
        _ write: ADOWrite, as account: String?, in generation: Int, while wanted: @escaping @Sendable () async -> Bool
    ) async throws -> ADOWrite.Answer {
        guard generation == self.generation, !isStopped, settings.makesChanges else { throw CancellationError() }
        let send = send
        let task = Task { try await send(write, account, wanted) }
        inFlight = task
        defer { if inFlight == task { inFlight = nil } }
        return try await task.value
    }

    // MARK: Forgetting

    /// Forgets what was going on, and calls off a change on its way that hasn't gone yet, as the setting goes off, Azure
    /// DevOps stops or someone else signs in. As the setting goes off (`turnedOff`), one that has gone settles all the same;
    /// otherwise what was going on was the last one's, and does nothing more as it settles (`lifetime`).
    func forgetAll(turnedOff: Bool = false) {
        if !turnedOff { lifetime += 1 }
        generation += 1
        let wasSent = inFlight != nil
        inFlight?.cancel()
        inFlight = nil
        if turnedOff, wasSent, case .sending? = line { return }
        line = nil
    }

    /// Stops for good, when Azure DevOps stops: nothing more is changed.
    func stop() {
        isStopped = true
        forgetAll()
    }

    /// Whom the sprint was read as, as it tells: when it's someone else than before, what was going on was the last one's,
    /// and goes, and so does what was known.
    func accountChanged(_ account: String?) {
        guard let account else { return }
        defer { self.account = account }
        guard let known = self.account, known != account else { return }
        forgetAll()
        self.known = []
        parents = [:]
        parentItems = [:]
        related = []
    }
}

/// What My Work's Map says of linking dependencies in Azure DevOps.
enum MapDependencyText {
    /// "Linking in Azure DevOps: Task 5106 waits for Task 5104…", "Taking away in Azure DevOps: 3 dependencies…".
    static func sending(_ change: MapDependencies.Change) -> String {
        "\(change.unlinks ? "Taking away" : "Linking") in Azure DevOps: \(change.words)…"
    }

    /// "Linked in Azure DevOps: Task 5106 waits for Task 5104.", "Took away in Azure DevOps: 3 dependencies."; where BriefBar
    /// changed none of them, as Azure DevOps had them so already, "Azure DevOps has it already: Task 5106 waits for Task
    /// 5104.", "Azure DevOps doesn't have them: 3 dependencies."
    static func changed(_ change: MapDependencies.Change, wrote: Bool) -> String {
        if wrote {
            return "\(change.unlinks ? "Took away" : "Linked") in Azure DevOps: \(change.words)."
        }
        let them = change.dependencies.count == 1 ? "it" : "them"
        if change.unlinks {
            return "Azure DevOps doesn't have \(them): \(change.words)."
        }
        return "Azure DevOps has \(them) already: \(change.words)."
    }

    /// What Undo does, in its tooltip.
    static func undoHelp(_ change: MapDependencies.Change) -> String {
        change.unlinks ? "Link again in Azure DevOps what BriefBar took away" : "Take away in Azure DevOps what BriefBar linked"
    }

    /// "1 dependency", "3 dependencies".
    static func count(_ count: Int) -> String {
        count == 1 ? "1 dependency" : "\(count) dependencies"
    }

    /// "Couldn't link in Azure DevOps: Task 5106 waits for Task 5104."
    static func failed(_ change: MapDependencies.Change) -> String {
        "Couldn't \(change.unlinks ? "take away" : "link") in Azure DevOps: \(change.words)."
    }

    /// How many a change that stopped did: "2 of 3 went."; nil for none.
    static func done(_ done: Int, of count: Int) -> String? {
        done > 0 ? "\(done) of \(count) went." : nil
    }

    /// Why the Map doesn't link while Make Changes in Azure DevOps is off.
    static let turnOn = "Turn on Make Changes in Azure DevOps, in Settings › Pull Requests, to link it there"

    /// Why it doesn't while another change is on its way.
    static let wait = "Another change to Azure DevOps is on its way: one at a time"
}

/// What linking dependencies in Azure DevOps is doing, or did, at the top of My Work's Map: Undo once it's done, Try Again
/// where it may help once it stopped.
struct MapDependencyLine: View {
    @ObservedObject var changes: MapDependencies

    var body: some View {
        if let line = changes.line {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                switch line {
                case .sending(let change):
                    ProgressView().controlSize(.small)
                    words(MapDependencyText.sending(change))
                case .changed(let change, let written):
                    symbol("link")
                    words(MapDependencyText.changed(change, wrote: !written.isEmpty))
                    if changes.undoable != nil {
                        Button("Undo") { Task { await changes.undo() } }
                            .buttonStyle(.borderless)
                            .help(MapDependencyText.undoHelp(change))
                    }
                    dismiss
                case .failed(let change, let problem, let done, _):
                    symbol("exclamationmark.triangle")
                    let sentence = problem.sentence(change.unlinks ? .removeDependency : .addDependency)
                    let parts = [MapDependencyText.failed(change), MapDependencyText.done(done, of: change.dependencies.count), sentence]
                    words(parts.compactMap { $0 }.joined(separator: " "))
                    if MapDependencies.retries(problem) {
                        Button("Try Again") { Task { await changes.retry() } }
                            .buttonStyle(.borderless)
                    }
                    dismiss
                }
            }
            .font(size: 12)
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    private func words(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var dismiss: some View {
        Button {
            changes.dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(size: 9, weight: .bold)
        }
        .buttonStyle(.borderless)
        .help("Dismiss")
        .accessibilityLabel("Dismiss")
    }
}
