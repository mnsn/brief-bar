import BriefBarCore
import Combine
import Foundation

/// Pull Request Order: which pull requests go together, as missions, and the order they merge in, for the Pull Requests
/// pages to list By Mission. It's made of what each source that's on tells it it shows now (`publish`), and of the orders
/// Copilot sessions told BriefBar through its agents' tools, which `--mcp` keeps in BriefBar's preferences and tells the app
/// it changed (`AgentChanges`). It's off until you turn it on (`PullRequestOrderSetting`): until then it reads nothing, not
/// even the orders it kept, and the sources tell it nothing. Turned off, it shows nothing again, and keeps the orders, what
/// it saw become of their pull requests, the mission you focus on and the names you gave missions, unused, until you
/// forget them. A mission is called by the name you gave it, else the one Apple Intelligence gave it on this Mac while By
/// Mission showed it (`MissionNamer`), else the one BriefBar gives it from its sources.
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
    /// The mission whose name you're editing in its header, while you are: Escape cancels that, rather than closing the
    /// details beside the list.
    @Published package var renaming: MissionKey?
    /// The names you gave missions: none while it's off. It says it changed when a name did, not as their time counts.
    package private(set) var names = MissionNames()
    /// The names Apple Intelligence gave missions, in memory only; in the demo, made-up ones.
    @Published package private(set) var modelNames: [MissionKey: String] = [:]
    /// Asks Apple Intelligence for missions' names: only the app's, never the demo's or `--render`'s.
    package var namer: MissionNamer? {
        didSet {
            namer?.named = { [weak self] key, name in self?.modelNamed(key, name) }
        }
    }

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
    /// When it last counted the time against the names you gave missions, while it's on.
    private var namesCounted: Date?
    /// The missions By Mission shows now, by the views that show them, the first to show first, with the window's page each
    /// is on, when it's on one.
    private var shown: [(viewer: WeakViewer, keys: [MissionKey], page: String?)] = []
    /// The windows' pages on screen now that can list pull requests By Mission, as their sources say (`setVisible`).
    private var visiblePages: Set<String> = []

    /// How often it looks at the time, for what time alone changes: an order that hasn't changed for 30 days shows as stale,
    /// and one that finished goes two weeks later, whether or not the sources show anything new meanwhile.
    package static let timeCheckInterval: TimeInterval = 3_600

    /// What a source told: its pull requests and sessions, how its things look, for what shows them, what each of its
    /// sessions told BriefBar it works on, which the Map shows, and whether it reads the stories its pull requests are for.
    private struct Told {
        var pullRequests: [OrderPullRequest]
        var sessions: [OrderSession]
        var items: [ItemRef: LinkedItem]
        var working: [ItemRef: [ItemRef]] = [:]
        var readsStories = false
    }

    private struct WeakViewer {
        weak var object: AnyObject?
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
    /// requests, the mission you focus on, or a name you gave a mission.
    package var keepsAnything: Bool {
        [DeclaredOrders.defaultsKey, OrderEvidence.defaultsKey, OrderFocus.defaultsKey, MissionNames.defaultsKey]
            .contains { defaults.object(forKey: $0) != nil }
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
            names = MissionNames()
            namesCounted = nil
            modelNames = [:]
            namer?.stop()
            missions = []
        }
    }

    private func load() {
        orders = DeclaredOrders.load(from: defaults)
        evidence = OrderEvidence.load(from: defaults)
        focus = OrderFocus.load(from: defaults)
        names = MissionNames.load(from: defaults)
        namesCounted = nil
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
    /// (`SessionUpdates`), which changes no mission, and whether it reads the stories its pull requests are for. It replaces
    /// what the source told before. Nothing's kept while Pull Request Order is off.
    package func publish(
        _ source: SourceID, pullRequests: [OrderPullRequest] = [], sessions: [OrderSession] = [], items: [LinkedItem] = [],
        working: [ItemRef: [ItemRef]] = [:], readsStories: Bool = false
    ) {
        guard isOn else { return }
        var byRef: [ItemRef: LinkedItem] = [:]
        for item in items where byRef[item.ref] == nil {
            byRef[item.ref] = item
        }
        let new = Told(pullRequests: pullRequests, sessions: sessions, items: byRef, working: working, readsStories: readsStories)
        let old = told[source]
        let sameFacts = old?.pullRequests == new.pullRequests && old?.sessions == new.sessions && old?.readsStories == new.readsStories
        guard !sameFacts || old?.items != new.items || old?.working != new.working else { return }
        objectWillChange.send()
        told[source] = new
        if !sameFacts {
            rebuild()
        } else {
            // What missions are named from, such as a title.
            askNames()
        }
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
    /// saw become of them, and the mission you focus on and the names you gave missions, when they're theirs.
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
        let plans = Set(orders.plans.map(\.id))
        var names = MissionNames.load(from: defaults)
        if names.forget(kinds, keepingPlans: plans) { names.save(to: defaults) }
        if isOn {
            // Before the source goes, whose rebuild would otherwise save what was forgotten again, such as a name.
            objectWillChange.send()
            self.orders = orders
            self.evidence = evidence
            self.focus = kept
            self.names = names
            let forgets = { (key: MissionKey) in MissionNames.forgets(key, kinds: kinds, keepingPlans: plans) }
            modelNames = modelNames.filter { !forgets($0.key) }
            namer?.forget(where: forgets)
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

    /// Forget All Orders: every order, what BriefBar saw become of their pull requests, the mission you focus on and the
    /// names you gave missions, whether Pull Request Order is on or not.
    package func forgetAll() {
        objectWillChange.send()
        DeclaredOrders.forgetAll(in: defaults)
        orders = DeclaredOrders()
        evidence = OrderEvidence()
        focus = nil
        names = MissionNames()
        rebuild()
    }

    /// The demo's orders, as if its sessions had told them, unless it has them, with what BriefBar saw become of their pull
    /// requests before, the mission you focus on, and the names Apple Intelligence would give missions, made up: only in
    /// the demo, while it's on.
    package func tellDemo(
        _ demo: DeclaredOrders, evidence seen: OrderEvidence = OrderEvidence(), focus key: MissionKey? = nil,
        names madeUp: [MissionKey: String] = [:]
    ) {
        guard isDemo, isOn else { return }
        for (key, name) in madeUp where modelNames[key] == nil {
            modelNames[key] = name
        }
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

    // MARK: Missions' names

    /// Who named a mission, for its help.
    package enum Naming: Equatable {
        case you
        case appleIntelligence
        case briefBar
    }

    /// What a mission is called: the name you gave it, else the one Apple Intelligence gave it, else BriefBar's own.
    package func title(of mission: OrderMission) -> String {
        names.name(for: mission.key) ?? briefBarsName(of: mission)
    }

    /// What it's called without your name: Apple Intelligence's, while it has an Azure DevOps pull request, else the name
    /// BriefBar gives it from its sources (`OrderText.title`). Use BriefBar's Name gives it this.
    package func briefBarsName(of mission: OrderMission) -> String {
        modelName(of: mission) ?? OrderText.title(of: mission, name: name(of:))
    }

    /// Who named it: you, else Apple Intelligence while its name is the one it has, though it kept BriefBar's own, as it's
    /// asked to while that fits, else BriefBar.
    package func naming(of mission: OrderMission) -> Naming {
        if names.name(for: mission.key) != nil { return .you }
        return modelName(of: mission) != nil ? .appleIntelligence : .briefBar
    }

    /// The name Apple Intelligence gave it, while it has an Azure DevOps pull request.
    private func modelName(of mission: OrderMission) -> String? {
        guard !MissionNaming.pullRequests(of: mission).isEmpty else { return nil }
        return modelNames[mission.key]
    }

    /// Whether Rename… can give it a name: it has one of yours, or BriefBar keeps fewer than it can.
    package func canRename(_ key: MissionKey) -> Bool {
        names.name(for: key) != nil || !names.isFull
    }

    /// Rename…: what you typed becomes its name, as you typed it; nothing, or BriefBar's name for it, gives it BriefBar's
    /// name again, and keeps nothing. At the cap, it keeps none. Never logged.
    /// - Parameter shown: what the field started with: left as it was, it changes nothing, though Apple Intelligence named
    ///   the mission meanwhile.
    @discardableResult
    package func rename(_ mission: OrderMission, to typed: String, from shown: String? = nil) -> MissionNames.Outcome {
        guard isOn else { return .unchanged }
        if let shown, MissionNames.cleaned(typed) == MissionNames.cleaned(shown) { return .unchanged }
        var names = self.names
        let outcome = names.rename(mission.key, to: typed, briefBarsName: briefBarsName(of: mission))
        guard names != self.names else { return outcome }
        objectWillChange.send()
        self.names = names
        names.save(to: defaults)
        askNames()
        return outcome
    }

    /// Use BriefBar's Name: forgets the name you gave it.
    package func useBriefBarsName(_ key: MissionKey) {
        guard isOn, names.name(for: key) != nil else { return }
        objectWillChange.send()
        names.clear(key)
        names.save(to: defaults)
        askNames()
    }

    /// By Mission shows these missions now, in this view, the first first: Apple Intelligence names them as they settle,
    /// while the window's page the view is on is on screen.
    /// - Parameter page: the window's page it's on (`page(_:window:)`); nil outside a window's page, where nothing it shows
    ///   is named, as nothing says it's on screen.
    package func showing(_ keys: [MissionKey], in viewer: AnyObject, on page: String? = nil) {
        if let index = shown.firstIndex(where: { $0.viewer.object === viewer }) {
            guard shown[index].keys != keys || shown[index].page != page else { return }
            shown[index].keys = keys
            shown[index].page = page
        } else {
            shown.append((WeakViewer(object: viewer), keys, page))
        }
        askNames()
    }

    /// That view no longer shows By Mission.
    package func stopShowing(in viewer: AnyObject) {
        guard let index = shown.firstIndex(where: { $0.viewer.object === viewer }) else { return }
        shown.remove(at: index)
        askNames()
    }

    /// What a window's page is called here: the section it shows, in that window, by the ID its `SectionViewer` has.
    package nonisolated static func page(_ section: SectionID, window: String) -> String {
        "\(section.rawValue) in window \(window)"
    }

    /// A window started or stopped showing, on screen, a page that can list pull requests By Mission, as its source says
    /// (`sectionVisibilityChanged`): minimized, hidden or covered, the missions it shows aren't named until it shows again.
    package func setVisible(_ visible: Bool, for page: String) {
        if visible {
            guard visiblePages.insert(page).inserted else { return }
        } else {
            guard visiblePages.remove(page) != nil else { return }
        }
        askNames()
    }

    /// The missions By Mission shows on screen now, in all its views, the first first: those Apple Intelligence names. A
    /// view counts only while a window shows its page on screen; one that isn't on a window's page never does.
    package var onScreen: [MissionKey] {
        var keys: [MissionKey] = []
        for view in shown where view.viewer.object != nil && view.page.map(visiblePages.contains) ?? false {
            for key in view.keys where !keys.contains(key) { keys.append(key) }
        }
        return keys
    }

    /// Asks Apple Intelligence to name the missions on screen that you didn't name, from what they're made of now.
    private func askNames() {
        guard let namer else { return }
        shown.removeAll { $0.viewer.object == nil }
        guard isOn else {
            namer.stop()
            return
        }
        let facts = facts
        let requests = onScreen.compactMap { key -> MissionNamer.Request? in
            guard names.name(for: key) == nil, let mission = missions.first(where: { $0.key == key }),
                  let inputs = MissionNaming.inputs(
                      for: mission, named: modelName(of: mission), stories: { facts.pullRequests[$0]?.stories ?? [] },
                      workItems: { facts.pullRequests[$0]?.workItems ?? [] }, sessionsWorking: sessionsWorking(on:),
                      name: name(of:)
                  )
            else { return nil }
            return MissionNamer.Request(key: key, inputs: inputs, isSettled: MissionNaming.isSettled(mission, facts: facts))
        }
        namer.update(requests)
    }

    private func modelNamed(_ key: MissionKey, _ name: String) {
        guard isOn, modelNames[key] != name else { return }
        modelNames[key] = name
    }

    // MARK: Missions

    /// What the sources that are on show now.
    private var facts: OrderFacts {
        let sources = SourceID.allCases.filter { told[$0] != nil }
        return OrderFacts(
            pullRequests: sources.flatMap { told[$0]?.pullRequests ?? [] },
            sessions: sources.flatMap { told[$0]?.sessions ?? [] },
            sourcesOn: Set(sources.flatMap(ItemRef.Kind.of).filter(\.isPullRequest)),
            readsStories: sources.contains { told[$0]?.readsStories == true }
        )
    }

    /// The kinds of thing whose source is on and tells it what it shows.
    private var kindsOn: Set<ItemRef.Kind> {
        Set(SourceID.allCases.filter { told[$0] != nil }.flatMap(ItemRef.Kind.of))
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
        var missions = OrderBoard.missions(facts: facts, orders: orders, evidence: evidence, focus: focus, now: date)
        // Focus follows the mission you focus on as its key changes: to its pull requests' story's, or a chain's whose
        // earliest left. Else it waits, as ever.
        if let focus, let next = OrderBoard.successor(of: focus, from: self.missions, to: missions) {
            self.focus = next
            OrderFocus.save(next, to: defaults)
            missions = OrderBoard.missions(facts: facts, orders: orders, evidence: evidence, focus: next, now: date)
        }
        keepNames(following: missions, facts: facts, at: date)
        forgetModelNames(keepingPlans: Set(orders.plans.map(\.id)))
        if missions != self.missions { self.missions = missions }
        askNames()
    }

    /// Apple Intelligence's names of orders BriefBar no longer keeps go, with what it was asked of them, as yours do,
    /// however the orders went: forgotten, finished, or left with no pull request as a source was turned off.
    private func forgetModelNames(keepingPlans plans: Set<UUID>) {
        let forgets = { (key: MissionKey) in MissionNames.forgets(key, kinds: [], keepingPlans: plans) }
        if modelNames.keys.contains(where: forgets) { modelNames = modelNames.filter { !forgets($0.key) } }
        namer?.forget(where: forgets)
    }

    /// The names you gave missions, as the missions change: each follows its mission as Focus does, those of orders BriefBar
    /// no longer keeps go, and the time since BriefBar last saw a mission counts against its name while BriefBar could
    /// see it, at most two hours at a time, as when the Mac slept.
    private func keepNames(following missions: [OrderMission], facts: OrderFacts, at date: Date) {
        var names = self.names
        var renamed = false
        for key in names.entries.keys.sorted(by: { $0.description < $1.description }) {
            if let next = OrderBoard.successor(of: key, from: self.missions, to: missions), names.follow(key, to: next) { renamed = true }
        }
        let plans = Set(orders.plans.map(\.id))
        if names.forget([], keepingPlans: plans) { renamed = true }
        let elapsed = namesCounted.map { min(max(date.timeIntervalSince($0), 0), 2 * Self.timeCheckInterval) } ?? 0
        namesCounted = date
        let kindsOn = kindsOn
        let before = names.entries.count
        let changed = names.account(shown: Set(missions.map(\.key)), canSee: { key in
            MissionNames.canSee(key, plans: plans, kindsOn: kindsOn, readsStories: facts.readsStories)
        }, elapsed: elapsed)
        if names.entries.count != before { renamed = true }
        if renamed { objectWillChange.send() }
        self.names = names
        if renamed || changed { names.save(to: defaults) }
    }
}
