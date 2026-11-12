import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Combine
import Foundation

/// Moving a work item of yours to another sprint, on My Work, with **Make Changes in Azure DevOps** on: one of your tasks or
/// bugs outside the sprint, into your team's current sprint or its next (`ADOWrite.setIteration`), each when you click it
/// and confirm, one at a time. The team's sprints are read, with one request, only as you move one to its next sprint, and
/// known for an hour (`SprintStore.nextSprint`). Where Azure DevOps put it shows at once, and the sprint and your work outside
/// it are read again (`SprintStore.moved`); Undo moves it back, while the line under My Work's header says it moved. A move
/// goes as whom BriefBar read the work item as, and only while it's where it was when you chose to move it, as BriefBar reads
/// it as you confirm. A move that didn't happen says why there, and your work is read again, to show where it is. The demo
/// moves only its made-up work, and reads nothing.
@MainActor
final class SprintMoves: ObservableObject {
    /// Where a move takes a work item: your team's current sprint, or its next.
    enum Target: Equatable {
        case current
        case next
    }

    /// What a move was chosen in: your team and its sprint going on then, by their IDs, and where it goes, that sprint or the
    /// next. Once either changed, as when the sprint ended, it doesn't go: where it goes isn't what you chose anymore.
    struct Context: Equatable {
        var team: String
        var sprint: String
        var target: Target

        init(_ board: SprintBoard, _ target: Target) {
            team = board.team.id
            sprint = board.sprint.id
            self.target = target
        }
    }

    /// A move of one of your work items from one iteration to another.
    struct Move: Equatable {
        var key: WorkItemKey
        /// What it is: "Task 5052".
        var name: String
        var title: String
        /// The paths of the iterations it goes from and to, such as `Storefront\Sprint 41`.
        var from: String
        var to: String
        /// Undo's, which moves it back where it was.
        var isUndo = false
        /// Whose sign-in it goes as: whom BriefBar read the work item as when you chose to move it; nil while that's not
        /// known, as in the demo. Signed in as someone else since, nothing goes as them (`ADOClient.send(_:as:)`).
        var account: String?
        /// What it was chosen in, which it goes only in; nil for Undo's, which moves it back where it was, whatever goes on.
        var context: Context?

        /// Where it goes from, as its card says: "Sprint 41", "No sprint".
        var fromName: String { OutsideWork.place(from) }
        /// Where it goes, as its card would say.
        var toName: String { OutsideWork.place(to) }

        /// The same move, back where it was: Undo's.
        var back: Move {
            Move(key: key, name: name, title: title, from: to, to: from, isUndo: !isUndo, account: account)
        }
    }

    /// A move that waits for you to confirm it, with the sprint it goes to: the current one, or the next, with its dates.
    struct Proposal: Equatable, Identifiable {
        var move: Move
        var target: Target
        var sprint: Sprint

        var id: WorkItemKey { move.key }
    }

    /// What a move is doing, or what became of it, as the line under My Work's header says.
    enum State: Equatable {
        case sending(Move)
        /// Azure DevOps moved it: Undo moves it back, unless it's Undo's.
        case moved(Move)
        /// It didn't move, or may not have: why. Try Again sends it again.
        case failed(Move, ADOWriteProblem)
        /// It didn't go: your team, or its sprint going on, changed since you chose it.
        case outdated(Move)
    }

    /// Looking for your team's next sprint, to move a work item there, or why it couldn't be found.
    enum Finding: Equatable {
        /// Reading your team's sprints, for the one after the current one: what for, "Task 5052".
        case reading(name: String)
        /// They couldn't be read: why. Try Again reads them again, for that work item.
        case failed(name: String, key: WorkItemKey, problem: String)
        /// Azure DevOps has none after the current one, by its name.
        case none(after: String)
        /// The work item is in it already: what it is, "Task 5052", and the sprint's name.
        case already(name: String, sprint: String)
    }

    @Published private(set) var state: State?
    /// While it's there, the line under My Work's header says it, in place of what a move did.
    @Published private(set) var finding: Finding?

    let settings: AppSettings
    private weak var sprint: SprintStore?
    /// Sends a change to Azure DevOps, as whom it was asked for as, when that's known, if it's still wanted as it goes, once
    /// its token came (`ADOClient.send(_:as:while:)`): the client's; a test's stand-in. Never in the demo.
    var send: (ADOWrite, String?, @escaping @Sendable () async -> Bool) async throws -> ADOWrite.Answer
    /// Your team's sprint after the current one (`SprintStore.nextSprint`); a test's stand-in.
    var readNextSprint: @MainActor () async throws -> Sprint?
    var now: () -> Date = Date.init
    /// The move on its way, which turning the setting off, Azure DevOps stopping or someone else signing in calls off
    /// (`forgetAll`): one that hasn't gone never does.
    private var inFlight: Task<ADOWrite.Answer, Error>?
    /// How many times what was going on was called off (`forgetAll`): a move asked for before then does nothing more as it
    /// comes back from what it waited for but show where Azure DevOps put it.
    private var generation = 0
    /// How many times what was going on ended, as someone else signed in or Azure DevOps stopped: a move sent before then does
    /// nothing more as it settles, since it was the last one's.
    private var lifetime = 0
    /// Azure DevOps stopped: nothing more is moved.
    private var isStopped = false
    /// Whom the sprint was last read as (`SprintStore.account`).
    private var account: String?
    private var cancellables: Set<AnyCancellable> = []

    init(sprint: SprintStore, settings: AppSettings, client: ADOClient) {
        self.sprint = sprint
        self.settings = settings
        send = { try await client.send($0, as: $1, while: $2) }
        readNextSprint = { [weak sprint] in try await sprint?.nextSprint() }
        // Someone else signed in, as the sprint tells once it's read as them: what was going on was the last one's.
        sprint.$account.removeDuplicates()
            .sink { [weak self] account in
                MainActor.assumeIsolated { self?.accountChanged(account) }
            }
            .store(in: &cancellables)
        // Turned off, cards offer no move, and what a move did goes, Undo with it; one on its way that hasn't gone yet is
        // called off. One that has gone goes on, since Azure DevOps may make it all the same: the line says so until it
        // settles, and then the card shows where Azure DevOps put it.
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

    /// Whether a work item of yours can move to another sprint here: Make Changes in Azure DevOps is on, a sprint is going on,
    /// and it's outside it, read with its iteration, among your work outside the sprint (`OutsideWork.place`). In the demo
    /// too, which moves only its made-up work.
    func canMove(_ item: WorkItem) -> Bool {
        guard settings.makesChanges, !isStopped, let sprint, let board = sprint.board, item.iteration != nil,
              sprint.outside?.items.contains(where: { $0.key == item.key }) == true
        else { return false }
        return !OutsideWork.isSamePath(item.iteration, board.sprint.path)
    }

    /// A move is on its way, or BriefBar looks for your team's next sprint: no other starts meanwhile.
    var isBusy: Bool {
        if case .sending? = state { return true }
        if case .reading? = finding { return true }
        return false
    }

    /// The name of your team's current sprint, which a card's menu moves a work item to: "Sprint 42".
    var currentSprint: String? {
        sprint?.board?.sprint.name
    }

    /// A work item's move to the sprint going on, to confirm.
    func propose(_ item: WorkItem) -> Proposal? {
        guard canMove(item), !isBusy, let board = sprint?.board,
              let move = move(of: item, to: board.sprint.path, in: Context(board, .current))
        else { return nil }
        return Proposal(move: move, target: .current, sprint: board.sprint)
    }

    /// A work item's move to your team's next sprint, to confirm, once it's known: read as you ask, unless it was within the
    /// hour. While it's read, and when it can't be, or there's none, the line under My Work's header says so.
    func proposeNext(_ item: WorkItem) async -> Proposal? {
        guard canMove(item), !isBusy, let board = sprint?.board else { return nil }
        let name = Self.name(of: item)
        let generation = generation
        finding = .reading(name: name)
        let next: Sprint?
        do {
            next = try await readNextSprint()
        } catch is CancellationError {
            if generation == self.generation { finding = nil }
            return nil
        } catch {
            guard generation == self.generation else { return nil }
            let problem = (error as? ADOError).map { PulseProblem.from($0).message } ?? error.localizedDescription
            finding = .failed(name: name, key: item.key, problem: problem)
            SpokenText.announce(SprintMoveText.findFailed(name, problem))
            return nil
        }
        guard generation == self.generation else { return nil }
        // Your team, or its sprint going on, changed while its sprints were read: what was found is for what went before.
        guard let shown = sprint?.board, Context(shown, .next) == Context(board, .next) else {
            finding = nil
            return nil
        }
        guard let next else {
            finding = .none(after: board.sprint.name)
            SpokenText.announce(SprintMoveText.noNextSprint(after: board.sprint.name))
            return nil
        }
        // As the work item is now, which may have changed while the sprints were read.
        guard let current = sprint?.item(item.key), canMove(current) else {
            finding = nil
            return nil
        }
        guard let move = move(of: current, to: next.path, in: Context(board, .next)) else {
            finding = .already(name: name, sprint: next.name)
            SpokenText.announce(SprintMoveText.already(name, in: next.name))
            return nil
        }
        finding = nil
        return Proposal(move: move, target: .next, sprint: next)
    }

    /// Whether a work item is in your team's next sprint, as read within the hour (`SprintStore.knownNextSprint`): its menus
    /// then offer no move there.
    func isInNextSprint(_ item: WorkItem) -> Bool {
        guard let next = sprint?.knownNextSprint(now: now()) else { return false }
        return OutsideWork.isSamePath(item.iteration, next.path)
    }

    /// Reads your team's sprints again, for a work item's move to the next, as Try Again does.
    func retryFinding() async -> Proposal? {
        guard case .failed(_, let key, _)? = finding, let item = sprint?.item(key) else {
            finding = nil
            return nil
        }
        finding = nil
        return await proposeNext(item)
    }

    /// A work item's move from where it is to another iteration, chosen in `context`; nil where it is already.
    private func move(of item: WorkItem, to path: String, in context: Context) -> Move? {
        guard let from = item.iteration, !OutsideWork.isSamePath(from, path) else { return nil }
        return Move(
            key: item.key, name: Self.name(of: item), title: item.title, from: from, to: path, account: sprint?.account,
            context: context
        )
    }

    /// Where a work item of yours is, as BriefBar last read it: in the sprint's iteration, for one on its board, which reads
    /// none; in its own, for one outside it; nil when that's not known.
    private func path(of item: WorkItem) -> String? {
        if let board = sprint?.board, board.item(item.key) != nil { return board.sprint.path }
        return item.iteration
    }

    /// "Task 5052".
    static func name(of item: WorkItem) -> String {
        "\(item.type) \(item.id)"
    }

    /// The move Undo takes back: the last one, once Azure DevOps made it, while Make Changes in Azure DevOps is on and the
    /// work item is still where it went, as BriefBar last read it; not once you dismissed it, moved another, or quit.
    var undoable: Move? {
        guard case .moved(let move)? = state, !move.isUndo, settings.makesChanges, !isStopped,
              let item = sprint?.item(move.key)
        else { return nil }
        guard let path = path(of: item) else { return move }
        return OutsideWork.isSamePath(path, move.to) ? move : nil
    }

    /// Whether Try Again may help a move that didn't happen: not when Azure DevOps refused it, nor when the work item isn't
    /// there, or isn't where it was.
    static func retries(_ problem: ADOWriteProblem) -> Bool {
        switch problem {
        case .notAllowed, .closed, .gone, .refused, .notListed: false
        default: true
        }
    }

    /// Dismisses what the line under My Work's header says.
    func dismiss() {
        if finding != nil {
            finding = nil
            return
        }
        guard !isBusy else { return }
        state = nil
    }

    // MARK: Moving

    /// Moves a work item, as you confirmed it.
    func move(_ proposal: Proposal) async {
        await send(proposal.move)
    }

    /// Moves the last work item you moved back where it was, as Undo does, without asking: it's what you just did, undone.
    func undo() async {
        guard let move = undoable else { return }
        await send(move.back)
    }

    /// Sends a move that didn't happen again, as Try Again does.
    func retry() async {
        guard case .failed(let move, let problem)? = state, Self.retries(problem) else { return }
        await send(move)
    }

    /// Sends a move, while you can make changes, as whom BriefBar read the work item as when you chose to move it, and only
    /// while it's where it was then: what Azure DevOps answers shows at once, and the sprint and your work outside it are read
    /// again. One that didn't happen, or may not have, says why, and your work is read again to show where it is.
    private func send(_ move: Move) async {
        guard !isStopped, !isBusy, settings.makesChanges, let sprint else { return }
        switch hold(move) {
        case nil:
            break
        case .there?:
            // Where it goes already, as confirmed in another window too: there's nothing to send, nor to try again.
            if case .failed(move, _)? = state { state = nil }
            return
        case let hold?:
            held(move, hold)
            return
        }
        let generation = generation, lifetime = lifetime
        finding = nil
        state = .sending(move)
        let answer: ADOWorkItem?
        do {
            switch sprint.mode {
            case .demo:
                answer = nil
            case .live:
                let write = ADOWrite.setIteration(move.key, from: move.from, to: move.to)
                // Checked again as it goes, once its token came, which may take a while, over which a read may have moved it.
                let result = try await dispatch(write, as: move.account, in: generation) { [weak self] in
                    await self?.isStillWanted(move) ?? false
                }
                if case .workItem(let item) = result { answer = item } else { answer = nil }
            }
        } catch is CancellationError {
            // Called off before it went: as the setting was turned off while it waited for a token, or someone else signed in,
            // the line says nothing; as BriefBar no longer reads it where it was, or shows another team or sprint, it says so.
            guard lifetime == self.lifetime, case .sending(move)? = state else { return }
            if generation == self.generation, let hold = hold(move), hold != .there {
                held(move, hold)
            } else {
                state = nil
            }
            return
        } catch {
            // Someone else signed in, or Azure DevOps stopped, as it went: it was the last one's, and does nothing more.
            guard lifetime == self.lifetime else { return }
            let problem = ADOWriteProblem(error, now: now())
            // Read again, to show where it is: Azure DevOps may have moved it, or someone else may have.
            sprint.refresh()
            // The sprint it didn't go to may be gone or renamed: your team's next sprint is read again as you move one there.
            sprint.forgetNextSprint(at: move.to)
            // Called off as it went, as the setting was turned off: the line says nothing more.
            guard generation == self.generation else {
                if case .sending(move)? = state { state = nil }
                return
            }
            didNotMove(move, problem)
            return
        }
        guard lifetime == self.lifetime else { return }
        if let item = sprint.item(move.key) {
            sprint.moved(item.moved(to: move.to, answer: answer, at: now()))
        } else {
            sprint.refresh()
        }
        // Called off as it went, as the setting was turned off: the card shows where it went, and nothing offers Undo.
        guard generation == self.generation else {
            if case .sending(move)? = state { state = nil }
            return
        }
        state = .moved(move)
        SpokenText.announce(SprintMoveText.moved(move) + (move.isUndo ? "" : " Undo moves it back."))
    }

    /// Says why a move didn't happen, or may not have, on the line under My Work's header, and to VoiceOver.
    private func didNotMove(_ move: Move, _ problem: ADOWriteProblem) {
        state = .failed(move, problem)
        SpokenText.announce(SprintMoveText.failed(move) + " " + problem.sentence(.setIteration))
    }

    /// Why a move doesn't go now, as BriefBar reads its work item, and shows your team and its sprint.
    private enum Hold {
        /// Another team shows, or another sprint is going on, than it was chosen for.
        case outdated
        /// BriefBar no longer reads it among your work, or reads it elsewhere than where it was when you chose to move it.
        case notListed
        /// BriefBar reads it where it goes already.
        case there
    }

    /// Why a move doesn't go now; nil when it can. Where its work item is isn't always known, as for one read without its
    /// iteration: Azure DevOps then tests it (`ADOWrite`).
    private func hold(_ move: Move) -> Hold? {
        guard let sprint else { return .notListed }
        if let context = move.context, sprint.board.map({ Context($0, context.target) }) != context { return .outdated }
        guard let item = sprint.item(move.key) else { return .notListed }
        guard let path = path(of: item) else { return nil }
        if OutsideWork.isSamePath(path, move.to) { return .there }
        return OutsideWork.isSamePath(path, move.from) ? nil : .notListed
    }

    /// Says why a move doesn't go, but for one where it goes already.
    private func held(_ move: Move, _ hold: Hold) {
        switch hold {
        case .outdated:
            state = .outdated(move)
            SpokenText.announce(SprintMoveText.outdated(move))
        case .notListed:
            didNotMove(move, .notListed)
        case .there:
            break
        }
    }

    /// Whether a move on its way still goes, as it's about to, once its token came: while you can make changes, and BriefBar
    /// reads its work item where it was, for the team and sprint it was chosen for.
    private func isStillWanted(_ move: Move) -> Bool {
        settings.makesChanges && !isStopped && hold(move) == nil
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

    /// Forgets what was going on, and calls off a move on its way that hasn't gone yet, as the setting goes off, Azure DevOps
    /// stops or someone else signs in. As the setting goes off (`turnedOff`), one that has gone settles all the same, the
    /// line saying it's on its way until then, and the card then shows where Azure DevOps put it; otherwise what was going on
    /// was the last one's, or ends, and does nothing more as it settles (`lifetime`).
    func forgetAll(turnedOff: Bool = false) {
        if !turnedOff { lifetime += 1 }
        generation += 1
        let wasSent = inFlight != nil
        inFlight?.cancel()
        inFlight = nil
        finding = nil
        if turnedOff, wasSent, case .sending? = state { return }
        state = nil
    }

    /// For `--render`: says this under My Work's header, as if it had happened.
    func showForRendering(_ state: State?, finding: Finding? = nil) {
        self.state = state
        self.finding = finding
    }

    /// Stops for good, when Azure DevOps stops: nothing more is moved.
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

/// What My Work says of moving your work to another sprint.
enum SprintMoveText {
    /// The confirmation's title: "Move Task 5052 to Sprint 42?"
    static func title(_ proposal: SprintMoves.Proposal) -> String {
        "Move \(proposal.move.name) to \(proposal.sprint.name)?"
    }

    /// The confirmation's button: "Move to Sprint 42".
    static func confirm(_ proposal: SprintMoves.Proposal) -> String {
        "Move to \(proposal.sprint.name)"
    }

    /// What the confirmation says: where it is, where it goes, that it's a change in Azure DevOps, as you, and how to take it
    /// back. "“Remove the old cart cookie” is in Sprint 41. BriefBar sets its iteration in Azure DevOps to Sprint 43, your
    /// team's next sprint, Nov 24 – Dec 5, as you. You can undo it on My Work."
    static func message(_ proposal: SprintMoves.Proposal) -> String {
        let move = proposal.move
        let place = move.fromName == OutsideWork.noSprint ? "isn't in a sprint" : "is in \(move.fromName)"
        let sprint = switch proposal.target {
        case .current:
            "\(proposal.sprint.name), your team's current sprint"
        case .next:
            "\(proposal.sprint.name), your team's next sprint" + (dates(proposal.sprint).map { ", \($0)" } ?? "")
        }
        return "“\(move.title)” \(place). BriefBar sets its iteration in Azure DevOps to \(sprint), as you. "
            + "You can undo it on My Work."
    }

    /// A sprint's days, as the Sprint page says them: "Nov 24 – Dec 5"; nil without both.
    static func dates(_ sprint: Sprint) -> String? {
        guard let start = sprint.start, let finish = sprint.finish else { return nil }
        return SprintDates.range(start, finish)
    }

    /// "Moving Task 5052 to Sprint 42…", "Moving Task 5052 back to Sprint 41…".
    static func sending(_ move: SprintMoves.Move) -> String {
        "Moving \(move.name) \(move.isUndo ? "back " : "")to \(place(move.toName))…"
    }

    /// "Moved Task 5052 from Sprint 41 to Sprint 42.", "Moved Task 4870 to Sprint 42." for one that was in no sprint, "Moved
    /// Task 5052 back to Sprint 41."
    static func moved(_ move: SprintMoves.Move) -> String {
        if move.isUndo { return "Moved \(move.name) back to \(place(move.toName))." }
        if move.fromName == OutsideWork.noSprint { return "Moved \(move.name) to \(place(move.toName))." }
        return "Moved \(move.name) from \(place(move.fromName)) to \(place(move.toName))."
    }

    /// "Didn't move Task 5052: Sprint 42 isn't your team's current sprint anymore."
    static func outdated(_ move: SprintMoves.Move) -> String {
        "Didn't move \(move.name): \(place(move.toName)) isn't your team's \(move.context?.target == .next ? "next" : "current") "
            + "sprint anymore."
    }

    /// "Couldn't move Task 5052 to Sprint 42.", "Couldn't move Task 5052 back to Sprint 41."
    static func failed(_ move: SprintMoves.Move) -> String {
        "Couldn't move \(move.name) \(move.isUndo ? "back " : "")to \(place(move.toName))."
    }

    /// "Finding your team's next sprint, for Task 5052…".
    static func finding(_ name: String) -> String {
        "Finding your team's next sprint, for \(name)…"
    }

    /// "Couldn't find your team's next sprint, for Task 5052. Azure DevOps answered with HTTP 500."
    static func findFailed(_ name: String, _ problem: String) -> String {
        "Couldn't find your team's next sprint, for \(name). \(problem)"
    }

    /// "Your team has no sprint after Sprint 42 in Azure DevOps yet."
    static func noNextSprint(after current: String) -> String {
        "Your team has no sprint after \(current) in Azure DevOps yet."
    }

    /// "Task 5052 is already in Sprint 43, your team's next sprint."
    static func already(_ name: String, in sprint: String) -> String {
        "\(name) is already in \(sprint), your team's next sprint."
    }

    /// A card's place line's tooltip, where it's a menu: "Where it is: Sprint 41. Click to move it to the current sprint or
    /// the next"; only to the current one, for one in the next already.
    static func placeHelp(_ place: String, inNextSprint: Bool) -> String {
        inNextSprint ? "Where it is: \(place), your team's next sprint. Click to move it to the current sprint"
            : "Where it is: \(place). Click to move it to the current sprint or the next"
    }

    /// An iteration as a sentence names it: "Sprint 41"; "no sprint" for a project's own.
    static func place(_ name: String) -> String {
        name == OutsideWork.noSprint ? "no sprint" : name
    }

    /// An iteration as a menu item names it, in title case: "Sprint 41"; "No Sprint" for a project's own.
    static func menuPlace(_ name: String) -> String {
        name == OutsideWork.noSprint ? "No Sprint" : name
    }

    /// A card's place line's tooltip, where it can't move: how to turn on what moves it.
    static let turnOnHelp =
        "Turn on Make Changes in Azure DevOps, in Settings › Pull Requests, to move it to the current sprint or the next here."
}
