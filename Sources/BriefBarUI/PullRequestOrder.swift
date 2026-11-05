import BriefBarCore
import Combine
import Foundation

/// Pull Request Order: which pull requests go together, as missions, and the order they merge in, for the Pull Requests
/// pages to list By Mission. It's made of what each source that's on tells it it shows now (`publish`), and of the orders
/// Copilot sessions told BriefBar through its agents' tools, which `--mcp` keeps in BriefBar's preferences and tells the app
/// it changed (`AgentChanges`). It's off until you turn it on (`PullRequestOrderSetting`): until then it reads nothing, not
/// even the orders it kept, and the sources tell it nothing. Turned off, it shows nothing again, and keeps the orders, what
/// it saw become of their pull requests and the mission you focus on, unused, until you forget them.
@MainActor
package final class PullRequestOrder: ObservableObject {
    @Published package private(set) var isOn: Bool
    /// The missions, as By Mission lists them (`OrderBoard.missions`): none while it's off.
    @Published package private(set) var missions: [OrderMission] = []
    /// The mission you keep on top: none while it's off.
    @Published package private(set) var focus: MissionKey?
    /// The orders sessions told BriefBar: none while it's off.
    @Published package private(set) var orders = DeclaredOrders()
    /// By Mission's view, List, Map or the Board, on both Pull Requests pages: GitHub's shows List for the Board
    /// (`view(offering:)`).
    @Published package private(set) var view: OrderView
    /// The mission a row's capsule asked By Mission to show, until it has.
    @Published package var revealed: MissionKey?
    /// The Board's lanes: one for each mission, or one for every card.
    @Published package private(set) var lanes: BoardLanes
    /// Whether you folded Up Next.
    @Published package private(set) var isUpNextFolded: Bool
    /// The column Up Next's "2 more ›" asked the Board to show, until it has.
    @Published package var revealedColumn: PullRequestStage?
    /// Each pull request's stage, where it is in its flow, as BriefBar works it out from what its source shows, or as you or
    /// a session set it: for the pull requests whose source tells their stages, Azure DevOps'; none while it's off.
    @Published package private(set) var stages: [ItemRef: StageReading] = [:]
    /// Your last change to a stage, for Undo: in memory only, until your next change, or you dismiss it.
    @Published package private(set) var lastChange: StageChange?

    private let defaults: UserDefaults
    private let isDemo: Bool
    private let now: () -> Date
    /// What BriefBar saw become of the pull requests that orders name, and of the one you focus on.
    private var evidence = OrderEvidence()
    /// The stages you set, for each Azure DevOps account (`order.stages`).
    private var marks = StageMarks()
    /// The stages you set for pull requests listed only because someone sent them to you, or before BriefBar knew which
    /// account signed in: in memory only.
    private var marksInMemory: [ItemRef: StageMark] = [:]
    /// What each source told it last.
    private var told: [SourceID: Told] = [:]
    /// Hears about the orders an agent tells or forgets through `--mcp`, while it's on.
    private var agentChanges: AnyObject?
    /// Looks at the time every hour, while it's on (`timePassed`).
    private var clock: Timer?

    /// How often it looks at the time, for what time alone changes: an order that hasn't changed for 30 days shows as stale,
    /// and one that finished goes two weeks later, whether or not the sources show anything new meanwhile.
    package static let timeCheckInterval: TimeInterval = 3_600

    /// What a source told: its pull requests and sessions, how its things look, for what shows them, what each of its
    /// sessions told BriefBar it works on, which the Map shows, and what its pull requests' stages are worked out from, with
    /// the account it read them with.
    private struct Told {
        var pullRequests: [OrderPullRequest]
        var sessions: [OrderSession]
        var items: [ItemRef: LinkedItem]
        var working: [ItemRef: [ItemRef]] = [:]
        var stages: [ItemRef: StageFacts] = [:]
        var account: String?
    }

    /// - Parameters:
    ///   - isDemo: the demo has it on, in preferences that are thrown away.
    ///   - now: the time, in tests.
    package init(defaults: UserDefaults, isDemo: Bool, now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.isDemo = isDemo
        self.now = now
        isOn = isDemo || PullRequestOrderSetting.isOn(in: defaults)
        view = OrderView.load(from: defaults)
        lanes = BoardLanes.load(from: defaults)
        isUpNextFolded = UpNext.isFolded(in: defaults)
        if isOn { load() }
    }

    /// List, Map or the Board, remembered for both pages.
    package func setView(_ view: OrderView) {
        guard view != self.view else { return }
        self.view = view
        view.save(to: defaults)
    }

    /// The view a page that offers these shows: the one you chose, or List where it doesn't offer that one, as GitHub's page
    /// doesn't offer the Board. Showing List there doesn't save it: Azure DevOps' page still shows the Board.
    package func view(offering views: [OrderView]) -> OrderView {
        view.shown(offering: views)
    }

    /// The Board's lanes, remembered.
    package func setLanes(_ lanes: BoardLanes) {
        guard lanes != self.lanes else { return }
        self.lanes = lanes
        lanes.save(to: defaults)
    }

    /// Folds or unfolds Up Next, remembered.
    package func setUpNextFolded(_ folded: Bool) {
        guard folded != isUpNextFolded else { return }
        isUpNextFolded = folded
        UpNext.setFolded(folded, in: defaults)
    }

    /// Shows the Board at a column, as Up Next's "2 more ›" does: By Mission's Board, remembered, scrolled to it.
    package func revealColumn(_ stage: PullRequestStage) {
        setView(.board)
        revealedColumn = stage
    }

    /// Asks By Mission to show a mission, as clicking a row's capsule does.
    package func reveal(_ key: MissionKey) {
        revealed = key
    }

    /// Whether BriefBar keeps anything for Pull Request Order, on or off: an order, what it saw become of their pull
    /// requests, or the mission you focus on.
    package var keepsAnything: Bool {
        [DeclaredOrders.defaultsKey, OrderEvidence.defaultsKey, OrderFocus.defaultsKey].contains { defaults.object(forKey: $0) != nil }
    }

    /// Pull Request Order, in Settings. On, it reads the orders it kept, and the sources tell it what they show; off, it
    /// forgets all that, in memory only.
    package func setOn(_ on: Bool) {
        guard on != isOn else { return }
        defaults.set(on, forKey: PullRequestOrderSetting.defaultsKey)
        Log.app.info("Pull Request Order \(on ? "on" : "off", privacy: .public)")
        isOn = on
        if on {
            load()
        } else {
            agentChanges = nil
            clock?.invalidate()
            clock = nil
            told = [:]
            orders = DeclaredOrders()
            evidence = OrderEvidence()
            focus = nil
            missions = []
            marks = StageMarks()
            marksInMemory = [:]
            stages = [:]
            lastChange = nil
        }
    }

    private func load() {
        orders = DeclaredOrders.load(from: defaults)
        evidence = OrderEvidence.load(from: defaults)
        focus = OrderFocus.load(from: defaults)
        marks = StageMarks.load(from: defaults)
        // The demo's agents keep their orders in their own memory.
        if !isDemo, agentChanges == nil {
            agentChanges = AgentChanges.observe { [weak self] in self?.reloadOrders() }
        }
        if clock == nil {
            let clock = Timer(timeInterval: Self.timeCheckInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.timePassed() }
            }
            clock.tolerance = 300
            RunLoop.main.add(clock, forMode: .common)
            self.clock = clock
        }
        rebuild()
    }

    /// Looks again at what time alone changes, as its clock does every hour: orders that went stale, those that finished
    /// long enough ago to go, and the stages you set for pull requests no list has had for 30 days.
    package func timePassed() {
        guard isOn else { return }
        if marks.forgetUnlisted(now: now()) { marks.save(to: defaults) }
        rebuild()
    }

    /// Reads the orders again, as an agent told or forgot one through `--mcp`.
    package func reloadOrders() {
        guard isOn else { return }
        let loaded = DeclaredOrders.load(from: defaults)
        guard loaded != orders else { return }
        orders = loaded
        rebuild()
    }

    // MARK: What the sources show

    /// What a source shows now, while it's on: the pull requests it lists, with what an order needs of each, the sessions
    /// it knows, how its things look, for what shows them, what each session told BriefBar it works on now
    /// (`SessionUpdates`), which changes no mission, and what its pull requests' stages are worked out from, with the
    /// account it read them with, whose stages you set apply. It replaces what the source told before. Nothing's kept while
    /// Pull Request Order is off.
    package func publish(
        _ source: SourceID, pullRequests: [OrderPullRequest] = [], sessions: [OrderSession] = [], items: [LinkedItem] = [],
        working: [ItemRef: [ItemRef]] = [:], stages: [ItemRef: StageFacts] = [:], account: String? = nil
    ) {
        guard isOn else { return }
        var byRef: [ItemRef: LinkedItem] = [:]
        for item in items where byRef[item.ref] == nil {
            byRef[item.ref] = item
        }
        let new = Told(
            pullRequests: pullRequests, sessions: sessions, items: byRef, working: working, stages: stages,
            account: account?.lowercased()
        )
        let old = told[source]
        let sameFacts = old?.pullRequests == new.pullRequests && old?.sessions == new.sessions
        let sameStages = old?.stages == new.stages && old?.account == new.account
        guard !sameFacts || !sameStages || old?.items != new.items || old?.working != new.working else { return }
        objectWillChange.send()
        told[source] = new
        // How a session looks says whether it works now, which stages follow.
        if sameFacts { restage() } else { rebuild() }
    }

    /// A source stopped: what it showed goes, and its pull requests can't be seen until it's on again.
    package func withdraw(_ source: SourceID) {
        guard told[source] != nil else { return }
        objectWillChange.send()
        told[source] = nil
        rebuild()
    }

    /// Forgets a source's things when you turn it off, as each source forgets what it kept, whether Pull Request Order is on
    /// or not: its pull requests' places in every order, which goes up a revision, the orders left with none, what BriefBar
    /// saw become of them, the mission you focus on, when it's theirs, and the stages you set for its pull requests.
    package func forget(_ source: SourceID) {
        let kinds = ItemRef.Kind.of(source)
        guard !kinds.isEmpty else { return }
        var orders = DeclaredOrders.load(from: defaults)
        let before = orders
        orders.forget(kinds)
        if orders != before { orders.save(to: defaults) }
        var evidence = OrderEvidence.load(from: defaults)
        if evidence.forget(kinds) { evidence.save(to: defaults) }
        let focus = OrderFocus.load(from: defaults)
        let kept = OrderFocus.kept(focus, in: orders, forgetting: kinds)
        if kept != focus { OrderFocus.save(kept, to: defaults) }
        var marks = StageMarks.load(from: defaults)
        if marks.forget(kinds) { marks.save(to: defaults) }
        marksInMemory = marksInMemory.filter { !kinds.contains($0.key.kind) }
        if let change = lastChange, kinds.contains(change.ref.kind) { lastChange = nil }
        withdraw(source)
        guard isOn else { return }
        self.orders = orders
        self.evidence = evidence
        self.focus = kept
        self.marks = marks
        rebuild()
    }

    /// How a source says one of its things looks, and what opening or showing it does; nil when no source that's on says.
    package func describe(_ ref: ItemRef) -> LinkedItem? {
        for source in SourceID.allCases {
            if let item = told[source]?.items[ref] { return item }
        }
        return nil
    }

    /// What a session told BriefBar it's working on now, as it shows: nothing while it isn't shown.
    package func workingOn(_ session: ItemRef) -> [ItemRef] {
        for source in SourceID.allCases {
            if let working = told[source]?.working[session] { return working }
        }
        return []
    }

    /// The sessions that told BriefBar they're working on a thing now, in reference order.
    package func sessionsWorking(on ref: ItemRef) -> [ItemRef] {
        var sessions: Set<ItemRef> = []
        for told in told.values {
            for (session, refs) in told.working where refs.contains(ref) {
                sessions.insert(session)
            }
        }
        return sessions.sorted()
    }

    // MARK: Your choices

    /// Keeps a mission on top, or none.
    package func setFocus(_ key: MissionKey?) {
        guard isOn, key != focus else { return }
        focus = key
        OrderFocus.save(key, to: defaults)
        rebuild()
    }

    /// Forget This Order: BriefBar no longer shows it, and an agent that names it is told so.
    package func forget(order id: UUID) {
        guard isOn else { return }
        var orders = DeclaredOrders.load(from: defaults)
        guard orders.plan(id) != nil else { return }
        orders.forget(id)
        orders.save(to: defaults)
        self.orders = orders
        let kept = OrderFocus.kept(focus, in: orders)
        if kept != focus {
            focus = kept
            OrderFocus.save(kept, to: defaults)
        }
        rebuild()
    }

    /// Forget All Orders: every order, what BriefBar saw become of their pull requests, and the mission you focus on,
    /// whether Pull Request Order is on or not.
    package func forgetAll() {
        objectWillChange.send()
        DeclaredOrders.forgetAll(in: defaults)
        orders = DeclaredOrders()
        evidence = OrderEvidence()
        focus = nil
        rebuild()
    }

    /// The demo's orders, as if its sessions had told them, unless it has them, with what BriefBar saw become of their pull
    /// requests before, and the mission you focus on: only in the demo, while it's on.
    package func tellDemo(_ demo: DeclaredOrders, evidence seen: OrderEvidence = OrderEvidence(), focus key: MissionKey? = nil) {
        guard isDemo, isOn else { return }
        let orders = DeclaredOrders.load(from: defaults)
        let missing = demo.plans.filter { orders.plan($0.id) == nil }
        guard !missing.isEmpty else { return }
        let told = DeclaredOrders(plans: orders.plans + missing)
        told.save(to: defaults)
        self.orders = told
        var evidence = self.evidence
        for (ref, record) in seen.records.sorted(by: { $0.key < $1.key }) where evidence.records[ref] == nil {
            evidence.observe(
                OrderObservation(ref: ref, state: record.outcome == .merged ? .merged : .closed, witness: record.witness),
                at: record.observedAt
            )
        }
        self.evidence = evidence
        evidence.save(to: defaults)
        if let key, focus == nil {
            focus = key
            OrderFocus.save(key, to: defaults)
        }
        rebuild()
    }

    /// What a source calls a session or a pull request, when one that's on says.
    package func name(of ref: ItemRef) -> String? {
        describe(ref)?.title
    }

    // MARK: Missions

    /// What the sources that are on show now.
    private var facts: OrderFacts {
        let sources = SourceID.allCases.filter { told[$0] != nil }
        return OrderFacts(
            pullRequests: sources.flatMap { told[$0]?.pullRequests ?? [] },
            sessions: sources.flatMap { told[$0]?.sessions ?? [] },
            sourcesOn: Set(sources.flatMap(ItemRef.Kind.of).filter(\.isPullRequest))
        )
    }

    /// The missions again, from what the sources show and the orders: first keeping what the sources show become of the
    /// pull requests that orders name or that you focus on, and forgetting the orders that finished long enough ago.
    private func rebuild() {
        guard isOn else {
            if !missions.isEmpty { missions = [] }
            return
        }
        let date = now()
        let facts = facts
        let focused = focus.flatMap(OrderFocus.ref(of:))
        var evidence = evidence
        for observation in facts.observations where orders.refs.contains(observation.ref) || observation.ref == focused {
            evidence.observe(observation, at: date)
        }
        let finished = orders.removeFinished(evidence: evidence, now: date)
        if !finished.isEmpty {
            // As the preferences have them, with what an agent told since.
            var saved = DeclaredOrders.load(from: defaults)
            for id in finished { saved.forget(id) }
            saved.save(to: defaults)
            orders = saved
            let kept = OrderFocus.kept(focus, in: saved)
            if kept != focus {
                focus = kept
                OrderFocus.save(kept, to: defaults)
            }
        }
        evidence.keep(only: orders.refs.union(focus.flatMap(OrderFocus.ref(of:)).map { [$0] } ?? []))
        if evidence != self.evidence {
            self.evidence = evidence
            evidence.save(to: defaults)
        }
        let missions = OrderBoard.missions(facts: facts, orders: orders, evidence: evidence, focus: focus, now: date)
        if missions != self.missions { self.missions = missions }
        restage()
    }

    // MARK: Stages

    /// A pull request's stage, while Pull Request Order is on and its source tells stages.
    package func stage(of ref: ItemRef) -> StageReading? {
        stages[ref]
    }

    /// Whether you opened a pull request, as its source tells for its stage: only yours go to Teammate's review on the Board.
    package func isYours(_ ref: ItemRef) -> Bool {
        stageFacts[ref]?.isYours ?? false
    }

    /// The Board, Up Next and each mission's next steps, for a page of these kinds, with its lanes as you chose them, or
    /// these.
    package func board(kinds: Set<ItemRef.Kind>, lanes: BoardLanes? = nil) -> PullRequestBoard {
        PullRequestBoard.make(stages: stages, missions: missions, kinds: kinds, lanes: lanes ?? self.lanes)
    }

    /// Whether BriefBar keeps a stage you set, on or off: for Forget Stages… in Settings.
    package var keepsStages: Bool {
        defaults.object(forKey: StageMarks.defaultsKey) != nil || !marksInMemory.isEmpty
    }

    /// The stages you set that BriefBar keeps, for each account, as many as there are, whatever lists have them now.
    package var keptStagesCount: Int {
        StageMarks.load(from: defaults).accounts.values.reduce(0) { $0 + $1.count } + marksInMemory.count
    }

    /// Sets a pull request's stage, as you choose it, In progress, Your review or Teammate's review, which stands until
    /// something ends it (`StageRules.stands`) or you change it; Teammate's review is Finished My Review. Undo puts back
    /// what it replaced. A pull request listed only because someone sent it to you keeps it in memory only. Refused, saying
    /// why, for a stage only BriefBar sets, one whose source tells no stages, or a new one once the account keeps the most.
    @discardableResult
    package func setStage(_ stage: PullRequestStage, of ref: ItemRef) -> StageChange.Outcome {
        guard isOn, stage.isSettable, let facts = stageFacts[ref] else { return .refused("BriefBar sets that stage itself") }
        let before = yourMark(of: ref, facts: facts)
        if let before, before.stage == stage, stages[ref]?.mark == before { return .unchanged }
        let mark = StageMark(stage: stage, at: now(), votes: facts.votes, commit: facts.commit)
        guard keep(mark, of: ref, facts: facts) else {
            return .refused(
                "BriefBar keeps up to \(StageMarks.mostPerAccount) stages you set. Let BriefBar decide one you no longer need first."
            )
        }
        lastChange = StageChange(ref: ref, before: before, after: stage)
        restage()
        return .done
    }

    /// Finished My Review: it's your teammates' turn, on yours; on someone else's, it leaves your board until something new
    /// needs you there.
    @discardableResult
    package func finishedReview(_ ref: ItemRef) -> StageChange.Outcome {
        setStage(.teammateReview, of: ref)
    }

    /// Put Yours Back: the stage you set, which a session's later change replaced, is the latest again.
    @discardableResult
    package func putYoursBack(_ ref: ItemRef) -> StageChange.Outcome {
        guard let yours = stages[ref]?.replaced else { return .unchanged }
        return setStage(yours.stage, of: ref)
    }

    /// Let BriefBar Decide: forgets the stage you set, and BriefBar works it out again.
    package func letBriefBarDecide(_ ref: ItemRef) {
        guard isOn, let facts = stageFacts[ref], let before = yourMark(of: ref, facts: facts) else { return }
        forgetMark(of: ref, facts: facts)
        lastChange = StageChange(ref: ref, before: before, after: nil)
        restage()
    }

    /// Undo: puts back exactly the stage your last change replaced, or none.
    package func undo() {
        guard isOn, let change = lastChange, let facts = stageFacts[change.ref] else {
            lastChange = nil
            return
        }
        lastChange = nil
        if let before = change.before {
            _ = keep(before, of: change.ref, facts: facts)
        } else {
            forgetMark(of: change.ref, facts: facts)
        }
        restage()
    }

    /// Takes the Undo line away, as ✕ beside it does.
    package func dismissLastChange() {
        lastChange = nil
    }

    /// Forget Stages…: every stage you set, with every account, on or off. What sessions set is theirs (18d).
    package func forgetStages() {
        objectWillChange.send()
        StageMarks.forgetAll(in: defaults)
        marks = StageMarks()
        marksInMemory = [:]
        lastChange = nil
        restage()
    }

    /// What the sources that are on tell of their pull requests' stages, the first source's of each.
    private var stageFacts: [ItemRef: StageFacts] {
        var all: [ItemRef: StageFacts] = [:]
        for source in SourceID.allCases {
            for (ref, facts) in told[source]?.stages ?? [:] where all[ref] == nil {
                all[ref] = facts
            }
        }
        return all
    }

    /// The account whose stages apply, as the source that tells a pull request's stage says.
    private func account(of ref: ItemRef) -> String? {
        SourceID.allCases.lazy.compactMap { self.told[$0] }.first { $0.stages[ref] != nil }?.account
    }

    /// Whether a stage you set for it stays in memory: one listed only because someone sent it to you, or one BriefBar
    /// doesn't know the account of yet.
    private func keepsInMemory(_ ref: ItemRef, facts: StageFacts) -> Bool {
        facts.role == .sentToYou || account(of: ref) == nil
    }

    private func yourMark(of ref: ItemRef, facts: StageFacts) -> StageMark? {
        if let mark = marksInMemory[ref] { return mark }
        guard !keepsInMemory(ref, facts: facts), let account = account(of: ref) else { return nil }
        return marks.mark(of: ref, for: account)
    }

    /// Keeps the stage you set: false when the account keeps the most already.
    private func keep(_ mark: StageMark, of ref: ItemRef, facts: StageFacts) -> Bool {
        if keepsInMemory(ref, facts: facts) {
            marksInMemory[ref] = mark
            return true
        }
        guard let account = account(of: ref), marks.set(mark, of: ref, for: account, at: now()) else { return false }
        marksInMemory[ref] = nil
        marks.save(to: defaults)
        return true
    }

    private func forgetMark(of ref: ItemRef, facts: StageFacts) {
        marksInMemory[ref] = nil
        if let account = account(of: ref), marks.clear(ref, for: account) { marks.save(to: defaults) }
    }

    /// Each pull request's stage again: from what its source tells, the sessions on it, the stage you set while it stands,
    /// and its order. A stage you set that no longer stands, or whose pull request merged or closed, goes; one kept in memory
    /// before BriefBar knew the account, or while it was only sent to you, is kept with the account once it can be; and
    /// what lists have now is noted, once a day, for what no list has had for 30 days to go.
    private func restage() {
        guard isOn else {
            if !stages.isEmpty { stages = [:] }
            return
        }
        let all = stageFacts
        let sessionsOn = sessionsOnPullRequests()
        var readings: [ItemRef: StageReading] = [:]
        var changed = false
        for (ref, facts) in all {
            let sessions = Self.merged(facts.sessions, sessionsOn[ref] ?? [])
            if let memory = marksInMemory[ref], !keepsInMemory(ref, facts: facts), let account = account(of: ref),
               marks.set(memory, of: ref, for: account, at: now()) {
                marksInMemory[ref] = nil
                changed = true
            }
            var mine = yourMark(of: ref, facts: facts)
            if let mark = mine, !facts.state.isOpen || !StageRules.stands(mark, facts: facts, sessions: sessions) {
                marksInMemory[ref] = nil
                if let account = account(of: ref), marks.clear(ref, for: account) { changed = true }
                mine = nil
            }
            let order = StageOrder.of(ref, in: missions)
            if let reading = StageRules.reading(facts: facts, sessions: sessions, marks: [mine].compactMap { $0 }, order: order) {
                readings[ref] = reading
            }
        }
        var listed: [String: Set<ItemRef>] = [:]
        for (ref, facts) in all where facts.role != .sentToYou {
            if let account = account(of: ref) { listed[account, default: []].insert(ref) }
        }
        for (account, refs) in listed where marks.listed(refs, for: account, at: now()) {
            changed = true
        }
        if changed { marks.save(to: defaults) }
        if readings != stages { stages = readings }
    }

    /// The Copilot app's sessions on each pull request, as their source tells them: those that opened it or work on it, as
    /// the app records them, and those that told BriefBar they work on it, each with what it does now and since when, as it
    /// looks; none it doesn't say how.
    private func sessionsOnPullRequests() -> [ItemRef: [StageSession]] {
        var on: [ItemRef: Set<ItemRef>] = [:]
        for told in told.values {
            for session in told.sessions {
                for ref in session.pullRequests { on[ref, default: []].insert(session.ref) }
            }
            for (session, refs) in told.working {
                for ref in refs { on[ref, default: []].insert(session) }
            }
        }
        return on.mapValues { sessions in
            sessions.sorted().compactMap { session in
                describe(session).map { StageSession(ref: session, activity: Self.activity($0.state), since: $0.date) }
            }
        }
    }

    /// What a session does, as the state it counts in says: at work, waiting for you, stopped, or done with it, finished or
    /// idle since.
    static func activity(_ state: ItemState?) -> StageSession.Activity {
        switch state {
        case .running?: .working
        case .needsYou?: .waitsForYou
        case .failing?: .stopped
        case .done?, nil: .finished
        }
    }

    /// The sessions a source knows of on a pull request, with the Copilot app's, each once: the source's first.
    static func merged(_ own: [StageSession], _ others: [StageSession]) -> [StageSession] {
        let known = Set(own.map(\.ref))
        return own + others.filter { !known.contains($0.ref) }
    }
}

/// Your last change to a pull request's stage, for Undo: the stage you'd set before it, and what you set.
package struct StageChange: Equatable, Sendable {
    package enum Outcome: Equatable, Sendable {
        case done
        case unchanged
        /// Why it couldn't be.
        case refused(String)
    }

    package var ref: ItemRef
    /// The stage you'd set before, which Undo puts back; nil when you'd set none.
    package var before: StageMark?
    /// What you set; nil for Let BriefBar Decide.
    package var after: PullRequestStage?

    /// "Moved !4093 to Teammate's review".
    package var words: String {
        StageText.moved(ref, to: after)
    }
}
