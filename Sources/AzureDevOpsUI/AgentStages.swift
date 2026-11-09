import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Foundation

/// What Pull Request Order keeps, as the stages agents are told need it (`AzureDevOpsReader.orderKept`).
struct OrderKept: Sendable {
    var orders: DeclaredOrders
    var evidence: OrderEvidence
    var focus: MissionKey?
    var changes: OrderChanges
    /// The stages you set, for each account.
    var marks: StageMarks
    /// The stages sessions set (`SessionStages`).
    var sessionStages: SessionStages
    /// The pull requests you chose for Up Next's slots, which come first in their columns, as on the Board: those the app
    /// keeps in the preferences, not those only sent to you in a chat, which it keeps in memory.
    var picks = UpNextPicks()
    /// The demo's stages, as if you and its sessions had set them then, each keeping what would end it as the pull request
    /// is now, as the app's demo has them (`PullRequestOrder.tellDemo`).
    var demoMarks: [ItemRef: StageMark] = [:]
    var demoSessionMarks: [ItemRef: StageMark] = [:]
}

/// Azure DevOps pull requests' stages, for agents, as Pull Request Order works them out in the app while it's on: from what
/// `--mcp`'s lists read, the tasks BriefBar sent to Copilot, the Copilot app's sessions on them (`MCPRelated.stageSessions`),
/// what you and those sessions set, and their missions, as the app keeps them. `--mcp` only reads what the app keeps: what
/// ends a stage set, or what an order did to one of your changes, is the app's to note.
struct AgentStages: Sendable {
    /// Each listed pull request's stage that has one.
    var readings: [ItemRef: StageReading]
    /// The Board's columns, as it orders them: what's next first in each.
    var columns: [PullRequestStage: [ItemRef]]
    /// What the sources call each session.
    var names: [ItemRef: String]
    var now: Date

    func name(_ ref: ItemRef) -> String? {
        names[ref]
    }

    /// The stages `needs_me` tells, as the Board shows them: Merged isn't one of them.
    static let told: [PullRequestStage] = PullRequestStage.columns.filter { $0 != .merged }
}

extension AzureDevOpsAgent {
    /// Each pull request the lists read's stage, as Pull Request Order works it out in the app, while it's on; nil while
    /// it's off.
    func stages(_ read: AzureDevOpsReader.PullRequests, now: Date = Date()) async -> AgentStages? {
        guard let kept = await reader.orderKept(now: now) else { return nil }
        let tasks = await reader.sendsToCopilot ? await reader.copilotTasks(now: now) : []
        let watched = Set(await reader.watchedPullRequests.map(\.key))
        let facts = await PullRequestOrderFacts.stages(read.records, items: read.items, tasks: tasks, watched: watched, readAt: read.readAt)
        let pullRequests = await PullRequestOrderFacts.pullRequests(read.records, items: read.items, showToReview: read.showToReview)
        // nil only while Copilot's off: one it couldn't read still lists the tasks BriefBar sent, as the app does.
        let copilot = await MCPRelated.stageSessions()
        let sentTasks = copilot == nil ? [] : tasks.compactMap(PullRequestOrderFacts.session)
        return Self.stages(
            facts: facts, pullRequests: pullRequests, copilot: copilot ?? MCPRelated.StageSessions(), sentTasks: sentTasks,
            kept: kept, account: read.account, now: now
        )
    }

    /// The same, from what was read: as `PullRequestOrder` rebuilds its missions and works its stages out, but noting and
    /// ending nothing, only in memory.
    /// - Parameter sentTasks: the tasks BriefBar sent to Copilot, which the app lists with the Copilot app's sessions,
    ///   unnamed, until you open one there, or, while it can't read the app's database, in place of their folders: what
    ///   they set counts too, while they're listed (`SessionStore`).
    static func stages(
        facts: [ItemRef: StageFacts], pullRequests: [OrderPullRequest], copilot: MCPRelated.StageSessions,
        sentTasks: [StageSession] = [], kept: OrderKept, account: String?, now: Date
    ) -> AgentStages {
        var copilot = copilot
        if !copilot.listedByApp {
            for task in sentTasks { copilot.listed[task.ref] = nil }
        }
        let orderFacts = OrderFacts(pullRequests: pullRequests, sessions: copilot.sessions, sourcesOn: [.pullRequest])
        var changes = kept.changes
        changes.noteOverrides(in: kept.orders, now: now)
        var evidence = kept.evidence
        let subjects = changes.subjects
        for observation in orderFacts.observations
        where kept.orders.refs.contains(observation.ref) || subjects.contains(observation.ref) {
            evidence.observe(observation, at: now)
        }
        let missions = OrderBoard.missions(
            facts: orderFacts, orders: kept.orders, evidence: evidence, focus: kept.focus, changes: changes, now: now
        )
        var sessionStages = kept.sessionStages
        for (ref, set) in kept.demoSessionMarks.sorted(by: { $0.key < $1.key }) {
            guard let session = set.by, let fact = facts[ref] else { continue }
            var stage = sessionStages[session] ?? SessionStage(session: session)
            stage.set(StageRules.mark(set.stage, at: set.at, facts: fact, by: session), of: ref)
            sessionStages.replace(stage)
        }
        var setters = copilot.doing
        for task in sentTasks where setters[task.ref] == nil {
            setters[task.ref] = StageSession(ref: task.ref, activity: task.activity, since: task.since)
        }
        let theirs = sessionStages.marks(listed: Set(setters.keys), now: now)
        let sessionsOn = copilot.onPullRequests
        var readings: [ItemRef: StageReading] = [:]
        for (ref, fact) in facts where fact.isListed {
            let sessions = PullRequestOrder.merged(fact.sessions, sessionsOn[ref] ?? [])
            var yours: StageMark?
            if let demo = kept.demoMarks[ref] {
                yours = StageRules.mark(demo.stage, at: demo.at, facts: fact)
            } else if fact.role != .sentToYou, let account {
                // One only sent to you in a chat keeps what you set on it in the app's memory, which `--mcp` can't read.
                yours = kept.marks.mark(of: ref, for: account)
            }
            let counted = StageRules.counted(
                yours: yours, theirs: theirs[ref] ?? [], facts: fact, sessions: sessions, setters: setters
            )
            let marks = [counted.yours].compactMap { $0 } + counted.theirs
            let order = StageOrder.of(ref, in: missions)
            if let reading = StageRules.reading(facts: fact, sessions: sessions, marks: marks, order: order, setters: setters) {
                readings[ref] = reading
            }
        }
        let board = PullRequestBoard.make(stages: readings, missions: missions, kinds: [.pullRequest], lanes: .none, picks: kept.picks)
        var columns: [PullRequestStage: [ItemRef]] = [:]
        for (stage, cards) in board.lanes.first?.columns ?? [:] {
            columns[stage] = cards.map(\.ref)
        }
        return AgentStages(readings: readings, columns: columns, names: copilot.listed.mapValues(\.name), now: now)
    }
}

extension AgentText {
    /// `needs_me`'s Stages: the Board in words, each stage the pull requests in it, what's next first, with why each is
    /// there, and who set it; nil with none.
    static func stages(_ stages: AgentStages, items: [PRSnapshot]) -> String? {
        let rows = Dictionary(items.map { ($0.key.linkRef, $0) }, uniquingKeysWith: { first, _ in first })
        var lines: [String] = []
        for stage in AgentStages.told {
            let refs = (stages.columns[stage] ?? []).filter { rows[$0] != nil && stages.readings[$0] != nil }
            guard !refs.isEmpty else { continue }
            lines.append("- \(stage.columnTitle) (\(refs.count)):")
            for ref in refs {
                guard let item = rows[ref], let reading = stages.readings[ref] else { continue }
                lines.append(
                    "  - !\(item.key.number) “\(QuotedText.oneLine(item.title))” in \(QuotedText.oneLine(item.repository)): "
                        + words(reading, stages: stages)
                )
            }
        }
        guard !lines.isEmpty else { return nil }
        return "Stages, as BriefBar's Board shows them, what's next first:\n" + lines.joined(separator: "\n")
    }

    /// `pull_request`'s stage: "Its stage: Your review: ‘Cart’ says it's ready (‘Cart’ set it 5m ago, after you). You'd set
    /// Teammate's review 2h ago, which a session's later change replaced: you can put yours back."
    static func stage(_ reading: StageReading, stages: AgentStages) -> String {
        var line = "Its stage: \(reading.stage.title): \(words(reading, stages: stages))."
        if let yours = reading.replaced {
            line += " You'd set \(yours.stage.title) \(StageText.agoWords(yours.at, now: stages.now)), which a session's later "
                + "change replaced: you can put yours back."
        }
        return line
    }

    /// Why it's in its stage, in BriefBar's words, with what fails too, as the Board says, when that happened, if that's
    /// what it says, and who set it: "Priya asked you", "‘Cart’ finished, 10m ago", "Nobody's asked to review it yet · build
    /// failed (You set it 2h ago)", "‘Cart’ says it's ready (set 5m ago, after you)". What sessions and people are called
    /// is quoted as other tools quote what others named (`QuotedText.inLine`), so all of it stays on its line.
    static func words(_ reading: StageReading, stages: AgentStages) -> String {
        var words = switch reading.why {
        case .findReviewer: "Nobody's asked to review it yet" + StageText.alsoFailing(reading)
        case .ready(autoComplete: false): "Ready to complete" + StageText.alsoFailing(reading)
        default: StageText.why(reading, name: stages.name)
        }
        if reading.why.saysWhen, let since = reading.since { words += ", \(ago(since, now: stages.now))" }
        // Where its words name the session that set it, only when: "(set 5m ago)", as the app says it.
        if let who = StageText.who(reading, now: stages.now, name: stages.name) { words += " (\(who))" }
        return QuotedText.inLine(words)
    }
}
