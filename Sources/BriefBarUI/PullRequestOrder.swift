import BriefBarCore
import Combine
import Foundation

/// Pull Request Order: which pull requests go together, as missions, and the order they merge in, for the Pull Requests
/// pages to list By Mission. It's made of what each source that's on tells it it shows now (`publish`), of the orders
/// Copilot sessions told BriefBar through its agents' tools, which `--mcp` keeps in BriefBar's preferences and tells the app
/// it changed (`AgentChanges`), and of your changes to missions (`OrderChanges`), which only the app writes. It's off until
/// you turn it on (`PullRequestOrderSetting`): until then it reads nothing, not even the orders it kept, and the sources tell
/// it nothing. Turned off, it shows nothing again, and keeps the orders, what it saw become of their pull requests, the
/// mission you focus on, your changes and the names you gave missions, unused, until you forget them. A mission is called
/// by the name you gave it, else the one Apple Intelligence gave it on this Mac while By Mission showed it
/// (`MissionNamer`), else the one BriefBar gives it from its sources.
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
    /// Your last change, for its Undo line, until your next one or until you dismiss it.
    @Published package private(set) var lastChange: OrderLastChange?
    /// Why BriefBar didn't make the change you asked for last, beside your last change's Undo, which stays: until your next
    /// change, Undo, or you dismiss it.
    @Published package private(set) var refusal: OrderLastChange?
    /// By Mission's view, List or Map, on both Pull Requests pages.
    @Published package private(set) var view: OrderView
    /// The mission a row's capsule asked By Mission to show, until it has.
    @Published package var revealed: MissionKey?
    /// The mission whose name you're editing in its header, while you are: Escape cancels that, rather than closing the
    /// details beside the list.
    @Published package var renaming: MissionKey?
    /// The names you gave missions: none while it's off. It says it changed when a name did, not as their time counts.
    package private(set) var yourNames = MissionNames()
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
    /// `names`, but the time, until the sources or the missions change.
    private var cachedNames: OrderNames?
    /// What BriefBar sees each pull request stacked on, as the missions were last made: what your changes can't go against.
    private var stacked: [ItemRef: Set<ItemRef>] = [:]
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
    /// sessions told BriefBar it works on, which the Map shows, which of its pull requests it lists only because someone
    /// sent them in a chat, and whether it reads the stories its pull requests are for.
    private struct Told {
        var pullRequests: [OrderPullRequest]
        var sessions: [OrderSession]
        var items: [ItemRef: LinkedItem]
        var working: [ItemRef: [ItemRef]] = [:]
        var inMemory: Set<ItemRef> = []
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
    /// requests, the mission you focus on, a change of yours, or a name you gave a mission.
    package var keepsAnything: Bool {
        !changesInMemory.isEmpty || !evidenceInMemory.records.isEmpty
            || [DeclaredOrders.defaultsKey, OrderEvidence.defaultsKey, OrderFocus.defaultsKey, OrderChanges.defaultsKey, MissionNames.defaultsKey]
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
            refusal = nil
            yourNames = MissionNames()
            namesCounted = nil
            modelNames = [:]
            namer?.stop()
            missions = []
        }
    }

    private func load() {
        orders = DeclaredOrders.load(from: defaults)
        evidence = OrderEvidence.load(from: defaults).merging(evidenceInMemory)
        focus = OrderFocus.load(from: defaults)
        changes = OrderChanges.load(from: defaults).merging(changesInMemory)
        yourNames = MissionNames.load(from: defaults)
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
    /// (`SessionUpdates`), which changes no mission, the pull requests it lists only because someone sent them in a chat,
    /// whose changes stay in memory, and whether it reads the stories its pull requests are for. It replaces what the source
    /// told before. Nothing's kept while Pull Request Order is off.
    package func publish(
        _ source: SourceID, pullRequests: [OrderPullRequest] = [], sessions: [OrderSession] = [], items: [LinkedItem] = [],
        working: [ItemRef: [ItemRef]] = [:], inMemory: Set<ItemRef> = [], readsStories: Bool = false
    ) {
        guard isOn else { return }
        var byRef: [ItemRef: LinkedItem] = [:]
        for item in items where byRef[item.ref] == nil {
            byRef[item.ref] = item
        }
        let new = Told(
            pullRequests: pullRequests, sessions: sessions, items: byRef, working: working, inMemory: inMemory, readsStories: readsStories
        )
        let old = told[source]
        let sameFacts = old?.pullRequests == new.pullRequests && old?.sessions == new.sessions && old?.readsStories == new.readsStories
        guard !sameFacts || old?.items != new.items || old?.working != new.working || old?.inMemory != new.inMemory else { return }
        objectWillChange.send()
        told[source] = new
        sentInChats.formUnion(inMemory)
        sentInChats.subtract(Set(pullRequests.map(\.ref)).subtracting(inMemory))
        if old?.inMemory != new.inMemory || !sameFacts { keep(changes) }
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
    /// saw become of them, your changes to them and those that put pull requests in its missions, and the mission you focus
    /// on and the names you gave missions, when they're theirs.
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
        let plans = Set(orders.plans.map(\.id))
        var names = MissionNames.load(from: defaults)
        if names.forget(kinds, keepingPlans: plans, keepingMine: changes.ownMissions) { names.save(to: defaults) }
        // What's left goes in before the source's pull requests leave the missions, so that rebuilding then, which can save
        // what it keeps, saves none of what was forgotten back, such as a name.
        if isOn {
            objectWillChange.send()
            self.orders = orders
            self.evidence = evidence
            self.changes = changes
            self.focus = kept
            lastChange = nil
            refusal = nil
            yourNames = names
            let forgets = { (key: MissionKey) in
                MissionNames.forgets(key, kinds: kinds, keepingPlans: plans, keepingMine: changes.ownMissions)
            }
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

    /// Forget All Orders: every order, what BriefBar saw become of their pull requests, the mission you focus on, your changes
    /// to missions and the names you gave missions, whether Pull Request Order is on or not.
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
        refusal = nil
        yourNames = MissionNames()
        rebuild()
    }

    /// The demo's orders, as if its sessions had told them, unless it has them, with what BriefBar saw become of their pull
    /// requests before, the mission you focus on, your made-up changes to its missions, and the names Apple Intelligence
    /// would give missions, made up: only in the demo, while it's on.
    package func tellDemo(
        _ demo: DeclaredOrders, evidence seen: OrderEvidence = OrderEvidence(), focus key: MissionKey? = nil,
        changes made: OrderChanges = OrderChanges(), names madeUp: [MissionKey: String] = [:]
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
        if changes.isEmpty, !made.isEmpty { keep(made) }
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
        yourNames.name(for: mission.key) ?? briefBarsName(of: mission)
    }

    /// What it's called without your name: Apple Intelligence's, while it has an Azure DevOps pull request, else the name
    /// BriefBar gives it from its sources (`OrderText.title`). Use BriefBar's Name gives it this.
    package func briefBarsName(of mission: OrderMission) -> String {
        modelName(of: mission) ?? OrderText.title(of: mission, name: name(of:))
    }

    /// Who named it: you, else Apple Intelligence while its name is the one it has, though it kept BriefBar's own, as it's
    /// asked to while that fits, else BriefBar.
    package func naming(of mission: OrderMission) -> Naming {
        if yourNames.name(for: mission.key) != nil { return .you }
        return modelName(of: mission) != nil ? .appleIntelligence : .briefBar
    }

    /// The name Apple Intelligence gave it, while it has an Azure DevOps pull request.
    private func modelName(of mission: OrderMission) -> String? {
        guard !MissionNaming.pullRequests(of: mission).isEmpty else { return nil }
        return modelNames[mission.key]
    }

    /// Whether Rename… can give it a name: it has one of yours, or BriefBar keeps fewer than it can.
    package func canRename(_ key: MissionKey) -> Bool {
        yourNames.name(for: key) != nil || !yourNames.isFull
    }

    /// Rename…: what you typed becomes its name, as you typed it; nothing, or BriefBar's name for it, gives it BriefBar's
    /// name again, and keeps nothing. At the cap, it keeps none. Never logged.
    /// - Parameter shown: what the field started with: left as it was, it changes nothing, though Apple Intelligence named
    ///   the mission meanwhile.
    @discardableResult
    package func rename(_ mission: OrderMission, to typed: String, from shown: String? = nil) -> MissionNames.Outcome {
        guard isOn else { return .unchanged }
        if let shown, MissionNames.cleaned(typed) == MissionNames.cleaned(shown) { return .unchanged }
        var names = yourNames
        let outcome = names.rename(mission.key, to: typed, briefBarsName: briefBarsName(of: mission))
        guard names != yourNames else { return outcome }
        objectWillChange.send()
        yourNames = names
        cachedNames = nil
        names.save(to: defaults)
        askNames()
        return outcome
    }

    /// Use BriefBar's Name: forgets the name you gave it.
    package func useBriefBarsName(_ key: MissionKey) {
        guard isOn, yourNames.name(for: key) != nil else { return }
        objectWillChange.send()
        yourNames.clear(key)
        cachedNames = nil
        yourNames.save(to: defaults)
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
            guard yourNames.name(for: key) == nil, let mission = missions.first(where: { $0.key == key }),
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
        cachedNames = nil
    }

    // MARK: Your changes to missions

    /// What a pull request's Mission menu offers now.
    /// - Parameters:
    ///   - mission: the mission whose card it's in, where it's in two.
    ///   - withPrerequisites: Merge After's, which only its menu needs: VoiceOver's actions do without.
    package func choices(for ref: ItemRef, in mission: MissionKey? = nil, withPrerequisites: Bool = true) -> MissionChoices {
        MissionChoices.of(
            ref, in: mission, missions: missions, changes: changes, orders: orders, stacked: stacked, withPrerequisites: withPrerequisites
        )
    }

    /// How many of your changes Undo Your Changes to This Mission takes back: to its pull requests, those you put in it and
    /// those you moved out of it (`OrderChanges.undone`).
    package func changes(in mission: OrderMission) -> Int {
        changes.undone(in: mission.key, missions: missions).count
    }

    /// What names sessions, pull requests and missions in the order's words, as the sources say now, and the time: missions
    /// as their headers do (`title(of:)`); the names worked out again once they change, the time read each time, for ages to
    /// go on.
    package var names: OrderNames {
        var names: OrderNames
        if let cachedNames {
            names = cachedNames
        } else {
            var titles: [ItemRef: String] = [:]
            for source in SourceID.allCases {
                for (ref, item) in told[source]?.items ?? [:] where titles[ref] == nil {
                    titles[ref] = item.title
                }
            }
            let named = titles
            var missionTitles: [MissionKey: String] = [:]
            for mission in missions where missionTitles[mission.key] == nil {
                missionTitles[mission.key] = title(of: mission)
            }
            let titled = missionTitles
            names = OrderNames(name: { named[$0] }, title: { titled[$0] })
            cachedNames = names
        }
        names.now = now()
        return names
    }

    /// Changes a mission as you asked, from a pull request's Mission menu or a mission's ⋯, and says what you did, for its
    /// Undo line and for VoiceOver; or, refused, why, beside your last change's Undo, and changes nothing. Nil when there was
    /// nothing to change.
    @discardableResult
    package func change(_ edit: OrderEdit) -> OrderLastChange? {
        guard isOn else { return nil }
        // Against the orders as agents last told them, though BriefBar hasn't heard yet: a revision told before your change
        // is what it replaced, not one that goes against it.
        reloadOrders()
        let before = Set(missions.map(\.key))
        // The card you move a pull request from, as it was, for its Undo line: a chain named by one you move goes on by
        // another of its own.
        var source: OrderMission?
        if case .move(_, _, let from?) = edit { source = missions.first { $0.key == from } }
        var changed = changes
        let touched: [ItemRef: OrderChange?]
        do {
            touched = try changed.apply(edit, missions: missions, orders: orders, stacked: stacked, now: now())
        } catch {
            let refused = OrderLastChange(
                said: "\(error)", refs: edit.refs, mission: cardMission(for: edit, source: source), touched: [:],
                evidence: OrderEvidence()
            )
            refusal = refused
            return refused
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
            said: OrderText.did(edit, names: names, newMission: made), refs: edit.refs, mission: cardMission(for: edit, source: source),
            touched: touched, evidence: seen
        )
        refusal = nil
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
        refusal = nil
        evidence = evidence.merging(last.evidence)
        keep(changed)
        rebuild()
        return true
    }

    /// × beside the Undo line: it goes, and your change stays.
    package func dismissLastChange() {
        lastChange = nil
    }

    /// × beside why BriefBar didn't make a change: it goes.
    package func dismissRefusal() {
        refusal = nil
    }

    /// What the Undo lines say, the latest first: why BriefBar didn't make the change you asked for last, then your last
    /// change, with Undo.
    package var said: [OrderLastChange] {
        [refusal, lastChange].compactMap { $0 }
    }

    /// The mission whose card shows what an edit did, so that Undo is where you are: the one you changed it in, else where
    /// its pull request is now. For a Move, the one you moved it from, also once a chain named by what you moved goes on by
    /// another of its own, else none, for the top of the list: never the card it went to, which can be out of sight.
    /// - Parameter source: the card you moved it from, as it was before the Move.
    private func cardMission(for edit: OrderEdit, source: OrderMission? = nil) -> MissionKey? {
        switch edit {
        case .undoMission(let key):
            return missions.contains { $0.key == key } ? key : nil
        case .move(let refs, _, let from):
            guard let from else { return nil }
            if missions.contains(where: { $0.key == from }) { return from }
            guard case .chain = from, let source else { return nil }
            let stayed = Set(source.steps.map(\.ref)).subtracting(refs)
            return missions.first { $0.kind == .stack && $0.steps.contains { stayed.contains($0.ref) } }?.key
        case .setNext(_, let key, _), .mergeAfter(_, _, let key, _):
            if missions.contains(where: { $0.key == key }) { return key }
        case .undo, .putBack:
            break
        }
        if let ref = edit.refs.first, let mission = OrderBoard.mission(of: ref, in: missions) { return mission.key }
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
            sourcesOn: Set(sources.flatMap(ItemRef.Kind.of).filter(\.isPullRequest)),
            readsStories: sources.contains { told[$0]?.readsStories == true }
        )
    }

    /// The kinds of thing whose source is on and tells it what it shows.
    private var kindsOn: Set<ItemRef.Kind> {
        Set(SourceID.allCases.filter { told[$0] != nil }.flatMap(ItemRef.Kind.of))
    }

    /// The missions again, from what the sources show, the orders and your changes: first keeping what the sources show
    /// become of the pull requests that orders or your changes name, or that you focus on, and forgetting the orders and
    /// changes that finished long enough ago; then moving a chain you put pull requests in on to another of its pull
    /// requests, as the one it's named by ends; then what's kept by the key of a mission that's gone on to where it went
    /// (`OrderBoard.successor`): your changes that name it and what Undo would put back, Focus, and the name you gave it.
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
        // What Undo would put back can name pull requests no change of yours names now: what BriefBar sees become of them
        // goes with it, in memory, for as long as Undo is there.
        if let last = lastChange, last.canUndo {
            let named = OrderChanges(last.touched.values.compactMap { $0 }).subjects
            var seen = last.evidence
            for observation in facts.observations where named.contains(observation.ref) {
                seen.observe(observation, at: date)
            }
            if seen != last.evidence { lastChange = last.seeing(seen) }
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
        let renamed = anchored.moveAnchors(in: missions, orders: orders, alsoFor: pending)
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
        // What's kept by a mission's key follows it, once it's gone, to where all its open pull requests went: a session's
        // pull requests to their story's, a chain to the chain or GitHub stack they're in now, as the one it was named by
        // ended, moved out or came back with Undo. Not by those your changes moved, into it or out of it, wherever they are
        // now. Else it waits, as ever. One rule for all of it: your changes and what Undo would put back, Focus, and the
        // name you gave the mission.
        let moved = Set(self.changes.holding(in: orders).filter { $0.value.placement != nil }.keys)
        let old = self.missions
        let new = missions
        let successor = { (key: MissionKey) in OrderBoard.successor(of: key, from: old, to: new, moved: moved) }
        var followed = self.changes
        var remade = !followed.followMissions(successor).isEmpty
        if remade { keep(followed) }
        if let last = lastChange { lastChange = last.renamingMissions(successor) }
        if let focus, let next = successor(focus) {
            self.focus = next
            OrderFocus.save(next, to: defaults)
            remade = true
        }
        if remade {
            missions = OrderBoard.missions(
                facts: facts, orders: orders, evidence: evidence, focus: focus, changes: self.changes, now: date
            )
        }
        keepNames(following: successor, in: missions, facts: facts, at: date)
        forgetModelNames(keepingPlans: Set(orders.plans.map(\.id)), keepingMine: self.changes.ownMissions)
        cachedNames = nil
        if missions != self.missions { self.missions = missions }
        askNames()
    }

    /// Apple Intelligence's names of orders BriefBar no longer keeps, and of missions of your own no change of yours puts a
    /// pull request in anymore, go, with what it was asked of them, as yours do, however they went: forgotten, finished,
    /// undone, or left with no pull request as a source was turned off.
    private func forgetModelNames(keepingPlans plans: Set<UUID>, keepingMine mine: Set<UUID>) {
        let forgets = { (key: MissionKey) in MissionNames.forgets(key, kinds: [], keepingPlans: plans, keepingMine: mine) }
        if modelNames.keys.contains(where: forgets) { modelNames = modelNames.filter { !forgets($0.key) } }
        namer?.forget(where: forgets)
    }

    /// The names you gave missions, as the missions change: each follows its mission as Focus does, by `successor`; those of
    /// orders BriefBar no longer keeps, and of missions of your own no change of yours puts a pull request in anymore, go;
    /// and the time since BriefBar last saw a mission counts against its name while BriefBar could see it, at most two hours
    /// at a time, as when the Mac slept.
    private func keepNames(
        following successor: (MissionKey) -> MissionKey?, in missions: [OrderMission], facts: OrderFacts, at date: Date
    ) {
        var names = yourNames
        var renamed = false
        for key in names.entries.keys.sorted(by: { $0.description < $1.description }) {
            if let next = successor(key), names.follow(key, to: next) { renamed = true }
        }
        let plans = Set(orders.plans.map(\.id))
        if names.forget([], keepingPlans: plans, keepingMine: changes.ownMissions) { renamed = true }
        let elapsed = namesCounted.map { min(max(date.timeIntervalSince($0), 0), 2 * Self.timeCheckInterval) } ?? 0
        namesCounted = date
        let kindsOn = kindsOn
        let before = names.entries.count
        let changed = names.account(shown: Set(missions.map(\.key)), canSee: { key in
            MissionNames.canSee(key, plans: plans, kindsOn: kindsOn, readsStories: facts.readsStories)
        }, elapsed: elapsed)
        if names.entries.count != before { renamed = true }
        if renamed { objectWillChange.send() }
        yourNames = names
        if renamed || changed { names.save(to: defaults) }
    }
}

/// Your last change to a mission, for its Undo line until your next one or until you dismiss it, in memory only; or why
/// BriefBar didn't make it.
package struct OrderLastChange: Equatable {
    /// What you did, "You set !4079 as next to merge", or why BriefBar didn't.
    package let said: String
    /// The pull requests it was about.
    package let refs: [ItemRef]
    /// The mission whose card shows it: the one you changed it in, or moved it from, else where its pull request is now; nil
    /// for the top of the list.
    package let mission: MissionKey?
    /// What it touched, as it was, for Undo; empty for one BriefBar refused.
    package let touched: [ItemRef: OrderChange?]
    /// What BriefBar saw become of the pull requests those were about, as it was, for Undo to put back with them.
    package let evidence: OrderEvidence

    /// Whether it was made, and Undo can put back what it touched.
    package var canUndo: Bool { !touched.isEmpty }

    /// The same, with what BriefBar saw become of its pull requests since.
    func seeing(_ evidence: OrderEvidence) -> OrderLastChange {
        OrderLastChange(said: said, refs: refs, mission: mission, touched: touched, evidence: evidence)
    }

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

    /// The same, with the missions it names that are gone named as where they went (`OrderBoard.successor`), as your changes
    /// are: in what Undo would put back, and its card.
    func renamingMissions(_ successor: (MissionKey) -> MissionKey?) -> OrderLastChange {
        var undo = OrderChanges(touched.values.compactMap { $0 })
        let renamed = undo.followMissions(successor)
        let card = mission.map { successor($0) ?? $0 }
        guard !renamed.isEmpty || card != mission else { return self }
        return OrderLastChange(
            said: said, refs: refs, mission: card, touched: touched.mapValues { change in change.map { undo[$0.ref] ?? $0 } },
            evidence: evidence
        )
    }
}
