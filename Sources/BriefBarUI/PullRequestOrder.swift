import BriefBarCore
import Combine
import Foundation

/// Pull Request Order: which pull requests go together, as missions, and the order they merge in, for the Pull Requests
/// pages to list By Mission. It's made of what each source that's on tells it it shows now (`publish`), of the orders
/// Copilot sessions told BriefBar through its agents' tools, which `--mcp` keeps in BriefBar's preferences and tells the app
/// it changed (`AgentChanges`), and of your changes to missions (`OrderChanges`), which only the app writes. It's off until
/// you turn it on (`PullRequestOrderSetting`): until then it reads nothing, not even the orders it kept, and the sources tell
/// it nothing. Turned off, it shows nothing again, and keeps the orders, what it saw become of their pull requests, the
/// mission you focus on and your changes, unused, until you forget them.
@MainActor
package final class PullRequestOrder: ObservableObject {
    @Published package private(set) var isOn: Bool
    /// The missions, as By Mission lists them (`OrderBoard.missions`): none while it's off.
    @Published package private(set) var missions: [OrderMission] = []
    /// The mission you keep on top: none while it's off.
    @Published package private(set) var focus: MissionKey?
    /// The orders sessions told BriefBar: none while it's off.
    @Published package private(set) var orders = DeclaredOrders()
    /// Your changes to missions, those kept in memory included: none while it's off.
    @Published package private(set) var changes = OrderChanges()
    /// Your last change, for its Undo line, until your next one or until you dismiss it; or why BriefBar didn't make it.
    @Published package private(set) var lastChange: OrderLastChange?
    /// By Mission's view, List or Map, on both Pull Requests pages.
    @Published package private(set) var view: OrderView
    /// The mission a row's capsule asked By Mission to show, until it has.
    @Published package var revealed: MissionKey?

    private let defaults: UserDefaults
    private let isDemo: Bool
    private let now: () -> Date
    /// What BriefBar saw become of the pull requests that orders and your changes name, and of the one you focus on.
    private var evidence = OrderEvidence()
    /// Your changes about pull requests listed only because someone sent them in a chat, which never go to the
    /// preferences: kept while BriefBar runs, Pull Request Order off or on.
    private var changesInMemory = OrderChanges()
    /// What BriefBar saw become of the pull requests that only those changes name, kept in memory as they are.
    private var evidenceInMemory = OrderEvidence()
    /// The pull requests a source said it lists only because someone sent them in a chat, while BriefBar runs, until one
    /// lists them otherwise, as yours or one you watch: one that leaves the lists, merged or closed, stays here.
    private var sentInChats: Set<ItemRef> = []
    /// What each source told it last.
    private var told: [SourceID: Told] = [:] {
        didSet { cachedNames = nil }
    }
    /// `names`, until the sources or the missions change.
    private var cachedNames: OrderNames?
    /// What BriefBar sees each pull request stacked on, as the missions were last made: what your changes can't go against.
    private var stacked: [ItemRef: Set<ItemRef>] = [:]
    /// Hears about the orders an agent tells or forgets through `--mcp`, while it's on.
    private var agentChanges: AnyObject?
    /// Looks at the time every hour, while it's on (`timePassed`).
    private var clock: Timer?

    /// How often it looks at the time, for what time alone changes: an order that hasn't changed for 30 days shows as stale,
    /// and one that finished goes two weeks later, whether or not the sources show anything new meanwhile.
    package static let timeCheckInterval: TimeInterval = 3_600

    /// What a source told: its pull requests and sessions, how its things look, for what shows them, what each of its
    /// sessions told BriefBar it works on, which the Map shows, and which of its pull requests it lists only because
    /// someone sent them in a chat.
    private struct Told {
        var pullRequests: [OrderPullRequest]
        var sessions: [OrderSession]
        var items: [ItemRef: LinkedItem]
        var working: [ItemRef: [ItemRef]] = [:]
        var inMemory: Set<ItemRef> = []
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
        if isOn { load() }
    }

    /// List or Map, remembered for both pages.
    package func setView(_ view: OrderView) {
        guard view != self.view else { return }
        self.view = view
        view.save(to: defaults)
    }

    /// Asks By Mission to show a mission, as clicking a row's capsule does.
    package func reveal(_ key: MissionKey) {
        revealed = key
    }

    /// Whether BriefBar keeps anything for Pull Request Order, on or off: an order, what it saw become of their pull
    /// requests, the mission you focus on, or a change of yours.
    package var keepsAnything: Bool {
        !changesInMemory.isEmpty || !evidenceInMemory.records.isEmpty || [DeclaredOrders.defaultsKey, OrderEvidence.defaultsKey, OrderFocus.defaultsKey, OrderChanges.defaultsKey]
            .contains { defaults.object(forKey: $0) != nil }
    }

    /// Pull Request Order, in Settings. On, it reads the orders and changes it kept, and the sources tell it what they show;
    /// off, it forgets all that, in memory only.
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
            changes = OrderChanges()
            lastChange = nil
            missions = []
        }
    }

    private func load() {
        orders = DeclaredOrders.load(from: defaults)
        evidence = OrderEvidence.load(from: defaults).merging(evidenceInMemory)
        focus = OrderFocus.load(from: defaults)
        changes = OrderChanges.load(from: defaults).merging(changesInMemory)
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

    /// Looks again at what time alone changes, as its clock does every hour: orders that went stale, and those that
    /// finished long enough ago to go.
    package func timePassed() {
        guard isOn else { return }
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
    /// (`SessionUpdates`), which changes no mission, and the pull requests it lists only because someone sent them in a
    /// chat, whose changes stay in memory. It replaces what the source told before. Nothing's kept while Pull Request Order
    /// is off.
    package func publish(
        _ source: SourceID, pullRequests: [OrderPullRequest] = [], sessions: [OrderSession] = [], items: [LinkedItem] = [],
        working: [ItemRef: [ItemRef]] = [:], inMemory: Set<ItemRef> = []
    ) {
        guard isOn else { return }
        var byRef: [ItemRef: LinkedItem] = [:]
        for item in items where byRef[item.ref] == nil {
            byRef[item.ref] = item
        }
        let new = Told(pullRequests: pullRequests, sessions: sessions, items: byRef, working: working, inMemory: inMemory)
        let old = told[source]
        let sameFacts = old?.pullRequests == new.pullRequests && old?.sessions == new.sessions
        guard !sameFacts || old?.items != new.items || old?.working != new.working || old?.inMemory != new.inMemory else { return }
        objectWillChange.send()
        told[source] = new
        sentInChats.formUnion(inMemory)
        sentInChats.subtract(Set(pullRequests.map(\.ref)).subtracting(inMemory))
        if old?.inMemory != new.inMemory || !sameFacts { keep(changes) }
        if !sameFacts { rebuild() }
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
    /// saw become of them, your changes to them and those that put pull requests in its missions, and the mission you focus
    /// on, when it's theirs.
    package func forget(_ source: SourceID) {
        let kinds = ItemRef.Kind.of(source)
        guard !kinds.isEmpty else { return }
        var orders = DeclaredOrders.load(from: defaults)
        let before = orders
        orders.forget(kinds)
        if orders != before { orders.save(to: defaults) }
        var evidence = OrderEvidence.load(from: defaults)
        if evidence.forget(kinds) { evidence.save(to: defaults) }
        evidenceInMemory.forget(kinds)
        evidence = evidence.merging(evidenceInMemory)
        sentInChats = sentInChats.filter { !kinds.contains($0.kind) }
        var saved = OrderChanges.load(from: defaults)
        if saved.forget(kinds) { saved.save(to: defaults) }
        changesInMemory.forget(kinds)
        let changes = saved.merging(changesInMemory)
        let focus = OrderFocus.load(from: defaults)
        let kept = OrderFocus.kept(focus, in: orders, changes: changes, forgetting: kinds)
        if kept != focus { OrderFocus.save(kept, to: defaults) }
        // What's left goes in before the source's pull requests leave the missions, so that rebuilding then, which can save
        // what it keeps, saves none of what was forgotten back.
        if isOn {
            objectWillChange.send()
            self.orders = orders
            self.evidence = evidence
            self.changes = changes
            self.focus = kept
            lastChange = nil
        }
        withdraw(source)
        guard isOn else { return }
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

    /// Forget This Order: BriefBar no longer shows it, and an agent that names it is told so. The pull requests you put in
    /// it stay together, as a mission of yours.
    package func forget(order id: UUID) {
        guard isOn else { return }
        var orders = DeclaredOrders.load(from: defaults)
        guard orders.plan(id) != nil else { return }
        orders.forget(id)
        orders.save(to: defaults)
        self.orders = orders
        let kept = OrderFocus.kept(focus, in: orders, changes: changes)
        if kept != focus {
            focus = kept
            OrderFocus.save(kept, to: defaults)
        }
        rebuild()
    }

    /// Forget All Orders: every order, what BriefBar saw become of their pull requests, the mission you focus on, and your
    /// changes to missions, whether Pull Request Order is on or not.
    package func forgetAll() {
        objectWillChange.send()
        DeclaredOrders.forgetAll(in: defaults)
        orders = DeclaredOrders()
        evidence = OrderEvidence()
        evidenceInMemory = OrderEvidence()
        focus = nil
        changes = OrderChanges()
        changesInMemory = OrderChanges()
        lastChange = nil
        rebuild()
    }

    /// The demo's orders, as if its sessions had told them, unless it has them, with what BriefBar saw become of their pull
    /// requests before, the mission you focus on and your made-up changes to its missions: only in the demo, while it's on.
    package func tellDemo(
        _ demo: DeclaredOrders, evidence seen: OrderEvidence = OrderEvidence(), focus key: MissionKey? = nil,
        changes made: OrderChanges = OrderChanges()
    ) {
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
        if changes.isEmpty, !made.isEmpty { keep(made) }
        rebuild()
    }

    /// What a source calls a session or a pull request, when one that's on says.
    package func name(of ref: ItemRef) -> String? {
        describe(ref)?.title
    }

    // MARK: Your changes to missions

    /// What a pull request's Mission menu offers now.
    /// - Parameter mission: the mission whose card it's in, where it's in two.
    package func choices(for ref: ItemRef, in mission: MissionKey? = nil) -> MissionChoices {
        MissionChoices.of(ref, in: mission, missions: missions, changes: changes, orders: orders, stacked: stacked)
    }

    /// How many of your changes Undo Your Changes to This Mission takes back: to its pull requests, those you put in it and
    /// those you moved out of it.
    package func changes(in mission: OrderMission) -> Int {
        let refs = Set(mission.steps.map(\.ref) + mission.attached.map(\.ref))
        return changes.all.filter { refs.contains($0.ref) || $0.placement == .into(mission.key) || $0.from == mission.key }.count
    }

    /// What names sessions, pull requests and missions in the order's words, as the sources say now, and the time: worked
    /// out again once they change.
    package var names: OrderNames {
        if let cachedNames { return cachedNames }
        var titles: [ItemRef: String] = [:]
        for source in SourceID.allCases {
            for (ref, item) in told[source]?.items ?? [:] where titles[ref] == nil {
                titles[ref] = item.title
            }
        }
        let named = titles
        var missionTitles: [MissionKey: String] = [:]
        for mission in missions where missionTitles[mission.key] == nil {
            missionTitles[mission.key] = OrderText.title(of: mission) { named[$0] }
        }
        let titled = missionTitles
        let names = OrderNames(name: { named[$0] }, title: { titled[$0] }, now: now())
        cachedNames = names
        return names
    }

    /// Changes a mission as you asked, from a pull request's Mission menu or a mission's ⋯, and says what you did, for its
    /// Undo line and for VoiceOver; or, refused, why, and changes nothing. Nil when there was nothing to change.
    @discardableResult
    package func change(_ edit: OrderEdit) -> OrderLastChange? {
        guard isOn else { return nil }
        let before = Set(missions.map(\.key))
        var changed = changes
        let touched: [ItemRef: OrderChange?]
        do {
            touched = try changed.apply(edit, missions: missions, orders: orders, stacked: stacked, now: now())
        } catch {
            let refusal = OrderLastChange(
                said: "\(error)", refs: edit.refs, mission: cardMission(for: edit), touched: [:], evidence: OrderEvidence()
            )
            lastChange = refusal
            return refusal
        }
        guard !touched.isEmpty else { return nil }
        // What BriefBar saw become of the pull requests the changes it touched were about, which can go with them, for Undo
        // to put back.
        var seen = evidence
        seen.keep(only: OrderChanges(touched.values.compactMap { $0 }).subjects)
        keep(changed)
        rebuild()
        var made = false
        if case .move(_, .into(let key), _) = edit, case .mine = key { made = !before.contains(key) }
        let last = OrderLastChange(
            said: OrderText.did(edit, names: names, newMission: made), refs: edit.refs, mission: cardMission(for: edit), touched: touched,
            evidence: seen
        )
        lastChange = last
        return last
    }

    /// Undo: puts back exactly what your last change touched.
    @discardableResult
    package func undoLastChange() -> Bool {
        guard isOn, let last = lastChange, last.canUndo else { return false }
        var changed = changes
        changed.restore(last.touched)
        lastChange = nil
        evidence = evidence.merging(last.evidence)
        keep(changed)
        rebuild()
        return true
    }

    /// × beside the Undo line: it goes, and your change stays.
    package func dismissLastChange() {
        lastChange = nil
    }

    /// The mission whose card shows what an edit did: the one you changed it in, else where its pull request is now, else
    /// where it was.
    private func cardMission(for edit: OrderEdit) -> MissionKey? {
        switch edit {
        case .undoMission(let key):
            return missions.contains { $0.key == key } ? key : nil
        case .setNext(_, let key, _), .mergeAfter(_, _, let key, _):
            if missions.contains(where: { $0.key == key }) { return key }
        case .move, .undo, .putBack:
            break
        }
        if let ref = edit.refs.first, let mission = OrderBoard.mission(of: ref, in: missions) { return mission.key }
        if case .move(_, _, let from?) = edit, missions.contains(where: { $0.key == from }) { return from }
        return nil
    }

    /// Keeps your changes: in the preferences, but those about a pull request listed only because someone sent it in a
    /// chat, which stay in memory, as what you saw of it does, until BriefBar lists each of its pull requests otherwise.
    private func keep(_ all: OrderChanges) {
        let (inMemory, saved) = all.split { !$0.named.isDisjoint(with: sentInChats) }
        if saved != OrderChanges.load(from: defaults) { saved.save(to: defaults) }
        changesInMemory = inMemory
        if all != changes { changes = all }
        keepEvidence()
    }

    /// Keeps what BriefBar saw become of pull requests: in the preferences, but what only your changes kept in memory name,
    /// which stays in memory with them, wherever they go.
    private func keepEvidence() {
        let focused = focus.flatMap(OrderFocus.ref(of:)).map { [$0] } ?? []
        var saved = evidence
        saved.keep(only: orders.refs.union(changes.split { changesInMemory[$0.ref] != nil }.rest.subjects).union(focused))
        var inMemory = evidence
        inMemory.keep(only: Set(evidence.records.keys).subtracting(saved.records.keys))
        evidenceInMemory = inMemory
        if saved != OrderEvidence.load(from: defaults) { saved.save(to: defaults) }
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

    /// The missions again, from what the sources show, the orders and your changes: first keeping what the sources show
    /// become of the pull requests that orders or your changes name, or that you focus on, and forgetting the orders and
    /// changes that finished long enough ago; then moving a chain you put pull requests in on to another of its pull
    /// requests, as the one it's named by ends.
    private func rebuild() {
        guard isOn else {
            if !missions.isEmpty { missions = [] }
            stacked = [:]
            return
        }
        let date = now()
        let facts = facts
        stacked = OrderBoard.stacked(facts)
        let focused = focus.flatMap(OrderFocus.ref(of:))
        // What an order changed since one of your changes, as BriefBar sees it: that change doesn't hold anymore, though the
        // order changes back, until you put yours back.
        var noted = changes
        if noted.noteOverrides(in: orders, now: date) { keep(noted) }
        let subjects = changes.subjects
        var evidence = evidence
        for observation in facts.observations
        where orders.refs.contains(observation.ref) || observation.ref == focused || subjects.contains(observation.ref) {
            evidence.observe(observation, at: date)
        }
        let finished = orders.removeFinished(evidence: evidence, now: date)
        if !finished.isEmpty {
            // As the preferences have them, with what an agent told since.
            var saved = DeclaredOrders.load(from: defaults)
            for id in finished { saved.forget(id) }
            saved.save(to: defaults)
            orders = saved
        }
        var changes = changes
        if !changes.removeFinished(evidence: evidence, now: date).isEmpty { keep(changes) }
        // The mission you focus on goes once its order finished, or, for one of your own, once no change of yours puts a
        // pull request in it, as Undo or time can take them.
        var isMine = false
        if case .mine? = focus { isMine = true }
        if !finished.isEmpty || isMine {
            let kept = OrderFocus.kept(focus, in: orders, changes: self.changes)
            if kept != focus {
                focus = kept
                OrderFocus.save(kept, to: defaults)
            }
        }
        let focusedRefs = focus.flatMap(OrderFocus.ref(of:)).map { [$0] } ?? []
        evidence.keep(only: orders.refs.union(self.changes.subjects).union(focusedRefs))
        if evidence != self.evidence {
            self.evidence = evidence
            keepEvidence()
        }
        var missions = OrderBoard.missions(
            facts: facts, orders: orders, evidence: evidence, focus: focus, changes: self.changes, now: date
        )
        var anchored = self.changes
        let pending = OrderChanges(lastChange?.touched.values.compactMap { $0 } ?? [])
        let renamed = anchored.moveAnchors(in: missions, alsoFor: pending)
        if !renamed.isEmpty {
            // What Undo would put back names those chains as they're named now too, though no change of yours names them.
            if let last = lastChange { lastChange = last.renamingChains(renamed) }
            if anchored != self.changes {
                keep(anchored)
                missions = OrderBoard.missions(
                    facts: facts, orders: orders, evidence: evidence, focus: focus, changes: self.changes, now: date
                )
            }
        }
        cachedNames = nil
        if missions != self.missions { self.missions = missions }
    }
}

/// Your last change to a mission, for its Undo line until your next one or until you dismiss it, in memory only; or why
/// BriefBar didn't make it.
package struct OrderLastChange: Equatable {
    /// What you did, "You set !4079 as next to merge", or why BriefBar didn't.
    package let said: String
    /// The pull requests it was about.
    package let refs: [ItemRef]
    /// The mission whose card shows it: where its pull request is now, else where it was.
    package let mission: MissionKey?
    /// What it touched, as it was, for Undo; empty for one BriefBar refused.
    package let touched: [ItemRef: OrderChange?]
    /// What BriefBar saw become of the pull requests those were about, as it was, for Undo to put back with them.
    package let evidence: OrderEvidence

    /// Whether it was made, and Undo can put back what it touched.
    package var canUndo: Bool { !touched.isEmpty }

    /// The same, with the chains it names named as `OrderChanges.moveAnchors` renamed them.
    func renamingChains(_ renamed: [ItemRef: ItemRef]) -> OrderLastChange {
        var undo = OrderChanges(touched.values.compactMap { $0 })
        undo.renameChains(renamed)
        var mission = mission
        if case .chain(let anchor)? = mission, let new = renamed[anchor] { mission = .chain(new) }
        return OrderLastChange(
            said: said, refs: refs, mission: mission, touched: touched.mapValues { change in change.map { undo[$0.ref] ?? $0 } },
            evidence: evidence
        )
    }
}
