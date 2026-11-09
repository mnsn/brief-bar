import BriefBarCore
import Combine
import Foundation

/// Pull Request Order: which pull requests go together, as missions, and the order they merge in, for the Pull Requests
/// pages to list By Mission. It's made of what each source that's on tells it it shows now (`publish`), of the orders
/// Copilot sessions told BriefBar through its agents' tools, which `--mcp` keeps in BriefBar's preferences and tells the app
/// it changed (`AgentChanges`), and of your changes to missions (`OrderChanges`), which only the app writes. It's off until
/// you turn it on (`PullRequestOrderSetting`): until then it reads nothing, not even the orders it kept, and the sources tell
/// it nothing. Turned off, it shows nothing again, and keeps the orders, what it saw become of their pull requests, the
/// mission you focus on, your changes, the names you gave missions and the suggested splits you kept together, unused,
/// until you forget them. A mission is called by the name you gave it, else the one Apple Intelligence gave it on this
/// Mac while By Mission showed it (`MissionNamer`), else the one BriefBar gives it from its sources.
@MainActor
package final class PullRequestOrder: ObservableObject {
    @Published package private(set) var isOn: Bool
    /// The missions, as By Mission lists them (`OrderBoard.missions`): none while it's off.
    @Published package private(set) var missions: [OrderMission] = []
    /// The pull requests you set as next to merge in a session's order whose order would hold them again were they set as
    /// next in another mission that holds them now: by pull request, then by that mission, the mission they're next in
    /// (`OrderBoard.nextsHeldAgain`). The Board doesn't move where one's next back and forth. None while it's off.
    @Published package private(set) var nextsHeldAgain: [ItemRef: [MissionKey: MissionKey]] = [:]
    /// The mission you keep on top: none while it's off.
    @Published package private(set) var focus: MissionKey?
    /// The orders sessions told BriefBar: none while it's off.
    @Published package private(set) var orders = DeclaredOrders()
    /// Your changes to missions, those kept in memory included: none while it's off.
    @Published package private(set) var changes = OrderChanges()
    /// Your last change, to a pull request's stage or to a mission, for Undo, which puts back exactly what it touched: one
    /// at a time, so that a change of either kind replaces Undo of the other, in memory only, until your next change, Undo,
    /// or you dismiss it.
    @Published package private(set) var lastChange: LastChange?
    /// Why BriefBar didn't make the change you asked for last, beside your last change's Undo, which stays: until your next
    /// change, Undo, or you dismiss it.
    @Published package private(set) var refusal: OrderLastChange?
    /// Your last change, when it was to a stage: what the Stage menu's Undo, the details' and the Board's Undo lines show.
    package var lastStageChange: StageChange? { lastChange?.stage }
    /// Your last change, when it was to a mission: what a mission's Undo line shows.
    package var lastOrderChange: OrderLastChange? { lastChange?.order }
    /// By Mission's view, List, Map or the Board, on both Pull Requests pages: GitHub's shows List for the Board
    /// (`view(offering:)`).
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
    /// Asks Apple Intelligence for missions' names, and whether to split them: only the app's, never the demo's or
    /// `--render`'s.
    package var namer: MissionNamer? {
        didSet {
            namer?.named = { [weak self] key, name in self?.modelNamed(key, name) }
            namer?.suggested = { [weak self] key, _, split in self?.splitSuggested(key, split) }
        }
    }
    /// The splits Apple Intelligence suggests, by mission, in memory only; in the demo, a made-up one. One shows while it
    /// holds for what its mission is now (`suggestedSplit(for:)`).
    @Published package private(set) var splits: [MissionKey: MissionSplit] = [:]
    /// The suggestions you kept together (`order.splits`): none while it's off.
    package private(set) var keptTogether = KeptTogether()
    /// The missions whose suggestion you asked to see again with Suggested Split…, though you kept it together, while
    /// BriefBar runs.
    @Published package private(set) var splitsShownAgain: Set<MissionKey> = []
    /// The Board's lanes: one for each mission, or one for every card.
    @Published package private(set) var lanes: BoardLanes
    /// Whether you folded Up Next.
    @Published package private(set) var isUpNextFolded: Bool
    /// The column Up Next's "2 more ›" asked the Board to show, until it has.
    @Published package var revealedColumn: PullRequestStage?
    /// Why the Board's keys couldn't move a pull request while its details covered the Board, for them to say
    /// (`StageRefusalLine`), until the Board shows again. In memory only.
    @Published package var stageRefusal: StageRefusal?
    /// Each pull request's stage, where it is in its flow, as BriefBar works it out from what its source shows, or as you or
    /// a session set it: for the pull requests whose source tells their stages, Azure DevOps'; none while it's off.
    @Published package private(set) var stages: [ItemRef: StageReading] = [:]
    /// The kinds of pull request whose source tells their stages now, Azure DevOps': their missions draw merged ones in
    /// Merged's color.
    private var stagedKinds: Set<ItemRef.Kind> = []

    private let defaults: UserDefaults
    private let isDemo: Bool
    private let now: () -> Date
    /// What BriefBar saw become of the pull requests that orders and your changes name, and of the one you focus on.
    private var evidence = OrderEvidence()
    /// The stages you set, for each Azure DevOps account (`order.stages`).
    private var marks = StageMarks()
    /// The stages you set for pull requests listed only because someone sent them to you, or before BriefBar knew which
    /// account signed in: in memory only, each with when a list last had it, so that they go after 30 days as those
    /// kept do. They count with those toward the most an account keeps, and stay, unused, while Pull Request Order is off.
    /// One waits here too while its account has no room: one set before BriefBar knew the account, or put back by Undo.
    private var marksInMemory: [ItemRef: StageMarks.Entry] = [:]
    /// The stages Copilot sessions set (`order.stage.<id>`), as their `--mcp` kept them: read as Pull Request Order turns
    /// on and as an agent changes something, the demo's in memory. Each counts only while the Copilot source lists its
    /// session (`listedSessionsDoing`).
    private var sessionStages = SessionStages()
    /// The account each source last told while it knew one: the stages you set in memory, and Undo, are that account's.
    /// Turning Pull Request Order off keeps it, so that once it's on again, another account still forgets them.
    private var accounts: [SourceID: String] = [:]
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
        didSet {
            cachedNames = nil
            questions = [:]
        }
    }
    /// `names`, but the time, until the sources or the missions change.
    private var cachedNames: OrderNames?
    /// Each mission's question for a suggested split, as worked out since the missions, what the sources show or its name
    /// last changed; nil for one it doesn't look at.
    private var questions: [MissionKey: MissionSplitQuestion?] = [:]
    /// When it last counted the time against what you kept together, while it's on.
    private var keptCounted: Date?
    /// The demo's made-up split: a mission, its groups of pull requests, and their names.
    private var demoSplit: (key: MissionKey, grouping: [Set<ItemRef>], names: [String?])?
    /// What the change you're making touched, as it was, while the missions are made again for it, before it's your last
    /// change: what its Undo would put back.
    private var making: [ItemRef: OrderChange?]?
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
    /// sessions told BriefBar it works on, which the Map shows, what its pull requests' stages are worked out from, with
    /// the account it read them with, which of its pull requests it lists only because someone sent them in a chat,
    /// whether it reads the stories its pull requests are for, and whether it has listed what it shows since it started.
    private struct Told {
        var pullRequests: [OrderPullRequest]
        var sessions: [OrderSession]
        var items: [ItemRef: LinkedItem]
        var working: [ItemRef: [ItemRef]] = [:]
        var stages: [ItemRef: StageFacts] = [:]
        var account: String?
        /// What each of its sessions does, as the source can tell it: how one that ended ended, which how it looks can't.
        var activities: [ItemRef: StageSession.Activity] = [:]
        /// Since when each does what it does, or ended, whether or not it has a row, as a task BriefBar sent hasn't until
        /// you open it in the Copilot app.
        var activitiesSince: [ItemRef: Date] = [:]
        var inMemory: Set<ItemRef> = []
        var readsStories = false
        var listed = true
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

    /// Asks By Mission to show a mission, as clicking a row's capsule does. On a page that shows the Board with Lanes: None,
    /// which has no lane for it, the Board shows a lane for each mission again, remembered, as choosing Missions does.
    /// - Parameter kinds: the kinds of pull request the page lists, for the view it shows.
    package func reveal(_ key: MissionKey, kinds: Set<ItemRef.Kind>) {
        if view(offering: OrderView.offered(for: kinds)) == .board { setLanes(.missions) }
        revealed = key
    }

    /// Whether BriefBar keeps anything for Pull Request Order, on or off: an order, what it saw become of their pull
    /// requests, the mission you focus on, a change of yours, a name you gave a mission, or a suggestion you kept together.
    package var keepsAnything: Bool {
        let keys = [
            DeclaredOrders.defaultsKey, OrderEvidence.defaultsKey, OrderFocus.defaultsKey, OrderChanges.defaultsKey, MissionNames.defaultsKey,
            KeptTogether.defaultsKey,
        ]
        return !changesInMemory.isEmpty || !evidenceInMemory.records.isEmpty || keys.contains { defaults.object(forKey: $0) != nil }
    }

    /// Pull Request Order, in Settings. On, it reads the orders and changes it kept, and the sources tell it what they show;
    /// off, it forgets all that, in memory only, but for the stages you set, which it keeps, unused: those in memory too,
    /// with the account each source told last, so that one that tells another once it's on again forgets them.
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
            splits = [:]
            keptTogether = KeptTogether()
            splitsShownAgain = []
            keptCounted = nil
            namer?.stop()
            missions = []
            nextsHeldAgain = [:]
            marks = StageMarks()
            sessionStages = SessionStages()
            stages = [:]
            stagedKinds = []
        }
    }

    private func load() {
        orders = DeclaredOrders.load(from: defaults)
        evidence = OrderEvidence.load(from: defaults).merging(evidenceInMemory)
        focus = OrderFocus.load(from: defaults)
        marks = StageMarks.load(from: defaults)
        changes = OrderChanges.load(from: defaults).merging(changesInMemory)
        yourNames = MissionNames.load(from: defaults)
        namesCounted = nil
        keptTogether = KeptTogether.load(from: defaults)
        keptCounted = nil
        // The demo's agents keep what they tell in their own memory.
        if !isDemo {
            SessionStages.prune(in: defaults, now: now())
            sessionStages = SessionStages.load(from: defaults, now: now())
        }
        if !isDemo, agentChanges == nil {
            agentChanges = AgentChanges.observe { [weak self] in self?.agentChanged() }
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
    /// long enough ago to go, the stages you set for pull requests no list has had for 30 days, kept or in memory, and
    /// those sessions set 30 days ago.
    package func timePassed() {
        guard isOn else { return }
        let date = now()
        if marks.forgetUnlisted(now: date) { marks.save(to: defaults) }
        marksInMemory = marksInMemory.filter { !$0.value.isUnlisted(at: date) }
        if !isDemo {
            SessionStages.prune(in: defaults, now: date)
            sessionStages = SessionStages.load(from: defaults, now: date)
        }
        rebuild()
    }

    /// An agent told or changed something through `--mcp`: the orders, and the stages sessions set, read again.
    package func agentChanged() {
        reloadOrders()
        reloadSessionStages()
    }

    /// Reads the orders again, as an agent told or forgot one through `--mcp`.
    package func reloadOrders() {
        guard isOn else { return }
        let loaded = DeclaredOrders.load(from: defaults)
        guard loaded != orders else { return }
        orders = loaded
        rebuild()
    }

    /// Reads the stages sessions set again, as one set or cleared one through `--mcp`.
    package func reloadSessionStages() {
        guard isOn, !isDemo else { return }
        let loaded = SessionStages.load(from: defaults, now: now())
        guard loaded != sessionStages else { return }
        sessionStages = loaded
        restage()
    }

    // MARK: What the sources show

    /// What a source shows now, while it's on: the pull requests it lists, with what an order needs of each, the sessions
    /// it knows, how its things look, for what shows them, what each session told BriefBar it works on now
    /// (`SessionUpdates`), which changes no mission, what its pull requests' stages are worked out from, with the account
    /// it read them with, whose stages you set apply, and how each of the sessions it lists does, or ended, when it can
    /// tell, and since when, which are the sessions whose stages count (`SessionStages`), the pull requests it lists
    /// only because someone sent them in a chat, whose changes stay in memory, whether it reads the stories its pull
    /// requests are for, and whether it has listed what it shows since it started, as it hasn't right after BriefBar
    /// starts: till then, what a mission is made of isn't counted. It replaces what the source told before. Once it
    /// tells another account than the one it told last, the stages you set that BriefBar kept in memory for its pull
    /// requests go, and so does Undo of one: they were the other account's. Nothing's kept while Pull Request Order is
    /// off.
    package func publish(
        _ source: SourceID, pullRequests: [OrderPullRequest] = [], sessions: [OrderSession] = [], items: [LinkedItem] = [],
        working: [ItemRef: [ItemRef]] = [:], stages: [ItemRef: StageFacts] = [:], account: String? = nil,
        sessionActivities: [ItemRef: StageSession.Activity] = [:], activitiesSince: [ItemRef: Date] = [:],
        inMemory: Set<ItemRef> = [], readsStories: Bool = false, listed: Bool = true
    ) {
        guard isOn else { return }
        var byRef: [ItemRef: LinkedItem] = [:]
        for item in items where byRef[item.ref] == nil {
            byRef[item.ref] = item
        }
        let new = Told(
            pullRequests: pullRequests, sessions: sessions, items: byRef, working: working, stages: stages,
            account: account?.lowercased(), activities: sessionActivities, activitiesSince: activitiesSince, inMemory: inMemory,
            readsStories: readsStories, listed: listed
        )
        let old = told[source]
        let sameFacts = old?.pullRequests == new.pullRequests && old?.sessions == new.sessions
            && old?.readsStories == new.readsStories && old?.listed == new.listed
        let sameStages = old?.stages == new.stages && old?.account == new.account && old?.activities == new.activities
            && old?.activitiesSince == new.activitiesSince
        guard !sameFacts || !sameStages || old?.items != new.items || old?.working != new.working
            || old?.inMemory != new.inMemory else { return }
        objectWillChange.send()
        if let account = new.account {
            if let was = accounts[source], was != account { forgetInMemory(ItemRef.Kind.of(source)) }
            accounts[source] = account
        }
        told[source] = new
        sentInChats.formUnion(inMemory)
        sentInChats.subtract(Set(pullRequests.map(\.ref)).subtracting(inMemory))
        if old?.inMemory != new.inMemory || !sameFacts { keep(changes) }
        // How a session looks says whether it works now, which stages follow; and what missions are named from, such as a
        // title, can change.
        if sameFacts {
            restage()
            askNames()
        } else {
            rebuild()
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
    /// saw become of them, your changes to them and those that put pull requests in its missions, the mission you focus on,
    /// the names you gave missions and the suggestions you kept together, when they're theirs, and the stages you set for its
    /// pull requests.
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
        var together = KeptTogether.load(from: defaults)
        if together.forget(kinds, keepingPlans: plans) { together.save(to: defaults) }
        var marks = StageMarks.load(from: defaults)
        if marks.forget(kinds) { marks.save(to: defaults) }
        forgetInMemory(kinds)
        // What sessions set: on its pull requests, or, with GitHub Copilot, everything, as its sessions told it.
        if !isDemo { SessionStages.forget(kinds, in: defaults, now: now()) }
        sessionStages.forget(kinds)
        accounts[source] = nil
        // What's left goes in before the source's pull requests leave the missions, so that rebuilding then, which can save
        // what it keeps, saves none of what was forgotten back, such as a name.
        if isOn {
            objectWillChange.send()
            self.orders = orders
            self.evidence = evidence
            self.changes = changes
            self.focus = kept
            self.marks = marks
            if lastOrderChange != nil { lastChange = nil }
            refusal = nil
            yourNames = names
            keptTogether = together
            // Apple Intelligence names only missions with an Azure DevOps pull request, from their titles: as Azure DevOps
            // goes, all its names go, and the answer under way, a session's mission's too, whose key names none. So do the
            // splits it suggests, which only move Azure DevOps' pull requests.
            let forgets = { (key: MissionKey) in
                kinds.contains(.pullRequest)
                    || MissionNames.forgets(key, kinds: kinds, keepingPlans: plans, keepingMine: changes.ownMissions)
            }
            modelNames = modelNames.filter { !forgets($0.key) }
            splits = splits.filter { !forgets($0.key) }
            splitsShownAgain = splitsShownAgain.filter { !forgets($0) }
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
    /// to missions, the names you gave missions and the suggestions you kept together, whether Pull Request Order is on or
    /// not.
    package func forgetAll() {
        objectWillChange.send()
        DeclaredOrders.forgetAll(in: defaults)
        orders = DeclaredOrders()
        evidence = OrderEvidence()
        evidenceInMemory = OrderEvidence()
        focus = nil
        changes = OrderChanges()
        changesInMemory = OrderChanges()
        if lastOrderChange != nil { lastChange = nil }
        refusal = nil
        yourNames = MissionNames()
        keptTogether = KeptTogether()
        splitsShownAgain = []
        rebuild()
    }

    /// The demo's stages, as if you'd set them then, on those of its pull requests whose source told their stages and that
    /// you haven't set: only in the demo, while it's on. Each keeps what would end it as the pull request is now, as one
    /// you set does (`StageRules.mark`).
    package func tellDemo(stages demo: [ItemRef: StageMark]) {
        guard isDemo, isOn else { return }
        var kept = false
        for (ref, set) in demo.sorted(by: { $0.key < $1.key }) {
            guard let facts = stageFacts[ref], yourMark(of: ref, facts: facts) == nil else { continue }
            let mark = StageRules.mark(set.stage, at: set.at, facts: facts)
            if keep(mark, of: ref, facts: facts) { kept = true }
        }
        if kept { restage() }
    }

    /// The demo's orders, as if its sessions had told them, unless it has them, with what BriefBar saw become of their pull
    /// requests before, the mission you focus on, your made-up changes to its missions, and the names Apple Intelligence
    /// would give missions and the split it would suggest, made up: only in the demo, while it's on.
    /// - Parameter split: a mission, its groups of pull requests, the one that keeps it first, and their names.
    package func tellDemo(
        _ demo: DeclaredOrders, evidence seen: OrderEvidence = OrderEvidence(), focus key: MissionKey? = nil,
        changes made: OrderChanges = OrderChanges(), names madeUp: [MissionKey: String] = [:],
        split: (key: MissionKey, grouping: [Set<ItemRef>], names: [String?])? = nil
    ) {
        guard isDemo, isOn else { return }
        for (key, name) in madeUp where modelNames[key] == nil {
            modelNames[key] = name
        }
        if let split { demoSplit = split }
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
        namesChanged(mission.key)
        names.save(to: defaults)
        askNames()
        return outcome
    }

    /// Use BriefBar's Name: forgets the name you gave it.
    package func useBriefBarsName(_ key: MissionKey) {
        guard isOn, yourNames.name(for: key) != nil else { return }
        objectWillChange.send()
        yourNames.clear(key)
        namesChanged(key)
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

    /// Asks Apple Intelligence to name the missions on screen that you didn't name, from what they're made of now; then,
    /// once their names are asked, whether those it looks at have become different pieces of work, but those you kept
    /// together as they're made now, unless you asked to see their suggestion again.
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
        let splits = onScreen.compactMap { key -> MissionNamer.SplitRequest? in
            guard let mission = missions.first(where: { $0.key == key }), let question = splitQuestion(for: mission),
                  question.isWorthAsking, splitsShownAgain.contains(key) || !keptTogether.keeps(key)
            else { return nil }
            return MissionNamer.SplitRequest(question: question)
        }
        namer.update(requests, splits: splits)
    }

    private func modelNamed(_ key: MissionKey, _ name: String) {
        guard isOn, modelNames[key] != name else { return }
        modelNames[key] = name
        namesChanged(key)
        // A split asked next asks the group that keeps the mission with the name it shows now.
        askNames()
    }

    /// A mission's name changed: what names it, the stages that name it, as where two orders go round, and its question
    /// for a suggested split, which asks with the name it shows.
    private func namesChanged(_ key: MissionKey) {
        cachedNames = nil
        questions[key] = nil
        restage()
    }

    // MARK: Suggested splits

    /// A mission's question for a suggested split now (`MissionSplitting.question`), or nil for one it doesn't look at.
    package func splitQuestion(for mission: OrderMission) -> MissionSplitQuestion? {
        if let known = questions[mission.key] { return known }
        let facts = facts
        let holding = changes.holding(in: orders)
        // What your changes name a mission by, a chain's: a split leaves those where they are.
        var naming: Set<ItemRef> = []
        for change in holding.values {
            for key in [change.placement?.mission, change.first].compactMap({ $0 }) {
                if case .chain(let anchor) = key { naming.insert(anchor) }
            }
        }
        let question = MissionSplitting.question(
            for: mission, in: missions, facts: facts, named: modelName(of: mission),
            isNamedByYou: yourNames.name(for: mission.key) != nil, splitFrom: { holding[$0]?.splitFrom },
            namesMission: naming.contains, isChanged: { changes[$0] != nil }, sessionsWorking: sessionsWorking(on:),
            seesSessions: kindsOn.contains(.session),
            name: name(of:)
        )
        questions[mission.key] = .some(question)
        return question
    }

    /// The split Apple Intelligence suggests for a mission, while it holds for what the mission is made of now: none while
    /// you keep it together, unless you asked to see it again with Suggested Split….
    package func suggestedSplit(for mission: OrderMission) -> MissionSplit? {
        guard isOn, let split = splits[mission.key], let question = splitQuestion(for: mission), split.holds(for: question),
              splitsShownAgain.contains(mission.key) || !keptTogether.keeps(mission.key)
        else { return nil }
        return split
    }

    /// The box a mission's suggested split shows, while it has one.
    package func splitBox(for mission: OrderMission) -> SplitBox? {
        suggestedSplit(for: mission).map { split in
            OrderText.splitBox(split, title: title(of: mission), yourName: yourNames.name(for: mission.key), names: names)
        }
    }

    /// Split: the split Apple Intelligence suggests for a mission, as one change of yours, with one Undo: each group's pull
    /// requests go where it says, each new mission with the name Apple Intelligence gave it, in memory, as any mission's
    /// is, and the mission keeps its key, Focus and the name you gave it. What VoiceOver hears after it; nil when it has no
    /// suggestion that holds now.
    @discardableResult
    package func split(_ shown: OrderMission) -> String? {
        guard isOn else { return nil }
        // Against the orders as agents last told them, as the change will be: a revision since may relate what the
        // suggestion separates, and then it doesn't hold.
        reloadOrders()
        guard let mission = missions.first(where: { $0.key == shown.key }), let split = suggestedSplit(for: mission) else {
            return nil
        }
        let box = OrderText.splitBox(split, title: title(of: mission), yourName: yourNames.name(for: mission.key), names: names)
        var moves: [OrderSplitMove] = []
        var named: [MissionKey: String] = [:]
        for (index, group) in split.plan.groups.enumerated() {
            let name = split.names.indices.contains(index) ? split.names[index] : nil
            switch group.goes {
            case .keeps:
                if let name { named[mission.key] = name }
            case .newMission:
                let key = MissionKey.mine(UUID())
                moves.append(OrderSplitMove(group.refs, to: .into(key)))
                if let name { named[key] = name }
            case .outside:
                moves.append(OrderSplitMove(group.refs, to: .outside))
            case .into(let key):
                moves.append(OrderSplitMove(group.refs, to: .into(key)))
            }
        }
        // The names first, so that the missions show with them, the line that says what it did names them, and Apple
        // Intelligence isn't asked them again.
        let before = modelNames
        for (key, name) in named { modelNames[key] = name }
        cachedNames = nil
        guard let done = change(.split(mission.key, moves), in: mission.key), done.canUndo else {
            modelNames = before
            cachedNames = nil
            return refusal?.said
        }
        namer?.adopt(Array(named.keys))
        splitsShownAgain.remove(mission.key)
        let undo = missions.contains { $0.key == mission.key }
            ? "on the card of ‘\(title(of: missions.first { $0.key == mission.key } ?? mission))’" : "at the top of the list"
        return OrderText.splitDone(box, undo: undo)
    }

    /// Keep Together: the suggestion goes, and comes back only once the mission has been made of something it wasn't for
    /// `KeptTogether.settleFor` (`MissionSplitQuestion.Contents`), as BriefBar keeps (`order.splits`); Suggested Split…
    /// shows it again meanwhile. What VoiceOver hears after it.
    @discardableResult
    package func keepTogether(_ mission: OrderMission) -> String {
        guard isOn, let question = splitQuestion(for: mission) else { return OrderText.keptTogether }
        objectWillChange.send()
        keptTogether.keep(mission.key, contents: question.contents, at: now())
        keptTogether.save(to: defaults)
        splitsShownAgain.remove(mission.key)
        askNames()
        return OrderText.keptTogether
    }

    /// Whether a mission's ⋯ offers Suggested Split…: you kept its suggestion together, and BriefBar still has it for what
    /// the mission is made of now, or Apple Intelligence can be asked it again, as after BriefBar restarted.
    package func offersSuggestedSplit(_ mission: OrderMission) -> Bool {
        guard isOn, !splitsShownAgain.contains(mission.key), let question = splitQuestion(for: mission),
              keptTogether.keeps(mission.key)
        else { return false }
        if let split = splits[mission.key], split.holds(for: question) { return true }
        return question.isWorthAsking && namer?.canAsk == true
    }

    /// Suggested Split…: shows the suggestion you kept together again, asking Apple Intelligence again if BriefBar restarted
    /// since, until you split the mission or keep it together again.
    package func showSuggestedSplit(_ mission: OrderMission) {
        guard offersSuggestedSplit(mission) else { return }
        splitsShownAgain.insert(mission.key)
        askNames()
    }

    private func splitSuggested(_ key: MissionKey, _ split: MissionSplit?) {
        guard isOn, splits[key] != split else { return }
        splits[key] = split
    }

    /// Pull requests a split moved are back where BriefBar or an order puts them, by Undo, or as an order took them since:
    /// the missions they're in now keep together as they're made now, so that the split and the session don't undo each
    /// other over and over; what one is made of, while BriefBar can't tell yet, as right after it starts, is told once it
    /// can (`KeptTogether.keep`).
    private func keepTogether(splitBack refs: Set<ItemRef>) {
        guard !refs.isEmpty else { return }
        var kept = false
        for mission in missions where MissionSplitting.looksAt(mission) {
            guard (mission.steps + mission.attached).contains(where: { refs.contains($0.ref) }),
                  let question = splitQuestion(for: mission)
            else { continue }
            keptTogether.keep(mission.key, contents: question.contents, at: now())
            kept = true
        }
        guard kept else { return }
        objectWillChange.send()
        keptTogether.save(to: defaults)
    }

    /// What you kept together, as the missions change: each follows its mission as Focus does, by `successor`; those of
    /// orders BriefBar no longer keeps go, and those whose missions have been made of something they weren't for
    /// `KeptTogether.settleFor`; and the time since BriefBar last saw a mission counts against it while BriefBar could
    /// see it, at most two hours at a time. Then the missions that pull requests a split moved went back to, as an order
    /// took them, which BriefBar noted in this look (`splitsTakenBack`), keep together (`keepTogether(splitBack:)`): the
    /// order's mission is there from the order alone, so it's there in the look that notes it, and BriefBar quitting
    /// can't lose it.
    private func keepKeptTogether(
        following successor: (MissionKey) -> MissionKey?, facts: OrderFacts, splitsTakenBack: Set<ItemRef>, at date: Date
    ) {
        var kept = keptTogether
        var changed = false
        for key in kept.entries.keys.sorted(by: { $0.description < $1.description }) {
            if let next = successor(key), kept.follow(key, to: next) { changed = true }
        }
        let plans = Set(orders.plans.map(\.id))
        if kept.forget([], keepingPlans: plans) { changed = true }
        let elapsed = keptCounted.map { min(max(date.timeIntervalSince($0), 0), 2 * Self.timeCheckInterval) } ?? 0
        keptCounted = date
        var contents: [MissionKey: MissionSplitQuestion.Contents?] = [:]
        // Not while a source still reads what it shows, as right after BriefBar starts: until it has, a mission can still be
        // without some of its own, which join it once read, or seem finished. Nor one whose contents can't be told, as while
        // Azure DevOps is off.
        for mission in missions where kept.entries[mission.key] != nil && !facts.isReading {
            guard let question = splitQuestion(for: mission) else {
                contents[mission.key] = .some(nil)
                continue
            }
            if let made = question.contents { contents[mission.key] = made }
        }
        let kindsOn = kindsOn
        if kept.account(seen: Set(missions.map(\.key)), contents: contents, canSee: { key in
            MissionNames.canSee(key, plans: plans, kindsOn: kindsOn, readsStories: facts.seesStories)
        }, elapsed: elapsed, at: date) {
            changed = true
        }
        // Nothing shows how long one has differed.
        if kept.entries != keptTogether.entries { objectWillChange.send() }
        keptTogether = kept
        if changed { kept.save(to: defaults) }
        keepTogether(splitBack: splitsTakenBack)
    }

    /// The demo's made-up split, for its mission's question as it is now: only in the demo.
    private func tellDemoSplit() {
        guard isDemo, let demo = demoSplit, let mission = missions.first(where: { $0.key == demo.key }),
              let question = splitQuestion(for: mission), splits[demo.key]?.holds(for: question) != true,
              let indices = MissionSplitting.indices(of: demo.grouping, in: question),
              let plan = MissionSplitting.plan(question, grouping: indices)
        else { return }
        splits[demo.key] = MissionSplit(key: demo.key, basis: question.basis, grouping: demo.grouping, plan: plan, names: demo.names)
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
    /// - Parameter card: the mission whose card you asked in, where its pull request is in two; nil for the first that has
    ///   it.
    @discardableResult
    package func change(_ edit: OrderEdit, in card: MissionKey? = nil) -> OrderLastChange? {
        guard isOn else { return nil }
        // Against the orders as agents last told them, though BriefBar hasn't heard yet: a revision told before your change
        // is what it replaced, not one that goes against it.
        reloadOrders()
        let before = Set(missions.map(\.key))
        // The card you move a pull request from, or take back or put back your change to it in, as it was, for its Undo
        // line: a chain named by one you move goes on by another of its own.
        var source: OrderMission?
        switch edit {
        case .move(_, _, let from?):
            source = missions.first { $0.key == from }
        case .undo(let ref), .putBack(let ref):
            source = missions.first { $0.key == card && $0.contains(ref) } ?? OrderBoard.mission(of: ref, in: missions)
        default:
            break
        }
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
        // Those a split moved that are back where BriefBar or an order puts them, as Undo Your Changes to It or to This
        // Mission took the split's change back.
        let splitBack = Set(touched.keys.filter { changes[$0]?.bySplit == true && changed[$0] == nil })
        // What BriefBar saw become of the pull requests the changes it touched were about, which can go with them, for Undo
        // to put back.
        var seen = evidence
        seen.keep(only: OrderChanges(touched.values.compactMap { $0 }).subjects)
        keep(changed)
        making = touched
        rebuild()
        making = nil
        keepTogether(splitBack: splitBack)
        var made = false
        if case .move(_, .into(let key), _) = edit, case .mine = key { made = !before.contains(key) }
        let last = OrderLastChange(
            said: OrderText.did(edit, names: names, newMission: made), refs: edit.refs, mission: cardMission(for: edit, source: source),
            touched: touched, evidence: seen
        )
        refusal = nil
        lastChange = .order(last)
        return last
    }

    /// Where a pull request you set as next to merge in a mission still waits, as another mission's order holds it too, and
    /// what frees it (`BoardText.stillWaits`): nil unless it's next there now, as a change BriefBar refused leaves it.
    package func stillWaits(_ ref: ItemRef, nextIn mission: MissionKey) -> String? {
        guard let change = changes[ref], change.first == mission, change.holds(in: orders) else { return nil }
        return BoardText.stillWaits(ref, besides: mission, in: missions, names: names)
    }

    /// × beside why BriefBar didn't make a change: it goes.
    package func dismissRefusal() {
        refusal = nil
    }

    /// What the Undo lines say, the latest first: why BriefBar didn't make the change you asked for last, then your last
    /// change, with Undo.
    package var said: [OrderLastChange] {
        [refusal, lastOrderChange].compactMap { $0 }
    }

    /// The mission whose card shows what an edit did, so that Undo is where you are: the one you changed it in. For a Move,
    /// the one you moved it from, and for Undo Your Changes to It and Put Yours Back, the one it was in as you chose it, also
    /// once a chain named by what you moved goes on by another of its own, else none, for the top of the list: never the
    /// card it went to, which can be out of sight. Else where its pull request is now.
    /// - Parameter source: the card you moved it from, or took back or put back your change to it in, as it was before.
    private func cardMission(for edit: OrderEdit, source: OrderMission? = nil) -> MissionKey? {
        func shown(_ key: MissionKey, besides refs: [ItemRef]) -> MissionKey? {
            if missions.contains(where: { $0.key == key }) { return key }
            guard case .chain = key, let source else { return nil }
            let stayed = Set(source.steps.map(\.ref)).subtracting(refs)
            return missions.first { $0.kind == .stack && $0.steps.contains { stayed.contains($0.ref) } }?.key
        }
        switch edit {
        case .undoMission(let key):
            return missions.contains { $0.key == key } ? key : nil
        case .split(let key, _):
            return missions.contains { $0.key == key } ? key : nil
        case .move(let refs, _, let from):
            return from.flatMap { shown($0, besides: refs) }
        case .undo(let ref), .putBack(let ref):
            return source.flatMap { shown($0.key, besides: [ref]) }
        case .setNext(_, let key, _), .mergeAfter(_, _, let key, _):
            if missions.contains(where: { $0.key == key }) { return key }
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

    /// The missions of your own that Undo would put a pull request in again: your last change's, or, while the change you're
    /// making goes in, that one's. Until it's gone, the name you gave such a mission, and Focus on it, wait.
    private var undoableOwnMissions: Set<UUID> {
        OrderChanges((making ?? lastOrderChange?.touched ?? [:]).values.compactMap { $0 }).ownMissions
    }

    /// Whether BriefBar can tell which stories' missions there are (`OrderFacts.seesStories`): only then is one that doesn't
    /// show gone.
    package var seesStories: Bool { facts.seesStories }

    /// What the sources that are on show now.
    private var facts: OrderFacts {
        let sources = SourceID.allCases.filter { told[$0] != nil }
        return OrderFacts(
            pullRequests: sources.flatMap { told[$0]?.pullRequests ?? [] },
            sessions: sources.flatMap { told[$0]?.sessions ?? [] },
            sourcesOn: Set(sources.flatMap(ItemRef.Kind.of).filter(\.isPullRequest)),
            readsStories: sources.contains { told[$0]?.readsStories == true },
            pending: Set(sources.filter { told[$0]?.listed == false }.flatMap(ItemRef.Kind.of))
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
            if !nextsHeldAgain.isEmpty { nextsHeldAgain = [:] }
            stacked = [:]
            return
        }
        let date = now()
        let facts = facts
        stacked = OrderBoard.stacked(facts)
        let focused = focus.flatMap(OrderFocus.ref(of:))
        // What an order changed since one of your changes, as BriefBar sees it: that change doesn't hold anymore, though the
        // order changes back, until you put yours back. A split's that an order took, as one told while BriefBar was closed,
        // which it notes as it starts, keeps the mission it went back to together, in this look (`keepKeptTogether`).
        var noted = changes
        var splitsTakenBack: Set<ItemRef> = []
        if noted.noteOverrides(in: orders, now: date) {
            for change in noted.all where change.bySplit && change.overridden != nil && changes[change.ref]?.overridden == nil {
                splitsTakenBack.insert(change.ref)
            }
            keep(noted)
        }
        let subjects = changes.subjects
        var evidence = evidence
        for observation in facts.observations
        where orders.refs.contains(observation.ref) || observation.ref == focused || subjects.contains(observation.ref) {
            evidence.observe(observation, at: date)
        }
        // What Undo would put back can name pull requests no change of yours names now: what BriefBar sees become of them
        // goes with it, in memory, for as long as Undo is there.
        if let last = lastOrderChange, last.canUndo {
            let named = OrderChanges(last.touched.values.compactMap { $0 }).subjects
            var seen = last.evidence
            for observation in facts.observations where named.contains(observation.ref) {
                seen.observe(observation, at: date)
            }
            if seen != last.evidence { lastChange = .order(last.seeing(seen)) }
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
        var tidied = !changes.removeFinished(evidence: evidence, now: date).isEmpty
        // Where orders BriefBar no longer keeps put pull requests, and those sent to you only in a chat that no order it keeps
        // names anymore: references that would outlast everything else BriefBar keeps of them.
        if changes.forgetPlaces(besides: orders, chatOnly: sentInChats) { tidied = true }
        if tidied { keep(changes) }
        // The mission you focus on goes once its order finished, or, for one of your own, once no change of yours puts a
        // pull request in it, as Undo or time can take them, and Undo wouldn't bring it back: its name waits as long.
        var isMine = false
        if case .mine? = focus { isMine = true }
        if !finished.isEmpty || isMine {
            var kept = OrderFocus.kept(focus, in: orders, changes: self.changes)
            if case .mine(let id)? = focus, undoableOwnMissions.contains(id) { kept = focus }
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
        let pending = OrderChanges(lastOrderChange?.touched.values.compactMap { $0 } ?? [])
        let renamed = anchored.moveAnchors(in: missions, orders: orders, alsoFor: pending)
        if !renamed.isEmpty {
            // What Undo would put back names those chains as they're named now too, though no change of yours names them.
            if let last = lastOrderChange { lastChange = .order(last.renamingChains(renamed)) }
            if anchored != self.changes {
                keep(anchored)
                missions = OrderBoard.missions(
                    facts: facts, orders: orders, evidence: evidence, focus: focus, changes: self.changes, now: date
                )
            }
        }
        // What's kept by a mission's key follows it, once it's gone, to where all its open pull requests went: a session's
        // pull requests, or a chain, to their story's, and back out to the one mission made of them alone they went to, but
        // not while they're in more than one, as a teammate's chain's are; a chain to the chain or GitHub stack they're in
        // now, as the one it was named by ended, moved out or came back with Undo, or to the one with the most of them, as
        // you split it.
        // Not by those your changes moved, into it or out of it, wherever they are now. Else it waits, as ever. One rule
        // for all of it: your changes and what Undo would put back, Focus, and the name you gave the mission; but where you
        // set one as next follows only where nothing else open is, so that others there don't wait for it, and where one
        // you didn't move was as you changed it, only to a mission that has it.
        let moved = Set(self.changes.holding(in: orders).filter { $0.value.placement != nil }.keys)
        let old = self.missions
        let new = missions
        let successor = { (key: MissionKey) in OrderBoard.successor(of: key, from: old, to: new, moved: moved) }
        let nexts = { (key: MissionKey) in OrderBoard.successor(of: key, from: old, to: new, moved: moved, alone: true) }
        let holds = { (key: MissionKey, ref: ItemRef) in
            new.first { $0.key == key }.map { ($0.steps + $0.attached).contains { $0.ref == ref } } ?? false
        }
        var followed = self.changes
        var remade = !followed.followMissions(successor, nexts: nexts, holds: holds).isEmpty
        if remade { keep(followed) }
        if let last = lastOrderChange { lastChange = .order(last.renamingMissions(successor, nexts: nexts, holds: holds)) }
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
        forgetModelNames(keepingPlans: Set(orders.plans.map(\.id)), keepingMine: self.changes.ownMissions.union(undoableOwnMissions))
        cachedNames = nil
        let heldAgain = OrderBoard.nextsHeldAgain(
            facts: facts, orders: orders, evidence: evidence, changes: self.changes, missions: missions, stacked: stacked, now: date
        )
        if heldAgain != nextsHeldAgain { nextsHeldAgain = heldAgain }
        if missions != self.missions { self.missions = missions }
        questions = [:]
        keepKeptTogether(following: successor, facts: facts, splitsTakenBack: splitsTakenBack, at: date)
        tellDemoSplit()
        restage()
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
        if names.forget([], keepingPlans: plans, keepingMine: changes.ownMissions.union(undoableOwnMissions)) { renamed = true }
        let elapsed = namesCounted.map { min(max(date.timeIntervalSince($0), 0), 2 * Self.timeCheckInterval) } ?? 0
        namesCounted = date
        let kindsOn = kindsOn
        let before = names.entries.count
        let changed = names.account(shown: Set(missions.map(\.key)), canSee: { key in
            MissionNames.canSee(key, plans: plans, kindsOn: kindsOn, readsStories: facts.seesStories)
        }, elapsed: elapsed)
        if names.entries.count != before { renamed = true }
        if renamed { objectWillChange.send() }
        yourNames = names
        if renamed || changed { names.save(to: defaults) }
    }

    // MARK: Stages

    /// A pull request's stage, while Pull Request Order is on and its source tells stages.
    package func stage(of ref: ItemRef) -> StageReading? {
        stages[ref]
    }

    /// Whether you opened a pull request, as its source tells for its stage: only yours can be set to Teammate's review.
    package func isYours(_ ref: ItemRef) -> Bool {
        stageFacts[ref]?.isYours ?? false
    }

    /// Who opened someone else's pull request, by their first name, as its source tells for its stage.
    package func author(of ref: ItemRef) -> String? {
        stageFacts[ref]?.author
    }

    /// Why a pull request can't be set to Teammate's review, wherever you'd set it: someone else's asks for its own reviews,
    /// and Finished My Review takes it off your board instead. Nil for yours, or one whose source tells no stage.
    package func whyNotTeammateReview(_ ref: ItemRef) -> String? {
        guard let facts = stageFacts[ref], !facts.isYours else { return nil }
        return StageText.whyNotTeammateReview(author: facts.author)
    }

    /// The Board, Up Next and each mission's next steps, for a page of these kinds, with its lanes as you chose them, or
    /// these.
    package func board(kinds: Set<ItemRef.Kind>, lanes: BoardLanes? = nil) -> PullRequestBoard {
        PullRequestBoard.make(stages: stages, missions: missions, kinds: kinds, lanes: lanes ?? self.lanes)
    }

    /// The stage a mission's graph colors a pull request by: its own, or Merged for one BriefBar saw merge whose source
    /// tells stages, listed or not, so every merged one on Azure DevOps' page reads alike; nil for one with none, such as
    /// GitHub's, which show as they did.
    package func drawnStage(of step: OrderStep) -> PullRequestStage? {
        if let reading = stages[step.ref] { return reading.stage }
        return step.status == .merged && stagedKinds.contains(step.ref.kind) ? .merged : nil
    }

    /// The time, as it tells stages' ages: "You set it 2h ago".
    package var currentDate: Date { now() }

    /// Whether a pull request's Stage menu has anything for it: its stage, until it merged, or Undo of your last change,
    /// which was to it, even once it has no stage left to show, such as someone else's that asks nothing of you.
    package func offersStageMenu(for ref: ItemRef) -> Bool {
        if lastStageChange?.ref == ref { return true }
        guard let reading = stages[ref] else { return false }
        return reading.stage != .merged
    }

    /// Whether BriefBar keeps a stage you or a session set, on or off: for Forget Stages… in Settings.
    package var keepsStages: Bool {
        defaults.object(forKey: StageMarks.defaultsKey) != nil || !marksInMemory.isEmpty || SessionStages.keepsAny(in: defaults)
            || !sessionStages.isEmpty
    }

    /// The stages you set that BriefBar keeps, for each account, as many as there are, whatever lists have them now.
    package var keptStagesCount: Int {
        StageMarks.load(from: defaults).accounts.values.reduce(0) { $0 + $1.count } + marksInMemory.count
    }

    /// Sets a pull request's stage, as you choose it, In progress, Your review or Teammate's review, which stands until
    /// something ends it (`StageRules.stands`) or you change it; Teammate's review is Finished My Review. Undo puts back
    /// what it replaced. A pull request listed only because someone sent it to you keeps it in memory only. Refused, saying
    /// why, while Pull Request Order is off, for a stage only BriefBar sets, for one no list that tells stages has now, or
    /// for a new one once the account keeps the most.
    @discardableResult
    package func setStage(_ stage: PullRequestStage, of ref: ItemRef) -> StageChange.Outcome {
        guard isOn else { return .refused(StageChange.orderIsOff) }
        guard stage.isSettable else { return .refused(StageText.whyNotSettable(stage) ?? StageChange.setByBriefBar) }
        guard let facts = stageFacts[ref], facts.isListed else { return .refused(StageChange.notListed) }
        guard facts.state.isOpen else { return .refused(facts.state == .merged ? StageChange.merged : StageChange.closed) }
        let before = yourMark(of: ref, facts: facts)
        if let before, before.stage == stage, stages[ref]?.mark == before { return .unchanged }
        let mark = StageRules.mark(stage, at: now(), facts: facts)
        guard keep(mark, of: ref, facts: facts) else {
            return .refused(
                "BriefBar keeps up to \(StageMarks.mostPerAccount) stages you set. Let BriefBar decide one you no longer need first."
            )
        }
        lastChange = .stage(StageChange(ref: ref, before: before, after: stage))
        refusal = nil
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

    /// Let BriefBar Decide: forgets the stage you set, and BriefBar works it out again: what sessions set before yours,
    /// which yours replaced, goes too, rather than come back, also what a session the Copilot app doesn't list now set,
    /// should it list it again. Unchanged when you set none.
    @discardableResult
    package func letBriefBarDecide(_ ref: ItemRef) -> StageChange.Outcome {
        guard isOn, let facts = stageFacts[ref], let before = yourMark(of: ref, facts: facts) else { return .unchanged }
        forgetMark(of: ref, facts: facts)
        end(sessionStages.marks(on: ref, setBy: before.at), of: ref)
        lastChange = .stage(StageChange(ref: ref, before: before, after: nil))
        refusal = nil
        restage()
        return .done
    }

    /// Undo: puts back exactly what your last change touched, whichever it was, a stage's or a mission's; true when it
    /// did. Why BriefBar refused a change goes with it.
    @discardableResult
    package func undo() -> Bool {
        switch lastChange {
        case .stage(let change)?: undo(change)
        case .order(let last)?: undo(last)
        case nil: false
        }
    }

    /// Puts back exactly the stage your last change replaced, or none. What it puts back is kept even once the account
    /// keeps the most, as when Let BriefBar Decide made room that one waiting in memory took: it waits there in turn, until
    /// the account has room.
    private func undo(_ change: StageChange) -> Bool {
        guard isOn, let facts = stageFacts[change.ref] else {
            lastChange = nil
            return false
        }
        lastChange = nil
        refusal = nil
        if let before = change.before {
            if !keep(before, of: change.ref, facts: facts) {
                marksInMemory[change.ref] = StageMarks.Entry(mark: before, listedAt: now())
            }
        } else {
            forgetMark(of: change.ref, facts: facts)
        }
        restage()
        return true
    }

    /// Puts back exactly what your last change to a mission touched. Undoing a split keeps the mission together as it's made
    /// again, as Keep Together does.
    private func undo(_ last: OrderLastChange) -> Bool {
        guard isOn, last.canUndo else { return false }
        var changed = changes
        changed.restore(last.touched)
        // Those a split moved that are back where BriefBar or an order puts them: their split's change gone, or one an order
        // took them from since, as Undo of Put Yours Back, or of a second split, brings back.
        let splitBack = Set(last.touched.keys.filter { ref in
            changes[ref]?.bySplit == true && (changed[ref].map { !$0.bySplit || !$0.holds(in: orders) } ?? true)
        })
        lastChange = nil
        refusal = nil
        evidence = evidence.merging(last.evidence)
        keep(changed)
        rebuild()
        keepTogether(splitBack: splitBack)
        return true
    }

    /// Takes the Undo line away, as × beside it does: your change stays.
    package func dismissLastChange() {
        lastChange = nil
    }

    /// Forget Stages…: every stage you set, with every account, and every one sessions set, on or off.
    package func forgetStages() {
        objectWillChange.send()
        StageMarks.forgetAll(in: defaults)
        SessionStages.forgetAll(in: defaults)
        marks = StageMarks()
        marksInMemory = [:]
        sessionStages = SessionStages()
        if lastStageChange != nil { lastChange = nil }
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

    /// Whether a stage you set for it stays in memory: one listed only because someone sent it to you in a chat, as what
    /// you've seen of it does, or one BriefBar doesn't know the account of yet.
    private func keepsInMemory(_ ref: ItemRef, facts: StageFacts) -> Bool {
        facts.role == .sentToYou || account(of: ref) == nil
    }

    private func yourMark(of ref: ItemRef, facts: StageFacts) -> StageMark? {
        if let entry = marksInMemory[ref] { return entry.mark }
        guard !keepsInMemory(ref, facts: facts), let account = account(of: ref) else { return nil }
        return marks.mark(of: ref, for: account)
    }

    /// Keeps the stage you set, in place of the one it had: false for a new one once the account keeps the most
    /// already, counting those in memory, so that one in memory always has room with the account once it can go there.
    private func keep(_ mark: StageMark, of ref: ItemRef, facts: StageFacts) -> Bool {
        let account = account(of: ref)
        let isNew = marksInMemory[ref] == nil && account.flatMap { marks.mark(of: ref, for: $0) } == nil
        guard !isNew || keptCount(of: ref.kind, for: account) < StageMarks.mostPerAccount else { return false }
        if !keepsInMemory(ref, facts: facts), let account, marks.set(mark, of: ref, for: account, at: now()) {
            marksInMemory[ref] = nil
            marks.save(to: defaults)
        } else {
            // One only sent to you, one whose account BriefBar doesn't know yet, or one kept here before it knew, until
            // the account has room for it.
            marksInMemory[ref] = StageMarks.Entry(mark: mark, listedAt: now())
        }
        return true
    }

    /// How many stages you set an account keeps, with those in memory for pull requests of this kind, its source's.
    private func keptCount(of kind: ItemRef.Kind, for account: String?) -> Int {
        (account.map { marks.count(for: $0) } ?? 0) + marksInMemory.keys.filter { $0.kind == kind }.count
    }

    private func forgetMark(of ref: ItemRef, facts: StageFacts) {
        marksInMemory[ref] = nil
        if let account = account(of: ref), marks.clear(ref, for: account) { marks.save(to: defaults) }
    }

    /// Forgets the stages you set that BriefBar kept in memory for pull requests of these kinds, and Undo of one.
    private func forgetInMemory(_ kinds: Set<ItemRef.Kind>) {
        marksInMemory = marksInMemory.filter { !kinds.contains($0.key.kind) }
        if let change = lastStageChange, kinds.contains(change.ref.kind) { lastChange = nil }
    }

    /// Takes away what sessions set on a pull request, once none of it counts: in memory, and from what each session
    /// keeps, unless it set something since; the demo's are in memory only.
    private func end(_ sessionMarks: [StageMark], of ref: ItemRef) {
        for mark in sessionMarks {
            guard let session = mark.by else { continue }
            sessionStages.remove(ref, of: session, setAt: mark.at)
            if !isDemo { SessionStages.end(ref, of: session, setAt: mark.at, in: defaults) }
        }
    }

    /// The demo's sessions' stages, as if they'd set them, in memory: only in the demo, while it's on, on those of its pull
    /// requests whose source told their stages and that no session set yet. Each keeps what would end it as the pull
    /// request is now, as a stage a session sets does (`StageRules.mark`).
    package func tellDemo(sessionStages demo: [ItemRef: StageMark]) {
        guard isDemo, isOn else { return }
        var told = false
        for (ref, set) in demo.sorted(by: { $0.key < $1.key }) {
            guard let session = set.by, let facts = stageFacts[ref],
                  !sessionStages.sessions.values.contains(where: { $0.marks[ref] != nil }) else { continue }
            var stage = sessionStages[session] ?? SessionStage(session: session)
            stage.set(StageRules.mark(set.stage, at: set.at, facts: facts, by: session), of: ref)
            sessionStages.replace(stage)
            told = true
        }
        if told { restage() }
    }

    /// Each pull request's stage again: from what its source tells, the sessions on it, the stage you set and those the
    /// sessions it lists set, the latest of them while it stands, and its order. Once the latest no longer stands, or the
    /// pull request merged or closed, none of them counts: yours goes, and so do the sessions', those it doesn't list now
    /// too, from what they keep, so that an older one never comes back (`SessionStages.end`). A stage you set that no longer stands goes too. One you
    /// set kept in memory before BriefBar knew the account, or while it was only sent to you, is kept with the account
    /// once it can be, and one kept with the account goes into memory once it's only sent to you, such as when you stop
    /// watching it; and what lists have now is noted, for what no list has had for 30 days to go: in memory each time,
    /// and once a day for those kept. Only those a list has show a stage: what was set on one it still reads, but no
    /// list has, still ends as it moves on.
    private func restage() {
        guard isOn else {
            if !stages.isEmpty { stages = [:] }
            stagedKinds = []
            return
        }
        let all = stageFacts
        stagedKinds = Set(all.keys.map(\.kind))
        let setters = listedSessionsDoing()
        let sessionsOn = sessionsOnPullRequests()
        let sessionMarks = sessionStages.marks(listed: Set(setters.keys), now: now())
        // What names an order where two go round, as its mission's header does: only for what this Mac shows.
        let names = self.names
        var readings: [ItemRef: StageReading] = [:]
        var changed = false
        for (ref, facts) in all {
            let sessions = Self.merged(facts.sessions, sessionsOn[ref] ?? [])
            if let memory = marksInMemory[ref], !keepsInMemory(ref, facts: facts), let account = account(of: ref),
               marks.set(memory.mark, of: ref, for: account, at: memory.listedAt) {
                marksInMemory[ref] = nil
                changed = true
            } else if facts.role == .sentToYou, let account = account(of: ref), let saved = marks.entry(of: ref, for: account) {
                if marksInMemory[ref] == nil { marksInMemory[ref] = saved }
                if marks.clear(ref, for: account) { changed = true }
            }
            var mine = yourMark(of: ref, facts: facts)
            let counted = StageRules.counted(
                yours: mine, theirs: sessionMarks[ref] ?? [], facts: facts, sessions: sessions, setters: setters
            )
            if counted.latestEnded {
                // What every session set on it, listed or not: all of it once it merged or closed, else what the latest set
                // before it ended, so that what an archived session set doesn't come back once it's listed again.
                let latest = ([mine].compactMap { $0 } + (sessionMarks[ref] ?? [])).map(\.at).max() ?? .distantPast
                end(sessionStages.marks(on: ref, setBy: facts.state.isOpen ? latest : nil), of: ref)
            }
            if mine != nil, counted.yours == nil {
                marksInMemory[ref] = nil
                if let account = account(of: ref), marks.clear(ref, for: account) { changed = true }
                mine = nil
            }
            guard facts.isListed else { continue }
            marksInMemory[ref]?.listedAt = now()
            let order = StageOrder.of(ref, in: missions, names: names)
            let set = [mine].compactMap { $0 } + counted.theirs
            if var reading = StageRules.reading(facts: facts, sessions: sessions, marks: set, order: order, setters: setters) {
                // Its words name the other order where two go round: what they say naming none, as agents read it, so that
                // a rename, which restages it, changes only its words (`StageReading.readTheSame`).
                if case .orderHolds = reading.why, case .holds(let words) = StageOrder.of(ref, in: missions),
                   reading.why != .orderHolds(words) {
                    reading.unnamedWhy = .orderHolds(words)
                }
                readings[ref] = reading
            }
        }
        var listed: [String: Set<ItemRef>] = [:]
        for (ref, facts) in all where facts.isListed && facts.role != .sentToYou {
            if let account = account(of: ref) { listed[account, default: []].insert(ref) }
        }
        for (account, refs) in listed where marks.listed(refs, for: account, at: now()) {
            changed = true
        }
        if changed { marks.save(to: defaults) }
        if readings != stages { stages = readings }
    }

    /// What each session the sources list does now, or how it ended, and since when, on a pull request or not: what ends
    /// an In progress it set (`StageRules.stands`). What a session set counts only while it's listed, so what an archived
    /// session set goes with it.
    private func listedSessionsDoing() -> [ItemRef: StageSession] {
        var doing: [ItemRef: StageSession] = [:]
        for source in SourceID.allCases {
            for (session, activity) in told[source]?.activities ?? [:] where doing[session] == nil {
                let since = told[source]?.activitiesSince[session] ?? describe(session)?.date
                doing[session] = StageSession(ref: session, activity: activity, since: since)
            }
        }
        return doing
    }

    /// The Copilot app's sessions on each pull request, as their source tells them: those that opened it or work on it, as
    /// the app records them, and those that told BriefBar they work on it, each with what it does now, or how it ended, as
    /// its source tells it, and since when; none it doesn't say how.
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
        var activities: [ItemRef: StageSession.Activity] = [:]
        for told in told.values {
            activities.merge(told.activities) { first, _ in first }
        }
        return on.mapValues { sessions in
            sessions.sorted().compactMap { session in
                describe(session).map { item in
                    StageSession(ref: session, activity: activities[session] ?? Self.activity(item.state), since: item.date)
                }
            }
        }
    }

    /// What a session does, as the state it counts in says, when its source doesn't say: at work, waiting for you,
    /// finished, or else stopped. One without a state, such as one gone idle, says nothing of how it ended, so it counts as
    /// stopped, which says nothing of its pull request.
    static func activity(_ state: ItemState?) -> StageSession.Activity {
        switch state {
        case .running?: .working
        case .needsYou?: .waitsForYou
        case .done?: .finished
        case .failing?, nil: .stopped
        }
    }

    /// The sessions a source knows of on a pull request, with the Copilot app's, each once. One both know, such as a task
    /// BriefBar sent that you went on with in the Copilot app, does what the app says once that's later, unless the app
    /// can't tell how it ended; the source's still names it and says whether it reviews.
    nonisolated package static func merged(_ own: [StageSession], _ others: [StageSession]) -> [StageSession] {
        let theirs = Dictionary(others.map { ($0.ref, $0) }) { first, _ in first }
        let known = Set(own.map(\.ref))
        let reconciled = own.map { session in
            guard let other = theirs[session.ref], other.activity != .stopped, let since = other.since,
                  session.since.map({ since > $0 }) ?? true else { return session }
            var now = session
            now.activity = other.activity
            now.since = since
            return now
        }
        return reconciled + others.filter { !known.contains($0.ref) }
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

    /// Why a stage can't be set, as VoiceOver hears it with a beep.
    package static let orderIsOff = "Pull Request Order is off: turn it on in Settings › Pull Requests"
    package static let setByBriefBar = "BriefBar sets that stage itself"
    package static let notListed = "BriefBar doesn't list that pull request now"
    package static let merged = "It merged: its stage doesn't change now"
    package static let closed = "It's closed: its stage doesn't change now"
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
    /// are: in what Undo would put back, where it sets one as next by `nexts`, the mission one it didn't move was in only
    /// where that one is (`holds`), and its card.
    func renamingMissions(
        _ successor: (MissionKey) -> MissionKey?, nexts: ((MissionKey) -> MissionKey?)? = nil,
        holds: ((MissionKey, ItemRef) -> Bool)? = nil
    ) -> OrderLastChange {
        var undo = OrderChanges(touched.values.compactMap { $0 })
        let renamed = undo.followMissions(successor, nexts: nexts, holds: holds)
        let card = mission.map { successor($0) ?? $0 }
        guard !renamed.isEmpty || card != mission else { return self }
        return OrderLastChange(
            said: said, refs: refs, mission: card, touched: touched.mapValues { change in change.map { undo[$0.ref] ?? $0 } },
            evidence: evidence
        )
    }
}

/// Your last change, for Undo, which puts back exactly what it touched: a pull request's stage, or a mission.
package enum LastChange: Equatable {
    case stage(StageChange)
    case order(OrderLastChange)

    /// The change to a stage, when it's one.
    package var stage: StageChange? {
        guard case .stage(let change) = self else { return nil }
        return change
    }

    /// The change to a mission, when it's one.
    package var order: OrderLastChange? {
        guard case .order(let change) = self else { return nil }
        return change
    }
}
