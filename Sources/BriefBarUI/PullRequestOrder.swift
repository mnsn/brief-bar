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
    /// By Mission's view, List or Map, on both Pull Requests pages.
    @Published package private(set) var view: OrderView
    /// The mission a row's capsule asked By Mission to show, until it has.
    @Published package var revealed: MissionKey?

    private let defaults: UserDefaults
    private let isDemo: Bool
    private let now: () -> Date
    /// What BriefBar saw become of the pull requests that orders name, and of the one you focus on.
    private var evidence = OrderEvidence()
    /// What each source told it last.
    private var told: [SourceID: Told] = [:]
    /// Hears about the orders an agent tells or forgets through `--mcp`, while it's on.
    private var agentChanges: AnyObject?
    /// Looks at the time every hour, while it's on (`timePassed`).
    private var clock: Timer?

    /// How often it looks at the time, for what time alone changes: an order that hasn't changed for 30 days shows as stale,
    /// and one that finished goes two weeks later, whether or not the sources show anything new meanwhile.
    package static let timeCheckInterval: TimeInterval = 3_600

    /// What a source told: its pull requests and sessions, and how its things look, for what shows them.
    private struct Told {
        var pullRequests: [OrderPullRequest]
        var sessions: [OrderSession]
        var items: [ItemRef: LinkedItem]
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
        }
    }

    private func load() {
        orders = DeclaredOrders.load(from: defaults)
        evidence = OrderEvidence.load(from: defaults)
        focus = OrderFocus.load(from: defaults)
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
    /// it knows, and how its things look, for what shows them. It replaces what the source told before. Nothing's kept
    /// while Pull Request Order is off.
    package func publish(
        _ source: SourceID, pullRequests: [OrderPullRequest] = [], sessions: [OrderSession] = [], items: [LinkedItem] = []
    ) {
        guard isOn else { return }
        var byRef: [ItemRef: LinkedItem] = [:]
        for item in items where byRef[item.ref] == nil {
            byRef[item.ref] = item
        }
        let new = Told(pullRequests: pullRequests, sessions: sessions, items: byRef)
        let old = told[source]
        let sameFacts = old?.pullRequests == new.pullRequests && old?.sessions == new.sessions
        guard !sameFacts || old?.items != new.items else { return }
        objectWillChange.send()
        told[source] = new
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
    /// saw become of them, and the mission you focus on, when it's theirs.
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
        withdraw(source)
        guard isOn else { return }
        self.orders = orders
        self.evidence = evidence
        self.focus = kept
        rebuild()
    }

    /// How a source says one of its things looks, and what opening or showing it does; nil when no source that's on says.
    package func describe(_ ref: ItemRef) -> LinkedItem? {
        for source in SourceID.allCases {
            if let item = told[source]?.items[ref] { return item }
        }
        return nil
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
    }
}
