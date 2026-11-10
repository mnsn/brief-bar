import AzureDevOpsCore
import BriefBarCore
import CopilotTasks
import Foundation

/// A prompt about some of a pull request that BriefBar sent to one of the Copilot app's sessions, or to a fork of it, or
/// copied for you to paste there (`CopilotTasksStore.deliver`): which session took it, what it took on (comment threads, a
/// build, its conflicts), what for and when, kept with Send Work to Copilot's runs (`ado.copilot.sentPrompts`) by references
/// only, never what it says, for as long as a link you make (`LinkEdits.lifetime`). Copilot works on it in the app, which
/// BriefBar doesn't run, so what became of it is what the session's log says from then on (`SessionTurn`), which BriefBar
/// follows until its turn ends (`CopilotTasksStore.followSentPrompts`).
struct SentPrompt: Codable, Equatable, Sendable, Identifiable {
    /// What it asked.
    enum Purpose: String, Codable, Sendable {
        /// Fix, on a thread or a build, Fix Comments, on the threads that waited on you, or resolving the conflicts.
        case fix
        /// Explain, as a prompt the session takes up itself, when it can't be asked aside.
        case explain
        /// Push & Reply, which ships what the fixes changed.
        case pushAndReply
    }

    /// What it's about, as it's sent: the pull request, what for, and what of it it takes on, with the pull request's target
    /// branch, which the conflicts it takes on are with; and, for Push & Reply, whether it fixes what it takes on first, as a
    /// comment's Fix sent with Push and Reply on does, with the commit the pull request's branch is at as it goes, as the
    /// list has read it, which `CopilotTasksStore.keep` fills in.
    struct About: Equatable, Sendable {
        var pullRequest: PRKey
        var purpose: Purpose
        var parts: [PullRequestPart]
        var target: String? = nil
        var fixes = false
        var head: String? = nil
    }

    /// The pull request.
    var pullRequest: ItemRef
    /// The session that took it: the session itself, or its fork.
    var session: String
    /// The session it forked, for a fork.
    var forkedFrom: String?
    /// It was copied as `/fork <prompt>`, for the Copilot app to fork `session` as you paste it: the fork isn't known yet.
    var awaitsFork: Bool
    var purpose: Purpose
    /// What it took on: threads, a build, the conflicts.
    var parts: [PullRequestPart]
    /// For the conflicts, the pull request's target branch as it was sent: with another, they're other conflicts
    /// (`CopilotTasksStore.endWorkThatsOver`). Nil otherwise, and for prompts BriefBar kept before it had this.
    var target: String?
    /// A Push & Reply that fixes the threads it takes on first, as a comment's Fix sent with Push and Reply on does
    /// (`TakenPart.fixes`). Nil otherwise, and for prompts BriefBar kept before it had this.
    var fixes: Bool?
    /// For one that fixes them first, the commit the pull request's branch was at as it was sent, as the list had read it
    /// (`PullRequest.sourceCommit`): once its turn finished, it pushed only if the list reads another since, as its prompt
    /// has it stop before it pushes when the tests don't pass, say (`CopilotTasksStore.seesPush(since:of:)`). Nil otherwise,
    /// when the list didn't have it, and for prompts BriefBar kept before it had this.
    var head: String?
    var sentAt: Date
    /// BriefBar copied it for you to paste, rather than sending it itself.
    var copied: Bool
    /// How its turn ended, as the session's log said once it did.
    var ended: RunPhase?
    /// Another prompt went to its session before its turn was seen to end: which turn's end is its, BriefBar can't tell
    /// from the session's log, so it says it doesn't know rather than take the later one's.
    var overlapped = false
    /// BriefBar stopped following its turn, which it didn't see end within `followLimit`, as when its session waited
    /// overnight for your answer: it says it doesn't know how it went, rather than forget it.
    var lostTrack = false

    var id: String { "\(session)/\(sentAt.timeIntervalSince1970)" }

    /// BriefBar follows its turn: it hasn't been seen to end, no other prompt went to its session before it was, and
    /// BriefBar hasn't stopped following it.
    var isFollowed: Bool { ended == nil && !overlapped && !lostTrack }

    /// The fork that took a prompt copied as `/fork`: the one fork the Copilot app made of its session since, as
    /// `SessionSender` finds one. With more, any could be another fork's, so none is.
    static func onlyFork(_ forks: [String]?) -> String? {
        guard let forks, forks.count == 1 else { return nil }
        return forks[0]
    }

    /// Nil when a session's ID isn't one.
    init?(
        _ about: About, session: String, forkedFrom: String? = nil, awaitsFork: Bool = false, sentAt: Date, copied: Bool,
        ended: RunPhase? = nil
    ) {
        guard AppSessions.isSessionID(session), forkedFrom.map(AppSessions.isSessionID) ?? true else { return nil }
        pullRequest = about.pullRequest.linkRef
        self.session = session
        self.forkedFrom = forkedFrom
        self.awaitsFork = awaitsFork
        purpose = about.purpose
        parts = about.parts
        target = about.parts.contains(.conflicts) ? about.target.flatMap { $0.isEmpty ? nil : $0 } : nil
        fixes = about.purpose == .pushAndReply && about.fixes ? true : nil
        head = fixes == true ? about.head.flatMap { $0.isEmpty ? nil : $0 } : nil
        self.sentAt = sentAt
        self.copied = copied
        self.ended = ended
    }

    /// Checked as when it was made: any program running as you can write the preferences.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pullRequest = try container.decode(ItemRef.self, forKey: .pullRequest)
        session = try container.decode(String.self, forKey: .session)
        forkedFrom = try container.decodeIfPresent(String.self, forKey: .forkedFrom)
        awaitsFork = try container.decodeIfPresent(Bool.self, forKey: .awaitsFork) ?? false
        purpose = try container.decode(Purpose.self, forKey: .purpose)
        parts = try container.decode([PullRequestPart].self, forKey: .parts)
        target = try container.decodeIfPresent(String.self, forKey: .target)
        fixes = try container.decodeIfPresent(Bool.self, forKey: .fixes)
        head = try container.decodeIfPresent(String.self, forKey: .head)
        sentAt = try container.decode(Date.self, forKey: .sentAt)
        copied = try container.decodeIfPresent(Bool.self, forKey: .copied) ?? false
        ended = try container.decodeIfPresent(RunPhase.self, forKey: .ended)
        overlapped = try container.decodeIfPresent(Bool.self, forKey: .overlapped) ?? false
        lostTrack = try container.decodeIfPresent(Bool.self, forKey: .lostTrack) ?? false
        guard pullRequest.kind == .pullRequest, AppSessions.isSessionID(session), forkedFrom.map(AppSessions.isSessionID) ?? true else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a prompt to a session"))
        }
    }

    func isFor(_ key: PRKey) -> Bool {
        pullRequest == key.linkRef
    }

    /// How long a prompt is kept: as long as a link you make, by when it was sent.
    static let lifetime = LinkEdits.lifetime
    /// The most kept, the latest.
    static let limit = 200
    /// How long BriefBar waits for you to paste one it copied, or for the fork you paste it in to be made.
    static let pasteWait: TimeInterval = 30 * 60
    /// How long BriefBar follows one whose turn hasn't ended: then it stops, and says it doesn't know how it went
    /// (`lostTrack`).
    static let followLimit: TimeInterval = 12 * 3_600

    /// The ones kept in the preferences, the oldest first: without what can't be read, such as what another program wrote
    /// there, and those older than `lifetime`. One still followed after `followLimit`, as when BriefBar didn't run
    /// meanwhile, stays for BriefBar to read its session's log once more: what it finds there says whether it ended,
    /// or whether BriefBar stops following it.
    static func load(from defaults: UserDefaults, now: Date = Date()) -> [SentPrompt] {
        guard let data = defaults.data(forKey: SettingsKey.copilotSentPrompts),
              let records = try? JSONDecoder().decode([Lossy].self, from: data)
        else { return [] }
        return kept(records.compactMap(\.value), now: now)
    }

    /// Leaves in the preferences only what `load` kept of them, when they hold more or other.
    static func prune(to kept: [SentPrompt], in defaults: UserDefaults) {
        guard defaults.object(forKey: SettingsKey.copilotSentPrompts) != nil else { return }
        let records = defaults.data(forKey: SettingsKey.copilotSentPrompts)
            .flatMap { try? JSONDecoder().decode([Lossy].self, from: $0) }?.map(\.value)
        guard records != kept.map(Optional.some) else { return }
        if !kept.isEmpty, let data = try? JSONEncoder().encode(kept) {
            defaults.set(data, forKey: SettingsKey.copilotSentPrompts)
        } else {
            defaults.removeObject(forKey: SettingsKey.copilotSentPrompts)
        }
    }

    static func kept(_ prompts: [SentPrompt], now: Date) -> [SentPrompt] {
        let cutoff = now.addingTimeInterval(-lifetime)
        let kept = prompts.filter { $0.sentAt >= cutoff && $0.sentAt <= now.addingTimeInterval(60) }
        return Array(kept.sorted { $0.sentAt < $1.sentAt }.suffix(limit))
    }

    /// A prompt that decodes to nil instead of failing, so one odd record doesn't lose the rest.
    private struct Lossy: Decodable {
        var value: SentPrompt?

        init(from decoder: Decoder) throws {
            value = try? decoder.singleValueContainer().decode(SentPrompt.self)
        }
    }
}

/// What Copilot does, or did, about something of a pull request, a comment thread, a build or its conflicts, for its
/// status line: the latest work that took it on, a task of BriefBar's (`CopilotRun.taken`) or a prompt sent to one of the
/// Copilot app's sessions (`SentPrompt`), in the session that works on it.
struct CopilotWork: Equatable {
    enum Purpose: Equatable {
        case fix, explain, pushAndReply
    }

    enum State: Equatable {
        /// Sent, but not taken up yet: copied for you to paste, or waiting for its session.
        case waiting(copied: Bool)
        /// Copilot works on it, at this step when it says.
        case working(String?)
        /// Its session asks you something, in the Copilot app.
        case needsYou
        /// Done, saying this when it said something.
        case done(String?)
        case failed(String?)
        case stopped
        /// Sent, or copied for you to paste, but another prompt went to the session before its turn was seen to end: how
        /// it went isn't known.
        case unknown(copied: Bool)
    }

    /// What it's about.
    var part: PullRequestPart
    var purpose: Purpose
    var state: State
    /// The session that works on it: its ID, the fork's for a fork.
    var session: String
    /// The session it forked, for a fork.
    var forkedFrom: String?
    /// A task of BriefBar's, which it runs with the Copilot CLI; otherwise one of the Copilot app's sessions.
    var isTask: Bool
    /// When it was taken on, or, once it's over, when it ended.
    var since: Date
    /// When it was taken on, whether it's over or not, and whichever task in its session keeps it now: a Push & Reply's,
    /// when it started to push, which a run of the build that fails after it was a run of what it pushed, or since.
    var takenAt: Date?
    /// For Push & Reply on a thread: it replies on it, as its prompt lists it. False for a thread whose fix it pushes along
    /// with all else its session changed, without replying on it (`CopilotTasksStore.work(on:of:for:)`).
    var replies = true
    /// For Push & Reply: it fixed what it's about first, as a comment's Fix, or Fix All, sent with Push and Reply on does
    /// (`TakenPart.fixes`, `SentPrompt.fixes`), so its sentences say it fixed it, and one that failed or stopped isn't
    /// offered to push, as a fix that did isn't. False for a fix it pushes along with all else its session changed.
    var fixes = false
    /// For one that fixed it first, the commit the pull request's branch was at as it was sent (`TakenPart.head`,
    /// `SentPrompt.head`); nil when that isn't known.
    var head: String?
    /// For one that fixed it first, done: the list has read the pull request's branch at another commit since it was sent
    /// (`CopilotTasksStore.seesPush(since:of:)`), which says it pushed. Its prompt has it stop before it pushes, as when the
    /// tests don't pass, or the pull request was retargeted, and end its turn all the same: without this, it says it fixed
    /// it, but that it's not pushed.
    var pushSeen = false

    /// Ongoing, rather than over.
    var isActive: Bool {
        switch state {
        case .waiting, .working, .needsYou: true
        case .done, .failed, .stopped, .unknown: false
        }
    }

    /// A fix that's done, and not pushed.
    var isReadyFix: Bool {
        if purpose == .fix, case .done = state { return true }
        return false
    }

    /// What was changed for it isn't pushed: a fix that's done, or a Push & Reply of it that failed or stopped, to try
    /// again; not one that fixed it first, whose fix may not be done.
    var waitsToBePushed: Bool {
        switch (purpose, state) {
        case (.fix, .done): true
        case (.pushAndReply, .failed), (.pushAndReply, .stopped): !fixes
        default: false
        }
    }

    /// Where it is, in a sentence's middle: "‘Retry backoff’", "a fork of ‘Retry backoff’", "its session"; a task of
    /// BriefBar's as one, "the ‘Fix the Build’ task" (`quoted(_:isTask:)`).
    /// - Parameters:
    ///   - name: the session's name; nil when it isn't known.
    ///   - forkOf: for a fork, the name of the session it forked, when that's known.
    ///   - isTask: the session, or the one a fork forked, is a task of BriefBar's.
    static func place(_ name: String?, isFork: Bool, forkOf: String?, isTask: Bool = false) -> String {
        let place = (isFork ? forkOf : name).map { quoted($0, isTask: isTask) } ?? "its session"
        return isFork ? "a fork of " + place : place
    }

    /// A session's name, quoted, as a sentence says it: "‘Retry backoff’"; a task of BriefBar's, named for what it does, as
    /// a task, "the ‘Fix the Build’ task", so that it doesn't read as a command.
    static func quoted(_ name: String, isTask: Bool) -> String {
        isTask ? "the ‘\(name)’ task" : "‘\(name)’"
    }

    /// What it says on what it's about, in a sentence: "Copilot is fixing this in ‘Retry backoff’", "Fixing this build in a
    /// fork of ‘Retry backoff’", "Fixed in ‘Retry backoff’, not pushed", "Couldn't fix it in ‘Retry backoff’", "Pushed from
    /// ‘Retry backoff’, without a reply"; for a Push & Reply that fixes it first (`fixes`), "Copilot is fixing this in ‘Retry
    /// backoff’, to push and reply", then "Fixed, pushed and replied in ‘Retry backoff’" once its push is seen (`pushSeen`),
    /// else "Fixed in ‘Retry backoff’, but not pushed". What Copilot said as it ended, such as why it couldn't, goes under
    /// it (`said`).
    /// - Parameters:
    ///   - name: the session's name; nil when it isn't known.
    ///   - forkOf: for a fork, the name of the session it forked.
    func sentence(name: String?, forkOf: String?) -> String {
        let fork = forkedFrom != nil
        let place = Self.place(name, isFork: fork, forkOf: forkOf, isTask: isTask)
        let words = Words(part, replies: replies)
        switch (purpose, state) {
        case (_, .waiting(copied: true)):
            return "Copied for \(place): paste it there"
        case (.pushAndReply, .working) where fixes:
            let fixing = "\(words.fixing) in \(place), \(words.toShip)"
            return fork ? Self.capitalized(fixing) : "Copilot is \(fixing)"
        case (.pushAndReply, .waiting(copied: false)) where fixes:
            return "Sent to \(place)"
        case (.pushAndReply, .waiting), (.pushAndReply, .working):
            return "\(words.pushing) from \(place)"
        case (_, .waiting(copied: false)):
            return "Sent to \(place)"
        case (_, .needsYou):
            return "\(Self.capitalized(place)) is waiting for your answer"
        case (.fix, .working):
            return fork ? "\(Self.capitalized(words.fixing)) in \(place)" : "Copilot is \(words.fixing) in \(place)"
        case (.explain, .working):
            return fork ? "\(Self.capitalized(words.explaining)) in \(place)" : "Copilot is \(words.explaining) in \(place)"
        case (.fix, .done):
            return "\(words.fixed) in \(place), not pushed"
        case (.explain, .done):
            return "Answered in \(place)"
        case (.pushAndReply, .done) where fixes:
            return pushSeen ? "\(words.fixedAndPushed) in \(place)" : "\(words.fixed) in \(place), but not pushed"
        case (.pushAndReply, .done):
            return "\(words.pushed) from \(place)" + (part.thread != nil && !replies ? ", without a reply" : "")
        case (_, .failed):
            let what = purpose == .explain ? "explain it" : purpose == .pushAndReply ? (fixes ? words.fixAndPushIt : "push it") : words.fixIt
            return "Couldn't \(what) in \(place)"
        case (_, .stopped):
            let what = purpose == .explain ? "answered" : purpose == .pushAndReply ? "pushed it" : words.fixedIt
            return "Stopped in \(place) before it \(what)"
        case (_, .unknown(let copied)):
            return copied ? "Copied for \(place) · see the session" : "Sent to \(place) · see the session"
        }
    }

    /// The words its sentences say it in, for what it's about.
    private struct Words {
        /// "fixing this", "fixing this build", "resolving the conflicts".
        var fixing: String
        /// "explaining this", "explaining the failure".
        var explaining: String
        /// "Fixed", "Resolved".
        var fixed: String
        /// "fix it", "resolve them".
        var fixIt: String
        /// "fixed it", "resolved them".
        var fixedIt: String
        /// "Pushing and replying", for a thread its Push & Reply replies on; "Pushing" for the rest.
        var pushing: String
        var pushed: String
        /// For a Push & Reply that fixes it first: what for, "to push and reply", for a thread; "to push" for the rest.
        var toShip: String
        /// For a Push & Reply that fixes it first: "Fixed, pushed and replied", "Fixed and pushed", "Resolved and pushed".
        var fixedAndPushed: String
        /// For a Push & Reply that fixes it first: "fix and push it", "resolve and push them".
        var fixAndPushIt: String

        /// - Parameter replies: for a thread, its Push & Reply replies on it.
        init(_ part: PullRequestPart, replies: Bool = true) {
            switch part {
            case .thread:
                fixing = "fixing this"
                explaining = "explaining this"
                fixed = "Fixed"
                fixIt = "fix it"
                fixedIt = "fixed it"
                pushing = replies ? "Pushing and replying" : "Pushing"
                pushed = replies ? "Pushed and replied" : "Pushed"
                toShip = replies ? "to push and reply" : "to push"
                fixedAndPushed = replies ? "Fixed, pushed and replied" : "Fixed and pushed"
                fixAndPushIt = "fix and push it"
            case .build:
                fixing = "fixing this build"
                explaining = "explaining the failure"
                fixed = "Fixed"
                fixIt = "fix it"
                fixedIt = "fixed it"
                pushing = "Pushing"
                pushed = "Pushed"
                toShip = "to push"
                fixedAndPushed = "Fixed and pushed"
                fixAndPushIt = "fix and push it"
            case .conflicts:
                fixing = "resolving the conflicts"
                explaining = "explaining the conflicts"
                fixed = "Resolved"
                fixIt = "resolve them"
                fixedIt = "resolved them"
                pushing = "Pushing"
                pushed = "Pushed"
                toShip = "to push"
                fixedAndPushed = "Resolved and pushed"
                fixAndPushIt = "resolve and push them"
            }
        }
    }

    private static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    /// From a task of BriefBar's that took it on (`CopilotRun.taken`), to fix it, or to push its fix, and reply on a
    /// thread, or to fix it first then do so, as it stands, or as it ended once a later task went on with its session.
    static func from(_ entry: CopilotTaskEntry, taken: TakenPart) -> CopilotWork {
        let isTask = entry.run?.isAppSession != true
        // Push & Reply ships what it took on; the others it has, it doesn't reply on, and they stay as they were.
        let purpose: Purpose = taken.ships == true ? .pushAndReply : .fix
        let fixes = purpose == .pushAndReply && taken.fixes == true
        let head = fixes ? taken.head : nil
        // Taken on by an earlier task in the session, which a later one went on with.
        if let before = taken.ended {
            let state: State = switch before {
            case .finished: .done(nil)
            case .failed: .failed(nil)
            case .stopped, .preparing, .working: .stopped
            }
            return CopilotWork(
                part: taken.part, purpose: purpose, state: state, session: entry.id, forkedFrom: entry.forkedFrom, isTask: isTask,
                since: taken.since, takenAt: taken.since, fixes: fixes, head: head
            )
        }
        let ended = entry.status.phase.isActive ? nil : entry.status.since
        return CopilotWork(
            part: taken.part, purpose: purpose, state: state(of: entry.status), session: entry.id, forkedFrom: entry.forkedFrom,
            isTask: isTask, since: ended ?? taken.since, takenAt: taken.since, fixes: fixes, head: head
        )
    }

    private static func state(of status: RunStatus) -> State {
        switch status.phase {
        case .preparing: .working(nil)
        case .working: .working(status.detail)
        case .finished: .done(status.detail)
        case .failed: .failed(status.detail)
        case .stopped: .stopped
        }
    }

    /// From a prompt sent to one of the Copilot app's sessions about it, as its turn stands (`SessionTurn`), or as it ended.
    static func from(_ prompt: SentPrompt, about part: PullRequestPart, turn: SessionTurn?) -> CopilotWork {
        let purpose: Purpose = switch prompt.purpose {
        case .fix: .fix
        case .explain: .explain
        case .pushAndReply: .pushAndReply
        }
        var state: State
        var since = prompt.sentAt
        switch turn?.phase {
        case .working(let step)?: state = .working(step)
        case .needsYou?: state = .needsYou
        case .finished(let summary)?: state = .done(summary)
        case .failed(let reason)?: state = .failed(reason)
        case .stopped?: state = .stopped
        case .waiting?, nil: state = .waiting(copied: prompt.copied)
        }
        if let turn, turn.isOver || turn.phase == .needsYou { since = turn.since ?? since }
        // As it ended, after BriefBar restarted: without what Copilot said, which isn't kept.
        if turn == nil || turn?.isOver == false, let ended = prompt.ended {
            state = switch ended {
            case .finished: .done(nil)
            case .failed: .failed(nil)
            case .stopped, .preparing, .working: .stopped
            }
        }
        if prompt.overlapped || prompt.lostTrack { state = .unknown(copied: prompt.copied) }
        let fixes = purpose == .pushAndReply && prompt.fixes == true
        return CopilotWork(
            part: part, purpose: purpose, state: state, session: prompt.session, forkedFrom: prompt.forkedFrom, isTask: false, since: since,
            takenAt: prompt.sentAt, fixes: fixes, head: fixes ? prompt.head : nil
        )
    }
}

/// The fixes done in a session and not pushed yet, for the bar at the foot of a pull request's details: "2 fixes ready in
/// ‘Retry backoff’".
struct ReadyFixes: Equatable, Identifiable {
    /// The session they're in: its ID, the fork's for a fork.
    var session: String
    var forkedFrom: String?
    /// A task of BriefBar's, which it runs with the Copilot CLI; otherwise one of the Copilot app's sessions.
    var isTask: Bool
    /// What they fixed: threads, builds, the conflicts.
    var parts: [PullRequestPart]
    /// When the latest was done.
    var latest: Date

    var id: String { session }

    /// The threads they fixed.
    var threads: [Int] { parts.compactMap(\.thread) }
}

extension CopilotTasksStore {
    /// Copilot's latest work on something of a pull request, a comment thread, a build or its conflicts, as its status line
    /// says it: a task of BriefBar's that took it on, or a prompt sent to one of the Copilot app's sessions about it, whichever
    /// took it on last. A fix done in a session, or a Push & Reply of it there that failed or stopped, is pushed with the
    /// rest of what the session changed by a Push & Reply that went on with the session since, or by a fix that pushed from
    /// a fork of it made since, though that replies only on the threads its prompt lists (`pushCarrying`). One that fixed it
    /// first, done, says it pushed only once the list reads the push (`CopilotWork.pushSeen`). Nil when none did, while Send
    /// Work to Copilot is off, and for what the demo made nothing up for.
    /// - Parameter purposes: only work for these, such as fixes and shipping them, past a question asked since.
    func work(on part: PullRequestPart, of key: PRKey, for purposes: Set<CopilotWork.Purpose>? = nil) -> CopilotWork? {
        guard isOn, mode != .demo || !clearedInDemo.contains(PartKey(pullRequest: key, part: part)) else { return nil }
        var latest: (since: Date, work: CopilotWork)?
        func consider(_ since: Date, _ work: CopilotWork) {
            if let purposes, !purposes.contains(work.purpose) { return }
            if latest.map({ since > $0.since }) ?? true { latest = (since, work) }
        }
        for entry in entries where entry.isOn(key) {
            guard let taken = entry.taken?.first(where: { $0.part == part }) else { continue }
            // One the session's latest task took on, as it started; one an earlier task did, as that one did.
            consider(taken.ended == nil ? entry.startedAt : taken.since, CopilotWork.from(entry, taken: taken))
        }
        for (prompt, turn) in prompts(about: key) where prompt.parts.contains(part) {
            consider(prompt.sentAt, CopilotWork.from(prompt, about: part, turn: turn))
        }
        guard var work = latest?.work else { return nil }
        if work.waitsToBePushed, purposes?.contains(.pushAndReply) != false, let push = pushCarrying(work, of: key) { return push }
        if work.fixes, case .done = work.state { work.pushSeen = seesPush(since: work.head, of: key) }
        return work
    }

    /// The prompts sent to the Copilot app's sessions about a pull request, each with its turn as it stands: the demo's
    /// made up.
    private func prompts(about key: PRKey) -> [(prompt: SentPrompt, turn: SessionTurn?)] {
        var prompts = settings.copilotSentPrompts.filter { $0.isFor(key) }.map { (prompt: $0, turn: promptTurns[$0.id]) }
        if mode == .demo { prompts += SentPrompt.demo(now: Date()).filter { $0.prompt.isFor(key) } }
        return prompts
    }

    /// The Push & Reply that pushed a fix along with the rest of what its session changed, since the fix, or a push of it
    /// that failed or stopped, was taken on; or that pushes it now. It commits and pushes all that the session changed,
    /// whatever its prompt lists, so it pushes a fix it doesn't list along with the rest, though it doesn't reply on it
    /// (`CopilotWork.replies`). A task of BriefBar's, the session's now or one that ran there before (`CopilotRun.pushes`,
    /// and, for runs kept before BriefBar had that, what each shipped), or a prompt sent to the session; or a fix sent with
    /// Push and Reply on to a fork of the session made once the fix was over, which pushes what the fork has of it: the
    /// Copilot app's fork has all the session changed, its changes that aren't committed too, but a fork the Copilot CLI
    /// made of one of BriefBar's tasks starts at the commit its checkout had, with the conflicts' resolution, which Resolve
    /// Conflicts commits, and no other fix, which nothing else commits. The first that finished, which pushed it, whatever
    /// came after it, such as one that failed; else the latest still under way; nil when none did, or each failed, stopped,
    /// waits for you to paste it, or went BriefBar doesn't know how. One that fixed what it took on first pushed only once
    /// the list read its push (`seesPush(since:of:)`), since its prompt has it stop before it pushes, as when the tests
    /// don't pass.
    private func pushCarrying(_ fix: CopilotWork, of key: PRKey) -> CopilotWork? {
        var pushed: (since: Date, work: CopilotWork)?
        var pushing: (since: Date, work: CopilotWork)?
        /// - Parameter after: when what it pushes was there to push: in the session, once the fix was taken on; in a fork,
        ///   made once the fix was over.
        func consider(_ since: Date, _ work: CopilotWork, after: Date) {
            guard since > after else { return }
            switch work.state {
            case .done:
                guard !work.fixes || seesPush(since: work.head, of: key) else { return }
                if pushed.map({ since < $0.since }) ?? true { pushed = (since, work) }
            case .waiting(copied: false), .working, .needsYou:
                if pushing.map({ since > $0.since }) ?? true { pushing = (since, work) }
            case .waiting(copied: true), .failed, .stopped, .unknown:
                break
            }
        }
        /// When what a push from a session would push of the fix was there: in the session itself, once the fix was taken
        /// on; in a fork of it made once the fix was over, as it was made, unless it's one the Copilot CLI made of one of
        /// BriefBar's tasks, which has only what the session committed, and the fix isn't the conflicts' resolution. Nil
        /// when it has none of it.
        func carried(by session: String, forkedFrom: String?, madeAt: Date, committedOnly: Bool) -> Date? {
            if session == fix.session { return fix.takenAt ?? fix.since }
            guard forkedFrom == fix.session, madeAt > fix.since, !committedOnly || fix.part == .conflicts else { return nil }
            return fix.since
        }
        for entry in entries where entry.isOn(key) {
            // A fork's session was made as its first task started, the earliest it kept.
            let kept = (entry.pushes ?? []).map(\.since) + (entry.taken ?? []).map(\.since)
            let madeAt = kept.reduce(entry.startedAt, min)
            let committedOnly = entry.run?.isAppSession != true
            let carrying = carried(by: entry.id, forkedFrom: entry.forkedFrom, madeAt: madeAt, committedOnly: committedOnly)
            guard let after = carrying else { continue }
            if entry.action == .pushAndReply {
                let ships = TakenPart(
                    fix.part, since: entry.startedAt, ships: true, fixes: entry.fixesFirst ? true : nil, head: entry.fixingHead
                )
                consider(entry.startedAt, CopilotWork.from(entry, taken: ships), after: after)
            }
            var before = (entry.pushes ?? []).map { push in
                TakenPart(fix.part, since: push.since, ended: push.ended, ships: true, fixes: push.fixes, head: push.head)
            }
            for shipped in entry.taken ?? [] where shipped.ships == true && shipped.ended != nil {
                before.append(TakenPart(
                    fix.part, since: shipped.since, ended: shipped.ended, ships: true, fixes: shipped.fixes, head: shipped.head
                ))
            }
            for push in before {
                consider(push.since, CopilotWork.from(entry, taken: push), after: after)
            }
        }
        for (prompt, turn) in prompts(about: key) where prompt.purpose == .pushAndReply {
            // The Copilot app's fork, made as the prompt went, with all the session changed.
            let carrying = carried(by: prompt.session, forkedFrom: prompt.forkedFrom, madeAt: prompt.sentAt, committedOnly: false)
            guard let after = carrying else { continue }
            consider(prompt.sentAt, CopilotWork.from(prompt, about: fix.part, turn: turn), after: after)
        }
        guard var push = (pushed ?? pushing)?.work else { return nil }
        // It pushed this fix along, without replying on it, whatever it fixed itself first.
        push.replies = false
        push.fixes = false
        return push
    }

    /// The fixes of a pull request's threads, builds and conflicts that are done and not pushed, by the session they're in,
    /// the latest first: only those of `parts`, what's still to fix, such as its open threads, the builds that don't pass and
    /// its conflicts while it has them; and those a Push & Reply that failed or stopped didn't push. A question asked about
    /// one since, as its line says, doesn't push its fix.
    func readyFixes(of key: PRKey, among parts: [PullRequestPart]) -> [ReadyFixes] {
        var groups: [String: ReadyFixes] = [:]
        for part in parts {
            guard let work = work(on: part, of: key, for: [.fix, .pushAndReply]), work.waitsToBePushed else { continue }
            var group = groups[work.session] ?? ReadyFixes(
                session: work.session, forkedFrom: work.forkedFrom, isTask: work.isTask, parts: [], latest: work.since
            )
            if !group.parts.contains(part) { group.parts.append(part) }
            group.latest = max(group.latest, work.since)
            groups[work.session] = group
        }
        return groups.values.sorted { ($0.latest, $0.session) > ($1.latest, $1.session) }
    }

    /// What a pull request's menus can push, by session, as the bar at the foot of its details has it (`readyFixes`), each
    /// for a Push & Reply that ships those alone, in that session; with none ready, what its last task changed, which a
    /// push ships, with the builds and conflicts fixed there, replying on no thread: not once what it took on itself was
    /// let go, and none of it is left, as it's over, such as a resolution of conflicts that are gone or with another target
    /// branch, or you cleared it (`CopilotRun.workLetGo`); but one that took on nothing itself, as it went on with a
    /// session, is. Only on an open pull request of yours.
    func pushes(of record: PRRecord) -> [ReadyFixes] {
        guard isOn, record.pullRequest.status == .active, record.role == .author else { return [] }
        let key = record.pullRequest.key
        let ready = readyFixes(of: key, among: record.partsToFix)
        guard ready.isEmpty else { return ready }
        guard let run = continuable(forPullRequest: key), run.action?.changesCode == true, run.ended == .finished,
              run.workLetGo != true || run.taken?.contains(where: { $0.ended == nil }) == true
        else { return [] }
        return [ReadyFixes(
            session: run.id, forkedFrom: run.forkedFrom, isTask: run.isAppSession != true, parts: unpushedParts(of: key, in: run.id),
            latest: run.startedAt
        )]
    }

    /// What Copilot does now about each kind of what's left of a pull request (`PRReadiness`), its comments, builds and
    /// conflicts: the most pressing of the fixes, and Push & Reply, under way on their threads, builds or conflicts, by a task
    /// of BriefBar's or a prompt sent to one of the Copilot app's sessions (`work(on:of:)`); asking you something first,
    /// then at work, then sent and not taken up yet. A prompt copied for you to paste, which waits on you, or a question
    /// asked about one, isn't Copilot taking care of it.
    func onIt(_ record: PRRecord) -> [PRReadiness.Item.Kind: CopilotWork] {
        let key = record.pullRequest.key
        return onIt(record) { work(on: $0, of: key, for: [.fix, .pushAndReply]) }
    }

    /// What Copilot does about each kind of what's left of a pull request, from what `work` says it does about each of its
    /// threads, builds and conflicts: in pictures, as they draw it.
    func onIt(_ record: PRRecord, work: (PullRequestPart) -> CopilotWork?) -> [PRReadiness.Item.Kind: CopilotWork] {
        let threads = (record.details?.threads ?? []).filter { !$0.isResolved }.map { PullRequestPart.thread($0.id) }
        var builds: [PullRequestPart] = []
        for case let part? in (record.details?.checks ?? []).map(\.part) where !builds.contains(part) {
            builds.append(part)
        }
        let kinds: [(PRReadiness.Item.Kind, [PullRequestPart])] = [(.comments, threads), (.builds, builds), (.conflicts, [.conflicts])]
        var onIt: [PRReadiness.Item.Kind: CopilotWork] = [:]
        for (kind, parts) in kinds {
            let works = parts.compactMap(work).filter { $0.purpose == .fix || $0.purpose == .pushAndReply }
            if let work = works.max(by: { Self.pressing($0) < Self.pressing($1) }), Self.pressing(work) > 0 {
                onIt[kind] = work
            }
        }
        return onIt
    }

    /// How pressing Copilot's work is for what's left: it asks you something, then it's at work, then it's sent; none once
    /// it's over, or copied for you to paste.
    private static func pressing(_ work: CopilotWork) -> Int {
        switch work.state {
        case .needsYou: 3
        case .working: 2
        case .waiting(copied: false): 1
        case .waiting(copied: true), .done, .failed, .stopped, .unknown: 0
        }
    }

    /// What of a pull request Copilot's work on is over: a build, once a run of it passed; its conflicts, once it merges
    /// cleanly, or targets another branch than the one they were with.
    private struct Over {
        var key: PRKey
        var part: PullRequestPart
        /// What was taken on of it before then is over: when the build's run passed, or when the list read the pull request
        /// merging cleanly.
        var at: Date?
        /// For conflicts, the pull request's target branch: those taken on with another are other conflicts, whenever that
        /// was. Nil when it isn't known.
        var target: String?

        /// Whether it ends what was taken on of `part` at `since`, with the pull request targeting `taken`.
        func ends(_ part: PullRequestPart, takenAt since: Date, target taken: String?) -> Bool {
            guard part == self.part else { return false }
            if let at, since < at { return true }
            if let target, let taken, taken != target { return true }
            return false
        }
    }

    /// Ends what Copilot took on of pull requests that's over: of a build that a run passed after; and of the conflicts of
    /// one that merges cleanly since, as the list read it, or that targets another branch than the one they were with, as
    /// when it was retargeted, since a resolution merged the target branch it had. A fix of one, done or not, pushed or not,
    /// or a question about it asked in a session, is over then, and stays so once a later run fails, maybe for another
    /// reason, or the pull request conflicts again, rather than coming back as ready to push, or to be resolved in the
    /// session that holds the old merge. What each task and prompt took on of it before then is let go
    /// (`CopilotRun.taken`, `SentPrompt.parts`): not what Copilot is still at, nor what it took on since. A pipeline that
    /// another of the pull request's policies runs is passed only once none of them still needs a fix, as
    /// `PRRecord.partsToFix` has it; a merge that Azure DevOps still works out, `queued`, isn't clean.
    /// - Parameters:
    ///   - records: the pull requests as the list read them last.
    ///   - now: about when it read them.
    func endWorkThatsOver(in records: [PRRecord], now: Date = Date()) {
        var overs: [Over] = []
        for record in records {
            let pr = record.pullRequest
            let target = pr.targetBranch.isEmpty ? nil : pr.targetBranch
            overs.append(Over(key: pr.key, part: .conflicts, at: pr.mergeStatus == "succeeded" ? now : nil, target: target))
            // Its policies couldn't be read: whether its builds passed isn't known.
            guard let details = record.details, details.checksKnown else { continue }
            var checksByPart: [PullRequestPart: [Check]] = [:]
            for check in details.checks {
                if let part = check.part { checksByPart[part, default: []].append(check) }
            }
            for (part, checks) in checksByPart where checks.allSatisfy(\.needsNoFix) {
                // When it last passed, or passed and expired since: one that doesn't apply didn't run.
                guard let at = checks.filter({ $0.state != .notApplicable }).compactMap(\.completedAt).max() else { continue }
                overs.append(Over(key: pr.key, part: part, at: at))
            }
        }
        guard !overs.isEmpty else { return }
        func isOver(_ part: TakenPart, on reference: PullRequestReference?) -> Bool {
            guard let reference else { return false }
            return overs.contains { over in
                reference.matches(organization: over.key.organization, id: over.key.number)
                    && over.ends(part.part, takenAt: part.since, target: part.target)
            }
        }
        // A send that goes on with a session, while it gets ready, launches without what it carried that's over.
        letGoPending { part, entry in part.ended != nil && isOver(part, on: entry.onPullRequest) }
        let active = Set(entries.filter { $0.status.phase.isActive }.map(\.id))
        let continuing = Dictionary(pending.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var runs = settings.copilotRuns
        var runsChanged = false
        for index in runs.indices {
            guard let taken = runs[index].taken, let reference = runs[index].onPullRequest else { continue }
            // What a task is at now stays: the parts a send that goes on with it is getting ready for, else, while it runs,
            // its own unfinished ones. What it went on with, over since, as an earlier task's, doesn't.
            let atNow: Set<PullRequestPart>
            if let next = continuing[runs[index].id], next.status.phase.isActive {
                atNow = Set((next.taken ?? []).filter { $0.ended == nil }.map(\.part))
            } else if active.contains(runs[index].id) {
                atNow = Set(taken.filter { $0.ended == nil }.map(\.part))
            } else {
                atNow = []
            }
            let kept = taken.filter { (part: TakenPart) -> Bool in atNow.contains(part.part) || !isOver(part, on: reference) }
            guard kept.count != taken.count else { continue }
            if taken.contains(where: { $0.ended == nil && !kept.contains($0) }) { runs[index].workLetGo = true }
            runs[index].taken = kept
            runsChanged = true
        }
        if runsChanged { settings.copilotRuns = runs }
        var prompts = settings.copilotSentPrompts
        var promptsChanged = false
        for index in prompts.indices {
            let prompt = prompts[index]
            let ended = overs.filter { over in
                prompt.isFor(over.key) && prompt.parts.contains(over.part)
                    && over.ends(over.part, takenAt: prompt.sentAt, target: prompt.target)
            }.map(\.part)
            guard !ended.isEmpty else { continue }
            // Not while Copilot is at it.
            let isActive = ended.contains { CopilotWork.from(prompt, about: $0, turn: promptTurns[prompt.id]).isActive }
            guard !isActive else { continue }
            prompts[index].parts.removeAll { ended.contains($0) }
            promptsChanged = true
        }
        if promptsChanged { settings.copilotSentPrompts = prompts }
    }

    /// The builds and conflicts of a pull request whose fixes are done in a session and not pushed, as each says
    /// (`work(on:of:for:)`): a Push & Reply there pushes them along with the threads its prompt lists, though it replies on
    /// none of them.
    func unpushedParts(of key: PRKey, in session: String) -> [PullRequestPart] {
        var parts: [PullRequestPart] = []
        let taken = entries.filter { $0.isOn(key) }.flatMap { ($0.taken ?? []).map(\.part) }
        let prompted = settings.copilotSentPrompts.filter { $0.isFor(key) }.flatMap(\.parts)
        for part in taken + prompted where part.thread == nil && !parts.contains(part) {
            guard let work = work(on: part, of: key, for: [.fix, .pushAndReply]), work.session == session, work.waitsToBePushed else { continue }
            parts.append(part)
        }
        return parts
    }

    /// Keeps a prompt that went to one of the Copilot app's sessions, sent as it says or copied for you to paste: about some
    /// of a pull request, to follow its turn there from its log; about anything, as the session's next turn, which
    /// the turns of the prompts sent it before aren't told from (`overlap`). Not once Azure DevOps stopped, or Send Work to
    /// Copilot is off, which forgot what it kept, as a delivery that took a while may end after. One copied for you to paste
    /// is kept with what was copied, `text`, and what it takes off Needs You once you paste it, `handOff` (`copiedPrompts`),
    /// before BriefBar starts following it, which looks for what you pasted from the first.
    /// - Returns: the prompt it keeps, about some of a pull request; nil when it keeps none.
    @discardableResult
    func keep(
        _ about: SentPrompt.About?, sentTo outcome: SessionDelivery, from session: String, forking: Bool, at date: Date = Date(),
        copying text: String? = nil, handOff: CommentHandOff? = nil
    ) -> SentPrompt? {
        guard canSend, isOn, !hasStopped else { return nil }
        // Where the pull request's branch is as a fix sent with Push and Reply on goes: it pushed once the list reads another.
        var about = about
        if let sent = about, sent.purpose == .pushAndReply, sent.fixes { about?.head = currentHead(sent.pullRequest) }
        let prompt: SentPrompt?
        switch outcome {
        case .sent:
            overlap(promptsIn: session, before: date)
            prompt = about.flatMap { SentPrompt($0, session: session, sentAt: date, copied: false) }
        case .forkedAndSent(let fork):
            prompt = about.flatMap { SentPrompt($0, session: fork, forkedFrom: session, sentAt: date, copied: false) }
        case .fellBack(let fallback):
            if let fork = fallback.fork {
                overlap(promptsIn: fork, before: date)
                prompt = about.flatMap { SentPrompt($0, session: fork, forkedFrom: session, sentAt: date, copied: true) }
            } else {
                // Copied as `/fork <prompt>`, it goes to a fork that isn't made yet, rather than to the session.
                if !forking { overlap(promptsIn: session, before: date) }
                prompt = about.flatMap { SentPrompt($0, session: session, awaitsFork: forking, sentAt: date, copied: true) }
            }
        case .notSent:
            prompt = nil
        }
        guard let prompt else { return nil }
        if prompt.copied, let text { copiedPrompts[prompt.id] = (text, handOff) }
        // As things are now, not as the delivery started, which may be minutes ago: a prompt sent since, faster, stays.
        settings.copilotSentPrompts = SentPrompt.kept(settings.copilotSentPrompts + [prompt], now: Date())
        refresh()
        return prompt
    }

    /// Another prompt went to a session at `date`, from BriefBar: the session's log can't tell the turns of the prompts
    /// sent it before, whose ends weren't seen yet, from its turn, so BriefBar stops following them, and says so
    /// (`SentPrompt.overlapped`). One seen over only once may be the end of the turn that ran as it was sent, so it isn't
    /// taken as its own. One copied for you to paste that BriefBar didn't see pasted isn't handed off: whether you pasted it
    /// can't be told either.
    func overlap(promptsIn session: String, before date: Date) {
        guard canSend, isOn, !hasStopped else { return }
        var prompts = settings.copilotSentPrompts
        for index in prompts.indices where prompts[index].session == session && prompts[index].isFollowed
            && !prompts[index].awaitsFork && prompts[index].sentAt < date {
            prompts[index].overlapped = true
            promptTurns[prompts[index].id] = nil
            promptsOver[prompts[index].id] = nil
            copiedPrompts[prompts[index].id] = nil
        }
        if prompts != settings.copilotSentPrompts { settings.copilotSentPrompts = prompts }
    }

    /// Another prompt is being sent to a session: until `resumeFollowing`, the turns of the prompts sent it before aren't
    /// followed, since the new one may reach it, and its turn end, before BriefBar hears it went. Once it's known to have
    /// gone, `overlap` says their outcome isn't known; once nothing went, they're followed again.
    func pauseFollowing(_ session: String) {
        followingPaused[session, default: 0] += 1
    }

    func resumeFollowing(_ session: String) {
        guard let sends = followingPaused[session] else { return }
        followingPaused[session] = sends > 1 ? sends - 1 : nil
    }

    /// Follows the turns of the prompts sent to the Copilot app's sessions about pull requests that haven't ended,
    /// from their sessions' logs since each was sent, off the main thread: which sessions the app runs a turn in, which
    /// something has open, the fork made for one copied as `/fork`, and their logs. A turn that's over twice in a row, a few
    /// seconds apart, ended: its prompt keeps how. One copied for you to paste, while BriefBar knows what it copied
    /// (`copiedPrompts`), is taken up only once a message sent the session since holds it, which says you pasted it: its
    /// turn starts there, and what it takes care of leaves Needs You; another message, sent before it or instead, is the
    /// session's own. One not pasted, or whose fork isn't made, after half an hour, goes, with nothing handed off. One
    /// whose turn hasn't ended after `SentPrompt.followLimit` isn't followed any more, and says BriefBar doesn't know how it
    /// went (`SentPrompt.lostTrack`). Only while Send Work to Copilot is on, never in the demo, and not while another prompt
    /// is being sent to its session (`pauseFollowing`).
    func followSentPrompts(now: Date = Date()) {
        guard mode == .live, canSend, isOn, !hasStopped, !isFollowingPrompts else { return }
        let open = settings.copilotSentPrompts.filter { $0.isFollowed && followingPaused[$0.session] == nil }
        guard !open.isEmpty else { return }
        isFollowingPrompts = true
        let home = appHome
        let monitor = promptMonitor
        let copied = copiedPrompts.mapValues(\.text)
        Task {
            // Where the sessions are that prompts go to: the Copilot app's folder, and the CLI's, whose terminal one may
            // have been pasted in.
            let homes = await sessionHomes()
            // Turned off, or stopped, while that waited: nothing's read.
            guard canSend, isOn, !hasStopped else {
                isFollowingPrompts = false
                return
            }
            let read = await Task.detached(priority: .utility) { () -> [Read] in
                let running = Set((try? AppSessions.running(home: home)) ?? [])
                var read: [Read] = []
                for prompt in open {
                    var session: String? = prompt.session
                    var fork: String?
                    if prompt.awaitsFork {
                        fork = SentPrompt.onlyFork(AppSessions.forks(of: prompt.session, since: prompt.sentAt, home: home))
                        session = fork
                    }
                    let found = session.flatMap { session in
                        homes.lazy.compactMap { home in
                            AppSessions.events(of: session, home: home).flatMap { FileManager.default.fileExists(atPath: $0.path) ? (home, $0) : nil }
                        }.first
                    }
                    guard let session, let found else {
                        read.append(Read(prompt: prompt, fork: fork, turn: nil, pasted: copied[prompt.id].map { _ in false }))
                        continue
                    }
                    let (sessionHome, events) = found
                    let log = await monitor.log(id: session, events: events)
                    let isRunning = running.contains(session), isOpen = AppSessions.isOpen(session, home: sessionHome)
                    var turn = SessionTurn.of(sentAt: prompt.sentAt, log: log, isRunning: isRunning, isOpen: isOpen)
                    // Copied for you to paste: its turn starts with the message that holds it, what you pasted.
                    var pasted: Bool?
                    if let text = copied[prompt.id] {
                        let pastedAt = turn.phase == .waiting ? nil : AppSessions.pasted(text, in: session, home: sessionHome, since: prompt.sentAt)
                        pasted = pastedAt != nil
                        turn = pastedAt.map { SessionTurn.of(sentAt: $0, log: log, isRunning: isRunning, isOpen: isOpen) }
                            ?? SessionTurn(phase: .waiting, since: prompt.sentAt)
                    }
                    read.append(Read(prompt: prompt, fork: fork, turn: turn, pasted: pasted))
                }
                return read
            }.value
            isFollowingPrompts = false
            // Turned off, or stopped, meanwhile: nothing more of it is kept.
            guard canSend, isOn, !hasStopped else { return }
            applyTurns(read, now: now)
        }
    }

    /// What `followSentPrompts` read of a prompt: the fork made for one copied as `/fork`, its turn, and, for one copied
    /// for you to paste, whether a message sent the session since holds what BriefBar copied; nil when BriefBar didn't know
    /// what it copied as it read.
    private struct Read: Sendable {
        var prompt: SentPrompt
        var fork: String?
        var turn: SessionTurn?
        var pasted: Bool?
    }

    /// What `followSentPrompts` read, on the prompts as they're kept now.
    private func applyTurns(_ read: [Read], now: Date) {
        var prompts = settings.copilotSentPrompts
        for item in read {
            let (prompt, fork, turn, pasted) = (item.prompt, item.fork, item.turn, item.pasted)
            // Gone, or overlapped by another since it was read: what it read isn't its. Nor while another prompt is being
            // sent to its session, since it was read: what it read may be that one's turn.
            guard let index = prompts.firstIndex(where: { $0.id == prompt.id }), prompts[index].isFollowed,
                  followingPaused[prompts[index].session] == nil
            else { continue }
            if let fork {
                prompts[index].session = fork
                prompts[index].forkedFrom = prompt.session
                prompts[index].awaitsFork = false
                // Its ID follows its session.
                if let copied = copiedPrompts.removeValue(forKey: prompt.id) { copiedPrompts[prompts[index].id] = copied }
            }
            let id = prompts[index].id
            // Read before BriefBar knew what it copied, as it was being kept: the next look tells whether you pasted it.
            if pasted == nil, copiedPrompts[id] != nil { continue }
            // Only once it changed: what shows it redraws as it does.
            if let turn, promptTurns[id] != turn { promptTurns[id] = turn }
            // Copied for you to paste, and seen in a message sent the session since: you pasted it, and what it takes care
            // of leaves Needs You.
            if pasted == true, let copied = copiedPrompts.removeValue(forKey: id), let handOff = copied.handOff {
                handedOff(handOff, copied.text)
            }
            let waited = now.timeIntervalSince(prompt.sentAt)
            if turn?.isOver == true {
                // Over twice in a row: not the end of a turn that ran as it was sent, which the prompt's own follows.
                if let first = promptsOver[id], now.timeIntervalSince(first) >= 2 {
                    prompts[index].ended = Self.phase(of: turn)
                    promptsOver[id] = nil
                } else if promptsOver[id] == nil {
                    promptsOver[id] = now
                    // A fix sent with Push and Reply on pushed once the list reads its branch moved: now, rather than at
                    // its next refresh.
                    if prompt.fixes == true, case .finished? = turn?.phase, let number = prompt.pullRequest.number {
                        rereadPullRequest(PRKey(prompt.pullRequest.scope, number))
                    }
                }
            } else {
                promptsOver[id] = nil
                let neverTaken = turn.map { $0.phase == .waiting } ?? true
                if neverTaken && (prompt.copied || prompt.awaitsFork) && waited > SentPrompt.pasteWait {
                    // Copied and not pasted, or its fork not made: nothing went, and nothing of it was handed off.
                    prompts.remove(at: index)
                    promptTurns[id] = nil
                    copiedPrompts[id] = nil
                } else if waited > SentPrompt.followLimit {
                    // Not seen to end, as when its session waited overnight for your answer: BriefBar stops following it,
                    // and says it doesn't know how it went, rather than forget it, and what it handed off with it.
                    prompts[index].lostTrack = true
                    promptTurns[id] = nil
                    copiedPrompts[id] = nil
                }
            }
        }
        if prompts != settings.copilotSentPrompts { settings.copilotSentPrompts = prompts }
    }

    private static func phase(of turn: SessionTurn?) -> RunPhase {
        switch turn?.phase {
        case .finished?: .finished
        case .failed?: .failed
        default: .stopped
        }
    }
}

// MARK: - A line's menu

extension CopilotTasksStore {
    /// The task of BriefBar's whose run is what a line says Copilot is at: its session's, on the pull request, while it works.
    private func runningTask(of work: CopilotWork, on key: PRKey) -> CopilotTaskEntry? {
        entries.first { $0.id == work.session && $0.isOn(key) && $0.status.phase.isActive }
    }

    /// Whether what a line says Copilot is at can be stopped from it: only while it says Copilot works on it, or asks you
    /// something, never once it's over, though a later task works in its session; then a task of BriefBar's that works now,
    /// or a prompt whose turn runs in one of the Copilot app's sessions, or waits for your answer there. Not a task getting
    /// its worktree ready, which nothing runs in yet, nor a prompt sent and not taken up, whose session is at something
    /// else. Never in the demo.
    func canStop(_ work: CopilotWork, of key: PRKey) -> Bool {
        guard canSend, isOn, !hasStopped else { return false }
        switch work.state {
        case .working, .needsYou: break
        case .waiting, .done, .failed, .stopped, .unknown: return false
        }
        if let task = runningTask(of: work, on: key) { return task.status.phase == .working && task.run != nil }
        return true
    }

    /// Stops what a line says Copilot is at: a task of BriefBar's, as its row's Stop does, which stops it at all it took on;
    /// or a prompt's turn in one of the Copilot app's sessions (`stopTurn`).
    /// - Returns: what to say once BriefBar didn't stop it itself; nil once it did.
    func stop(_ work: CopilotWork, of key: PRKey) async -> String? {
        guard canStop(work, of: key) else { return nil }
        if let task = runningTask(of: work, on: key) {
            stop(task)
            return nil
        }
        return await stopTurn(in: work.session)
    }

    /// Whether Copilot fixes something of a pull request now, or pushes its fix, which its Fix, or Resolve, waits for: by
    /// the latest fix, or Push & Reply, that took it on, whatever came after, such as a question about it sent since to
    /// another session, which its line says instead (`work(on:of:for:)`).
    func isFixing(_ part: PullRequestPart, of key: PRKey) -> Bool {
        work(on: part, of: key, for: [.fix, .pushAndReply])?.isFixing == true
    }

    /// Whether a line's Try Again sends what it says again, with the same words: a fix that failed or stopped, whether or
    /// not it was to push and reply.
    static func canTryAgain(_ work: CopilotWork) -> Bool {
        guard work.purpose == .fix || (work.purpose == .pushAndReply && work.fixes) else { return false }
        switch work.state {
        case .failed, .stopped: return true
        case .waiting, .working, .needsYou, .done, .unknown: return false
        }
    }

    /// Whether a line can be cleared: what it says is over, or copied for you to paste, which may never be.
    static func canClear(_ work: CopilotWork) -> Bool {
        switch work.state {
        case .done, .failed, .stopped, .unknown, .waiting(copied: true): return true
        case .waiting(copied: false), .working, .needsYou: return false
        }
    }

    /// The words a fix that Try Again tries again went with, as its composer sent them, with the answer it quoted: only for
    /// that very attempt, as when it took on what it's about tells (`FixWords.takenAt`), not another sent meanwhile or
    /// since, such as from the Send to Copilot window, whose words BriefBar doesn't keep. Nil otherwise, and once BriefBar
    /// restarted.
    func retryWords(for work: CopilotWork, of key: PRKey) -> FixWords? {
        guard let words = fixWords[PartKey(pullRequest: key, part: work.part)],
              abs(words.takenAt.timeIntervalSince(work.takenAt ?? work.since)) < 0.001
        else { return nil }
        return words
    }

    /// Keeps the words a fix went with, for what it took on, for Try Again (`retryWords(for:of:)`), in memory only: those of
    /// a fix of one thread, build or the conflicts, from its own composer, `ask`, not Fix All's, written for all the threads
    /// it takes on, which Try Again on one of them doesn't send for it alone, but opens its composer, going where Fix All
    /// went, for you to write. Not once Send Work to Copilot is off, or Azure DevOps stopped, which forgot them, as a send
    /// that took a while may end after.
    func remember(_ words: FixWords, for parts: [PullRequestPart], of key: PRKey, from ask: CopilotAsk) {
        guard isOn, !hasStopped, ask == .fix else { return }
        for part in parts {
            fixWords[PartKey(pullRequest: key, part: part)] = words
        }
    }

    /// Lets go of Copilot's work on something of a pull request, as its line's Clear does, as Dismiss does for an answer:
    /// what each task and prompt took on of it (`CopilotRun.taken`, `SentPrompt.parts`), so that the line goes and nothing
    /// older takes its place, and a fix of it is no longer ready to push; and what a send that couldn't start keeps of it,
    /// or one getting ready carries from before, which it would launch with. What Copilot is still at stays; a prompt copied
    /// for you to paste that takes on nothing else goes, and hands nothing off, and one that takes on more, or a Push &
    /// Reply, which stays, no longer hands off a thread's comments, once you paste it (`CommentHandOff.without(thread:)`).
    /// The demo's are let go in memory.
    func clear(_ part: PullRequestPart, of key: PRKey) {
        guard isOn else { return }
        objectWillChange.send()
        if mode == .demo {
            clearedInDemo.insert(PartKey(pullRequest: key, part: part))
            return
        }
        letGoPending { taken, entry in
            taken.part == part && entry.isOn(key) && (!entry.status.phase.isActive || taken.ended != nil)
        }
        let active = Set(entries.filter { $0.status.phase.isActive }.map(\.id))
        let continuing = Dictionary(pending.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var runs = settings.copilotRuns
        for index in runs.indices where runs[index].onPullRequest?.matches(organization: key.organization, id: key.number) == true {
            guard let taken = runs[index].taken else { continue }
            // What it's at now stays: what a send that goes on with it is getting ready for, else, while it runs, its own.
            let isAtIt: Bool
            if let next = continuing[runs[index].id], next.status.phase.isActive {
                isAtIt = next.taken?.contains { $0.part == part && $0.ended == nil } == true
            } else {
                isAtIt = active.contains(runs[index].id) && taken.contains { $0.part == part && $0.ended == nil }
            }
            guard !isAtIt else { continue }
            let kept = taken.filter { $0.part != part }
            guard kept.count != taken.count else { continue }
            if taken.contains(where: { $0.part == part && $0.ended == nil }) { runs[index].workLetGo = true }
            runs[index].taken = kept
        }
        if runs != settings.copilotRuns { settings.copilotRuns = runs }
        var prompts = settings.copilotSentPrompts
        // The fixes it leaves with nothing, which it lets go of: not a Push & Reply, which still says that its session
        // pushed what it changed, though it may not have been seen to end yet, for the fixes it pushed along.
        var emptied: Set<String> = []
        var clearedIn: Set<String> = []
        for index in prompts.indices where prompts[index].isFor(key) && prompts[index].parts.contains(part) {
            let work = CopilotWork.from(prompts[index], about: part, turn: promptTurns[prompts[index].id])
            guard Self.canClear(work) else { continue }
            prompts[index].parts.removeAll { $0 == part }
            clearedIn.insert(prompts[index].id)
            if prompts[index].parts.isEmpty, prompts[index].isFollowed, prompts[index].purpose != .pushAndReply {
                emptied.insert(prompts[index].id)
            }
        }
        for id in emptied {
            copiedPrompts[id] = nil
            promptTurns[id] = nil
        }
        // One it keeps, copied for you to paste, no longer takes the thread's comments off Needs You once you do.
        if let thread = part.thread {
            for id in clearedIn.subtracting(emptied) {
                guard let copied = copiedPrompts[id], let handOff = copied.handOff else { continue }
                copiedPrompts[id] = (copied.text, handOff.without(thread: thread))
            }
        }
        prompts.removeAll { emptied.contains($0.id) }
        if prompts != settings.copilotSentPrompts { settings.copilotSentPrompts = prompts }
    }
}
