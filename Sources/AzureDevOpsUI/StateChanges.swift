import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Combine
import Foundation

/// A work item's state on the Sprint page and My Work, with **Make Changes in Azure DevOps** on: a task, story or bug on the
/// sprint's board, or any other in the team's project that BriefBar reads, such as one of yours outside the sprint, or one My
/// Work's Map shows, put in another of the states of its type, as the team's backlog configuration maps them
/// (`SprintBoard.states(of:)`), from its state's menu, its own menus or its details, or, on My Work's Board, by moving its
/// card to another column (`boardStates(for:)`), each when you choose one (`ADOWrite.setState`), one at a time. Its new
/// state shows at once: on the sprint's board, or among your work outside it, and the sprint is read again
/// (`SprintStore.changedState`); elsewhere, as Show Links and its details have it, and Show Links reads it again
/// (`elsewhere`). Undo puts it back, while the line under the Sprint page's header, and My Work's, says it changed. A change
/// goes as whom BriefBar read the sprint as, and only while the work item is in the state it was in when you chose another,
/// as BriefBar reads it as the change goes. One that didn't happen says why there, and it's read again, to show its state.
/// The demo changes only its made-up work items, and reads nothing.
@MainActor
final class StateChanges: ObservableObject {
    /// A change of a work item's state.
    struct Change: Equatable {
        var key: WorkItemKey
        /// What it is: "Task 5104".
        var name: String
        var title: String
        /// The states it goes from and to, as its process names them: "New", "Active".
        var from: String
        var to: String
        /// Undo's, which puts it back in the state it was in.
        var isUndo = false
        /// Whose sign-in it goes as: whom BriefBar read the sprint as when you chose the state; nil while that's not known, as
        /// in the demo. Signed in as someone else since, nothing goes as them (`ADOClient.send(_:as:)`).
        var account: String?

        /// The same change, back: Undo's.
        var back: Change {
            Change(key: key, name: name, title: title, from: to, to: from, isUndo: !isUndo, account: account)
        }
    }

    /// What a change is doing, or what became of it, as the line under the Sprint page's header says.
    enum Line: Equatable {
        case sending(Change)
        /// Azure DevOps changed it: Undo puts it back, unless it's Undo's.
        case changed(Change)
        /// It didn't change, or may not have: why. Try Again sends it again, where it may help (`retries`).
        case failed(Change, ADOWriteProblem)
    }

    @Published private(set) var line: Line?

    let settings: AppSettings
    private weak var sprint: SprintStore?
    /// Sends a change to Azure DevOps, as whom it was asked for as, when that's known, if it's still wanted as it goes, once
    /// its token came (`ADOClient.send(_:as:while:)`): the client's; a test's stand-in. Never in the demo.
    var send: (ADOWrite, String?, @escaping @Sendable () async -> Bool) async throws -> ADOWrite.Answer
    /// A work item that neither the sprint's board nor your work outside it has, as Show Links read it, such as someone
    /// else's that My Work's Map shows, or one you added there: the source's (`WorkLinksStore.linkedWorkItem`); none by
    /// default.
    var linked: (WorkItemKey) -> WorkItem? = { _ in nil }
    /// Tells what else shows a work item that isn't on the sprint's board that its state changed, as Azure DevOps answered,
    /// or may have, nil: Show Links, which shows it so at once and reads it again, and its details. The source's; nothing
    /// by default.
    var elsewhere: (WorkItemKey, WorkItem?) -> Void = { _, _ in }
    var now: () -> Date = Date.init
    /// The change on its way, which turning the setting off, Azure DevOps stopping or someone else signing in calls off
    /// (`forgetAll`): one that hasn't gone never does.
    private var inFlight: Task<ADOWrite.Answer, Error>?
    /// How many times what was going on was called off (`forgetAll`): a change asked for before then does nothing more as
    /// it comes back from what it waited for but show the state Azure DevOps put it in.
    private var generation = 0
    /// How many times what was going on ended, as someone else signed in or Azure DevOps stopped: a change sent before then
    /// does nothing more as it settles, since it was the last one's.
    private var lifetime = 0
    /// Azure DevOps stopped: nothing more is changed.
    private var isStopped = false
    /// Whom the sprint was last read as (`SprintStore.account`).
    private var account: String?
    /// The last work item off the sprint's board whose state BriefBar changed, as Azure DevOps answered: what BriefBar knows
    /// of it until something reads it again since (`item(_:)`), as one of yours outside the sprint leaves it once it's done,
    /// for Undo to go from. In memory only.
    private var changedElsewhere: WorkItem?
    private var cancellables: Set<AnyCancellable> = []

    init(sprint: SprintStore, settings: AppSettings, client: ADOClient) {
        self.sprint = sprint
        self.settings = settings
        send = { try await client.send($0, as: $1, while: $2) }
        // Someone else signed in, as the sprint tells once it's read as them: what was going on was the last one's.
        sprint.$account.removeDuplicates()
            .sink { [weak self] account in
                MainActor.assumeIsolated { self?.accountChanged(account) }
            }
            .store(in: &cancellables)
        // Turned off, the menus offer no state, and what a change did goes, Undo with it; one on its way that hasn't gone yet
        // is called off. One that has gone goes on, since Azure DevOps may make it all the same: the line says so until it
        // settles, and then the board shows the state Azure DevOps put it in.
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

    // MARK: What you can do

    /// The states a work item can be put in from its menus, in its process's order: those of its type, as the team's backlog
    /// configuration maps them, with one to go to that it isn't in, for one on the sprint's board, and any other in the
    /// team's project that BriefBar reads (`item(_:)`). None while Make Changes in Azure DevOps is off, for a work item
    /// BriefBar doesn't read, or one in another project, or when its type's states aren't known, as with no sprint going on.
    /// In the demo too, which changes only its made-up work items.
    func choices(for item: WorkItem) -> [WorkItemState] {
        guard settings.makesChanges, !isStopped else { return [] }
        return states(for: item)
    }

    /// Whether a work item's state can be changed here (`choices(for:)`).
    func canChange(_ item: WorkItem) -> Bool {
        !choices(for: item).isEmpty
    }

    /// The states VoiceOver's actions offer to put a work item in, on its card on My Work's Board: those its menus offer
    /// (`choices(for:)`) but the one it's in; none while a change is on its way, which they couldn't make, as its menus'
    /// are dimmed then.
    func actionChoices(for item: WorkItem) -> [WorkItemState] {
        guard !isBusy else { return [] }
        return choices(for: item).filter { !Self.isSame($0.name, item.state) }
    }

    /// Whether a work item's state could be changed here once Make Changes in Azure DevOps is on, while it's off: its state's
    /// tooltip then says how to turn it on.
    func needsSetting(_ item: WorkItem) -> Bool {
        !settings.makesChanges && !isStopped && !states(for: item).isEmpty
    }

    /// What My Work's Board knows of a work item's states, for what moving its card to another column does
    /// (`BoardTask.move(to:sameLane:states:)`): for one its menus could put in another state, in the sprint or out of it,
    /// whatever the setting, the state BriefBar reads it in and the first of each kind its type has, in its process's order,
    /// held while Make Changes in Azure DevOps is off, saying how to turn it on, or while a change is on its way. Nil for any
    /// other.
    func boardStates(for item: WorkItem) -> BoardTaskStates? {
        guard !isStopped, let current = self.item(item.key) else { return nil }
        let states = states(for: current)
        guard !states.isEmpty else { return nil }
        let first = Dictionary(states.map { (MyWorkFacts.progress(of: $0.category), $0.name) }) { first, _ in first }
        let held: String? = if !settings.makesChanges {
            StateChangeText.turnOnToMove
        } else if case .sending(let change)? = line {
            StateChangeText.waitToMove(change)
        } else {
            nil
        }
        return .changes(current: current.state, first: first, held: held)
    }

    /// The states of a work item that BriefBar reads in the team's project, as `choices(for:)` offers them, whatever the
    /// setting.
    private func states(for item: WorkItem) -> [WorkItemState] {
        guard let board = sprint?.board, let current = self.item(item.key), board.isInTeamsProject(current) else { return [] }
        let states = board.states(of: current.type)
        guard states.contains(where: { !Self.isSame($0.name, current.state) }) else { return [] }
        return states
    }

    /// A work item as BriefBar reads it now, for its state's menus, what a change of it goes from and whether My Work's Map
    /// counts it done: the sprint's board's; else whichever changed last (`WorkItemDetailsStore.newest`) of yours outside the
    /// sprint, the last one off the board whose state BriefBar changed, as Azure DevOps answered, and Show Links' (`linked`),
    /// such as a parent the Map shows, which reads it last. Show Links guesses the category of its state from its name, so
    /// one in the team's project takes its state's category as the team's backlog configuration maps its type's states, as a
    /// custom state's that the team counts as done; the others' category stays while it's in the same state. Nil for one
    /// BriefBar doesn't read.
    func item(_ key: WorkItemKey) -> WorkItem? {
        if let item = sprint?.board?.item(key) { return item }
        let outside = sprint?.outside?.items.first { $0.key == key }
        let changed = changedElsewhere?.key == key ? changedElsewhere : nil
        guard var item = [changed, linked(key)].reduce(outside, { WorkItemDetailsStore.newest($0, $1) }) else { return nil }
        if let board = sprint?.board, board.isInTeamsProject(item), let category = board.categories(of: item.type)?[item.state] {
            item.category = WorkItem.Category(category: category, state: item.state)
        }
        return item
    }

    /// A change is on its way: no other starts meanwhile.
    var isBusy: Bool {
        if case .sending? = line { return true }
        return false
    }

    /// Puts a work item in another of its states, as you chose it: from the one BriefBar reads it in now, as you choose it.
    /// Nothing for one its type doesn't have, nor for the one it's in already, as a read may have found it since you chose
    /// it. Says, once the change is done, however it ended, whether BriefBar reads the work item in that state, as My Work's
    /// Board waits to know (`send`): so for the one it's in already too.
    @discardableResult
    func change(_ item: WorkItem, to name: String) async -> Bool {
        guard let sprint, let current = self.item(item.key) else { return false }
        guard !Self.isSame(current.state, name) else { return true }
        guard !isBusy, choices(for: current).contains(where: { $0.name == name }) else { return false }
        return await send(Change(
            key: current.key, name: Self.name(of: current), title: current.title, from: current.state, to: name, account: sprint.account
        ))
    }

    /// The change Undo takes back: the last one, once Azure DevOps made it, while Make Changes in Azure DevOps is on and the
    /// work item is still in the state it went to, as BriefBar last read it; not once you dismissed it, changed another, or
    /// quit.
    var undoable: Change? {
        guard case .changed(let change)? = line, !change.isUndo, settings.makesChanges, !isStopped,
              let item = item(change.key), Self.isSame(item.state, change.to)
        else { return nil }
        return change
    }

    /// Puts the work item whose state you changed last back in the state it was in, as Undo does, without asking: it's what
    /// you just did, undone.
    func undo() async {
        guard let change = undoable else { return }
        await send(change.back)
    }

    /// Sends a change that didn't happen again, as Try Again does.
    func retry() async {
        guard case .failed(let change, let problem)? = line, Self.retries(problem) else { return }
        await send(change)
    }

    /// Whether Try Again may help a change that didn't happen: not when Azure DevOps refused it, nor when the work item isn't
    /// there, or isn't in the state it was in.
    static func retries(_ problem: ADOWriteProblem) -> Bool {
        switch problem {
        case .notAllowed, .closed, .gone, .refused, .notListed: false
        default: true
        }
    }

    /// Dismisses what the line under the Sprint page's header says, but while a change is on its way.
    func dismiss() {
        guard !isBusy else { return }
        line = nil
    }

    /// "Task 5104".
    static func name(of item: WorkItem) -> String {
        "\(item.type) \(item.id)"
    }

    /// Whether two names are the same state's: Azure DevOps tells states apart whatever the case of their letters.
    static func isSame(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    // MARK: Changing

    /// Sends a change, while you can make changes (`perform(_:in:)`). Says, once it's done, whether BriefBar reads the work
    /// item in the state it goes to, however it ended: as Azure DevOps answered; or as a read found it already, as one that
    /// someone else put there while the change waited for its token, which calls it off.
    @discardableResult
    private func send(_ change: Change) async -> Bool {
        guard !isStopped, !isBusy, settings.makesChanges, let sprint else { return false }
        await perform(change, in: sprint)
        return hold(change) == .there
    }

    /// Sends a change as whom BriefBar read the sprint as when you chose it, and only while the work item is in the state it
    /// was in then: what Azure DevOps answers shows at once, and the sprint is read again. One that didn't happen, or may not
    /// have, says why, and the sprint is read again to show its state.
    private func perform(_ change: Change, in sprint: SprintStore) async {
        switch hold(change) {
        case nil:
            break
        case .there?:
            // In the state it goes to already, as chosen in another window too: there's nothing to send, nor to try again.
            if case .failed(change, _)? = line { line = nil }
            return
        case .notListed?:
            didNotChange(change, .notListed)
            return
        }
        let generation = generation, lifetime = lifetime
        line = .sending(change)
        let answer: ADOWorkItem?
        do {
            switch sprint.mode {
            case .demo:
                answer = nil
            case .live:
                let write = ADOWrite.setState(change.key, from: change.from, to: change.to)
                // Checked again as it goes, once its token came, which may take a while, over which a read may have changed it.
                let result = try await dispatch(write, as: change.account, in: generation) { [weak self] in
                    await self?.isStillWanted(change) ?? false
                }
                if case .workItem(let item) = result { answer = item } else { answer = nil }
            }
        } catch is CancellationError {
            // Called off before it went: as the setting was turned off while it waited for a token, or someone else signed in,
            // the line says nothing; as BriefBar no longer reads it in the state it was in, it says so.
            guard lifetime == self.lifetime, case .sending(change)? = line else { return }
            if generation == self.generation, let hold = hold(change), hold != .there {
                didNotChange(change, .notListed)
            } else {
                line = nil
            }
            return
        } catch {
            // Someone else signed in, or Azure DevOps stopped, as it went: it was the last one's, and does nothing more.
            guard lifetime == self.lifetime else { return }
            let problem = ADOWriteProblem(error, now: now())
            // Read again, to show its state: Azure DevOps may have changed it, or someone else may have; one off the sprint's
            // board, as Show Links has it too.
            sprint.refresh()
            if sprint.board?.item(change.key) == nil { elsewhere(change.key, nil) }
            // Called off as it went, as the setting was turned off: the line says nothing more.
            guard generation == self.generation else {
                if case .sending(change)? = line { line = nil }
                return
            }
            didNotChange(change, problem)
            return
        }
        guard lifetime == self.lifetime else { return }
        if let item = item(change.key) {
            let changed = item.changing(
                state: change.to, answer: answer, at: now(), categories: sprint.board?.categories(of: item.type)
            )
            // On the sprint's board, or among your work outside it, it's there at once, and the engine keeps it so over a
            // read that started before, and reads the sprint again; one it doesn't have, the sprint is read again for all the
            // same, as one of yours reopened comes back among your work outside it. Elsewhere, Show Links and its details
            // have it so, and it's what Undo goes from.
            if sprint.item(change.key) != nil { sprint.changedState(changed) } else { sprint.refresh() }
            if sprint.board?.item(change.key) == nil {
                changedElsewhere = changed
                elsewhere(change.key, changed)
            }
        } else {
            sprint.refresh()
        }
        // Called off as it went, as the setting was turned off: the board shows its new state, and nothing offers Undo.
        guard generation == self.generation else {
            if case .sending(change)? = line { line = nil }
            return
        }
        line = .changed(change)
        SpokenText.announce(StateChangeText.changed(change) + (change.isUndo ? "" : " Undo changes it back."))
    }

    /// Says why a change didn't happen, or may not have, on the line under the Sprint page's header, and to VoiceOver.
    private func didNotChange(_ change: Change, _ problem: ADOWriteProblem) {
        line = .failed(change, problem)
        SpokenText.announce(StateChangeText.failed(change) + " " + problem.sentence(.setState))
    }

    /// Why a change doesn't go now, as BriefBar reads the work item.
    private enum Hold {
        /// BriefBar no longer reads its work item, on the sprint's board or elsewhere, or reads it in another state than the
        /// one it was in when you chose this one.
        case notListed
        /// BriefBar reads it in the state it goes to already.
        case there
    }

    /// Why a change doesn't go now; nil when it can.
    private func hold(_ change: Change) -> Hold? {
        guard let item = item(change.key) else { return .notListed }
        if Self.isSame(item.state, change.to) { return .there }
        return Self.isSame(item.state, change.from) ? nil : .notListed
    }

    /// Whether a change on its way still goes, as it's about to, once its token came: while you can make changes, and
    /// BriefBar reads its work item in the state it was in.
    private func isStillWanted(_ change: Change) -> Bool {
        settings.makesChanges && !isStopped && hold(change) == nil
    }

    /// Sends a change, while you can make changes and nothing called it off since it was asked for (`generation`), as whom
    /// it was asked for as, in a task that's called off as they go (`forgetAll`): before it goes, as while it waits for a
    /// token, it never does, nor once `wanted`, asked as it's about to go, no longer wants it, and throws
    /// `CancellationError`; once it's gone, it settles all the same, with Azure DevOps' answer or why it failed
    /// (`ADOClient.send(_:as:while:)`).
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
    /// DevOps stops or someone else signs in. As the setting goes off (`turnedOff`), one that has gone settles all the same,
    /// the line saying it's on its way until then, and the board then shows the state Azure DevOps put it in; otherwise what
    /// was going on was the last one's, or ends, and does nothing more as it settles (`lifetime`).
    func forgetAll(turnedOff: Bool = false) {
        if !turnedOff { lifetime += 1 }
        generation += 1
        changedElsewhere = nil
        let wasSent = inFlight != nil
        inFlight?.cancel()
        inFlight = nil
        if turnedOff, wasSent, case .sending? = line { return }
        line = nil
    }

    /// For `--render`: says this under the Sprint page's header, as if it had happened.
    func showForRendering(_ line: Line?) {
        self.line = line
    }

    /// Stops for good, when Azure DevOps stops: nothing more is changed.
    func stop() {
        isStopped = true
        forgetAll()
    }

    /// Whom the sprint was read as, as it tells: when it's someone else than before, what was going on was the last one's,
    /// and goes.
    func accountChanged(_ account: String?) {
        guard let account else { return }
        defer { self.account = account }
        guard let known = self.account, known != account else { return }
        forgetAll()
    }
}

/// What the Sprint page says of changing a work item's state.
enum StateChangeText {
    /// "Changing Task 5104 to Active…", "Changing Task 5104 back to New…".
    static func sending(_ change: StateChanges.Change) -> String {
        "Changing \(change.name) \(change.isUndo ? "back " : "")to \(change.to)…"
    }

    /// "Changed Task 5104 from New to Active.", "Changed Task 5104 back to New."
    static func changed(_ change: StateChanges.Change) -> String {
        change.isUndo ? "Changed \(change.name) back to \(change.to)." : "Changed \(change.name) from \(change.from) to \(change.to)."
    }

    /// "Couldn't change Task 5104 to Active.", "Couldn't change Task 5104 back to New."
    static func failed(_ change: StateChanges.Change) -> String {
        "Couldn't change \(change.name) \(change.isUndo ? "back " : "")to \(change.to)."
    }

    /// The menu item that takes the last change back: "Undo: Change Back to New".
    static func undo(_ change: StateChanges.Change) -> String {
        "Undo: Change Back to \(change.from)"
    }

    /// The tooltip of a work item's state: where it's a menu, "State: Active. Click to change it"; where it would be with Make
    /// Changes in Azure DevOps on, how to turn that on; else only its state.
    static func help(_ item: WorkItem, canChange: Bool, needsSetting: Bool) -> String {
        if canChange { return "State: \(item.state). Click to change it" }
        if needsSetting { return "State: \(item.state). \(turnOnHelp)" }
        return "State: \(item.state)"
    }

    /// How to turn on what changes a work item's state, while it's off.
    static let turnOnHelp = "Turn on Make Changes in Azure DevOps, in Settings › Pull Requests, to change it here."

    /// Why moving a work item's card on My Work's Board doesn't change its state while Make Changes in Azure DevOps is off.
    static let turnOnToMove = "Turn on Make Changes in Azure DevOps, in Settings › Pull Requests, to set its state by moving its card"

    /// Why it doesn't while another change is on its way: "Task 5104 is changing to Active: one state changes at a time".
    static func waitToMove(_ change: StateChanges.Change) -> String {
        "\(change.name) is changing \(change.isUndo ? "back " : "")to \(change.to): one state changes at a time"
    }
}
