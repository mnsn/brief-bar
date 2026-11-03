import AzureDevOpsCore
import BriefBarCore
import CopilotTasks
import Foundation

/// A prompt about some of a pull request's comment threads that BriefBar sent to one of the Copilot app's sessions, or to a
/// fork of it, or copied for you to paste there (`CopilotTasksStore.deliver`): which session took it, which threads, what
/// for and when, kept with Send Work to Copilot's runs (`ado.copilot.sentPrompts`) by references only, never what it says,
/// for as long as a link you make (`LinkEdits.lifetime`). Copilot works on it in the app, which BriefBar doesn't run, so
/// what became of it is what the session's log says from then on (`SessionTurn`), which BriefBar follows until its turn
/// ends (`CopilotTasksStore.followSentPrompts`).
struct SentPrompt: Codable, Equatable, Sendable, Identifiable {
    /// What it asked.
    enum Purpose: String, Codable, Sendable {
        /// Fix, on one thread, or Fix Comments, on those that waited on you.
        case fix
        /// Explain, as a prompt the session takes up itself, when it can't be asked aside.
        case explain
        /// Push & Reply, which ships what the fixes changed.
        case pushAndReply
    }

    /// What it's about, as it's sent: the pull request, what for, and its threads.
    struct About: Equatable, Sendable {
        var pullRequest: PRKey
        var purpose: Purpose
        var threads: [Int]
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
    var threads: [Int]
    var sentAt: Date
    /// BriefBar copied it for you to paste, rather than sending it itself.
    var copied: Bool
    /// How its turn ended, as the session's log said once it did.
    var ended: RunPhase?
    /// Another prompt went to its session before its turn was seen to end: which turn's end is its, BriefBar can't tell
    /// from the session's log, so it says it doesn't know rather than take the later one's.
    var overlapped = false

    var id: String { "\(session)/\(sentAt.timeIntervalSince1970)" }

    /// BriefBar follows its turn: it hasn't been seen to end, and no other prompt went to its session before it was.
    var isFollowed: Bool { ended == nil && !overlapped }

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
        threads = about.threads
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
        threads = try container.decode([Int].self, forKey: .threads)
        sentAt = try container.decode(Date.self, forKey: .sentAt)
        copied = try container.decodeIfPresent(Bool.self, forKey: .copied) ?? false
        ended = try container.decodeIfPresent(RunPhase.self, forKey: .ended)
        overlapped = try container.decodeIfPresent(Bool.self, forKey: .overlapped) ?? false
        guard pullRequest.kind == .pullRequest, AppSessions.isSessionID(session), forkedFrom.map(AppSessions.isSessionID) ?? true else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a prompt to a session"))
        }
    }

    func isFor(_ key: PRKey) -> Bool {
        pullRequest == key.linkRef
    }

    /// How long one is kept: as long as a link you make, by when it was sent.
    static let lifetime = LinkEdits.lifetime
    /// The most kept, the latest.
    static let limit = 200
    /// How long BriefBar waits for you to paste one it copied, or for the fork you paste it in to be made.
    static let pasteWait: TimeInterval = 30 * 60
    /// How long BriefBar follows one whose turn hasn't ended.
    static let followLimit: TimeInterval = 12 * 3_600

    /// The ones kept in the preferences, the oldest first: without what can't be read, such as what another program wrote
    /// there, those older than `lifetime`, and those still followed after `followLimit`.
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
        let kept = prompts.filter { prompt in
            guard prompt.sentAt >= cutoff, prompt.sentAt <= now.addingTimeInterval(60) else { return false }
            return !prompt.isFollowed || now.timeIntervalSince(prompt.sentAt) < followLimit
        }
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

/// What Copilot does, or did, about one of a pull request's comment threads, for its status line: the latest work that
/// took it on, a task of BriefBar's (`CopilotRun.threads`) or a prompt sent to one of the Copilot app's sessions
/// (`SentPrompt`), in the session that works on it.
struct CommentWork: Equatable {
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
    /// again.
    var waitsToBePushed: Bool {
        switch (purpose, state) {
        case (.fix, .done), (.pushAndReply, .failed), (.pushAndReply, .stopped): true
        default: false
        }
    }

    /// Where it is, in a sentence's middle: "‘Retry backoff’", "a fork of ‘Retry backoff’", "its session".
    /// - Parameters:
    ///   - name: the session's name; nil when it isn't known.
    ///   - forkOf: for a fork, the name of the session it forked, when that's known.
    static func place(_ name: String?, isFork: Bool, forkOf: String?) -> String {
        guard isFork else { return name.map { "‘\($0)’" } ?? "its session" }
        return "a fork of " + (forkOf.map { "‘\($0)’" } ?? "its session")
    }

    /// What it says on its thread, in a sentence: "Copilot is fixing this in ‘Retry backoff’", "Fixing this in a fork of
    /// ‘Retry backoff’", "Fixed in ‘Retry backoff’, not pushed", "Couldn't fix it: …".
    /// - Parameters:
    ///   - name: the session's name; nil when it isn't known.
    ///   - forkOf: for a fork, the name of the session it forked.
    func sentence(name: String?, forkOf: String?) -> String {
        let fork = forkedFrom != nil
        let place = Self.place(name, isFork: fork, forkOf: forkOf)
        switch (purpose, state) {
        case (_, .waiting(copied: true)):
            return "Copied for \(place): paste it there"
        case (.pushAndReply, .waiting), (.pushAndReply, .working):
            return "Pushing and replying from \(place)"
        case (_, .waiting(copied: false)):
            return "Sent to \(place)"
        case (_, .needsYou):
            return "\(place.prefix(1).uppercased() + place.dropFirst()) is waiting for your answer"
        case (.fix, .working):
            return fork ? "Fixing this in \(place)" : "Copilot is fixing this in \(place)"
        case (.explain, .working):
            return fork ? "Explaining this in \(place)" : "Copilot is explaining this in \(place)"
        case (.fix, .done):
            return "Fixed in \(place), not pushed"
        case (.explain, .done):
            return "Answered in \(place)"
        case (.pushAndReply, .done):
            return "Pushed and replied from \(place)"
        case (_, .failed(let reason)):
            let what = purpose == .explain ? "explain it" : purpose == .pushAndReply ? "push it" : "fix it"
            guard let reason = reason.flatMap(CopilotTasksStore.firstLine) else { return "Couldn't \(what) in \(place)" }
            return "Couldn't \(what): \(reason)"
        case (_, .stopped):
            let what = purpose == .explain ? "answered" : purpose == .pushAndReply ? "pushed it" : "fixed it"
            return "Stopped in \(place) before it \(what)"
        case (_, .unknown(let copied)):
            return copied ? "Copied for \(place) · see the session" : "Sent to \(place) · see the session"
        }
    }

    /// From a task of BriefBar's that took the thread on (`CopilotRun.threads`), to fix it, or to push its fix and reply on
    /// it, as it stands, or as it ended once a later task went on with its session.
    static func from(_ entry: CopilotTaskEntry, taken: TakenThread) -> CommentWork {
        let isTask = entry.run?.isAppSession != true
        // Push & Reply ships those its prompt listed; the others it has, it doesn't reply on, and they stay as they were.
        let purpose: Purpose = taken.ships == true ? .pushAndReply : .fix
        // Taken on by an earlier task in the session, which a later one went on with.
        if let before = taken.ended {
            let state: State = switch before {
            case .finished: .done(nil)
            case .failed: .failed(nil)
            case .stopped, .preparing, .working: .stopped
            }
            return CommentWork(purpose: purpose, state: state, session: entry.id, forkedFrom: entry.forkedFrom, isTask: isTask, since: taken.since)
        }
        let ended = entry.status.phase.isActive ? nil : entry.status.since
        return CommentWork(
            purpose: purpose, state: state(of: entry.status), session: entry.id, forkedFrom: entry.forkedFrom, isTask: isTask,
            since: ended ?? taken.since
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

    /// From a prompt sent to one of the Copilot app's sessions, as its turn stands (`SessionTurn`), or as it ended.
    static func from(_ prompt: SentPrompt, turn: SessionTurn?) -> CommentWork {
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
        if prompt.overlapped { state = .unknown(copied: prompt.copied) }
        return CommentWork(purpose: purpose, state: state, session: prompt.session, forkedFrom: prompt.forkedFrom, isTask: false, since: since)
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
    var threads: [Int]
    /// When the latest was done.
    var latest: Date

    var id: String { session }
}

extension CopilotTasksStore {
    /// Copilot's latest work on a pull request's comment thread, as its status line says it: a task of BriefBar's that
    /// took it on, or a prompt sent to one of the Copilot app's sessions about it, whichever took it on last. Nil when none
    /// did, while Send Work to Copilot is off, and for the demo's other threads.
    /// - Parameter purposes: only work for these, such as fixes and shipping them, past a question asked since.
    func commentWork(on thread: Int, of key: PRKey, for purposes: Set<CommentWork.Purpose>? = nil) -> CommentWork? {
        guard isOn else { return nil }
        var latest: (since: Date, work: CommentWork)?
        func consider(_ since: Date, _ work: CommentWork) {
            if let purposes, !purposes.contains(work.purpose) { return }
            if latest.map({ since > $0.since }) ?? true { latest = (since, work) }
        }
        for entry in entries where entry.isOn(key) {
            guard let taken = entry.threads?.first(where: { $0.id == thread }) else { continue }
            // One the session's latest task took on, as it started; one an earlier task did, as that one did.
            consider(taken.ended == nil ? entry.startedAt : taken.since, CommentWork.from(entry, taken: taken))
        }
        for prompt in settings.copilotSentPrompts where prompt.isFor(key) && prompt.threads.contains(thread) {
            consider(prompt.sentAt, CommentWork.from(prompt, turn: promptTurns[prompt.id]))
        }
        // The demo's, made up.
        if mode == .demo {
            for (prompt, turn) in SentPrompt.demo(now: Date()) where prompt.isFor(key) && prompt.threads.contains(thread) {
                consider(prompt.sentAt, CommentWork.from(prompt, turn: turn))
            }
        }
        return latest?.work
    }

    /// The fixes of a pull request's threads that are done and not pushed, by the session they're in, the latest first:
    /// only those of `threads`, the ones still open, and those a Push & Reply that failed or stopped didn't push. A
    /// question asked about a thread since, as its line says, doesn't push its fix.
    func readyFixes(of key: PRKey, among threads: [Int]) -> [ReadyFixes] {
        var groups: [String: ReadyFixes] = [:]
        for thread in threads {
            guard let work = commentWork(on: thread, of: key, for: [.fix, .pushAndReply]), work.waitsToBePushed else { continue }
            var group = groups[work.session] ?? ReadyFixes(
                session: work.session, forkedFrom: work.forkedFrom, isTask: work.isTask, threads: [], latest: work.since
            )
            group.threads.append(thread)
            group.latest = max(group.latest, work.since)
            groups[work.session] = group
        }
        return groups.values.sorted { ($0.latest, $0.session) > ($1.latest, $1.session) }
    }

    /// Keeps a prompt that went to one of the Copilot app's sessions, sent as it says or copied for you to paste: about a
    /// pull request's threads, to follow its turn there from its log; about anything, as the session's next turn, which
    /// the turns of the prompts sent it before aren't told from (`overlap`). Not once Azure DevOps stopped, or Send Work to
    /// Copilot is off, which forgot what it kept, as a delivery that took a while may end after.
    func keep(_ about: SentPrompt.About?, sentTo outcome: SessionDelivery, from session: String, forking: Bool, at date: Date = Date()) {
        guard canSend, isOn, !hasStopped else { return }
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
        guard let prompt else { return }
        // As things are now, not as the delivery started, which may be minutes ago: a prompt sent since, faster, stays.
        settings.copilotSentPrompts = SentPrompt.kept(settings.copilotSentPrompts + [prompt], now: Date())
        refresh()
    }

    /// Another prompt went to a session at `date`, from BriefBar: the session's log can't tell the turns of the prompts
    /// sent it before, whose ends weren't seen yet, from its turn, so BriefBar stops following them, and says so
    /// (`SentPrompt.overlapped`). One seen over only once may be the end of the turn that ran as it was sent, so it isn't
    /// taken as its own.
    func overlap(promptsIn session: String, before date: Date) {
        guard canSend, isOn, !hasStopped else { return }
        var prompts = settings.copilotSentPrompts
        for index in prompts.indices where prompts[index].session == session && prompts[index].isFollowed
            && !prompts[index].awaitsFork && prompts[index].sentAt < date {
            prompts[index].overlapped = true
            promptTurns[prompts[index].id] = nil
            promptsOver[prompts[index].id] = nil
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

    /// Follows the turns of the prompts sent to the Copilot app's sessions about pull requests' threads that haven't ended,
    /// from their sessions' logs since each was sent, off the main thread: which sessions the app runs a turn in, which
    /// something has open, the fork made for one copied as `/fork`, and their logs. A turn that's over twice in a row, a few
    /// seconds apart, ended: its prompt keeps how. One copied and not pasted, or whose fork isn't made, after half an hour,
    /// and one whose turn hasn't ended after `SentPrompt.followLimit`, goes. Only while Send Work to Copilot is on, never in
    /// the demo, and not while another prompt is being sent to its session (`pauseFollowing`).
    func followSentPrompts(now: Date = Date()) {
        guard mode == .live, canSend, isOn, !hasStopped, !isFollowingPrompts else { return }
        let open = settings.copilotSentPrompts.filter { $0.isFollowed && followingPaused[$0.session] == nil }
        guard !open.isEmpty else { return }
        isFollowingPrompts = true
        let home = appHome
        let monitor = promptMonitor
        Task {
            // Where the sessions are that prompts go to: the Copilot app's folder, and the CLI's, whose terminal one may
            // have been pasted in.
            let homes = await sessionHomes()
            // Turned off, or stopped, while that waited: nothing's read.
            guard canSend, isOn, !hasStopped else {
                isFollowingPrompts = false
                return
            }
            let read = await Task.detached(priority: .utility) { () -> [(prompt: SentPrompt, fork: String?, turn: SessionTurn?)] in
                let running = Set((try? AppSessions.running(home: home)) ?? [])
                var read: [(prompt: SentPrompt, fork: String?, turn: SessionTurn?)] = []
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
                        read.append((prompt, fork, nil))
                        continue
                    }
                    let (sessionHome, events) = found
                    let log = await monitor.log(id: session, events: events)
                    let turn = SessionTurn.of(
                        sentAt: prompt.sentAt, log: log, isRunning: running.contains(session),
                        isOpen: AppSessions.isOpen(session, home: sessionHome)
                    )
                    read.append((prompt, fork, turn))
                }
                return read
            }.value
            isFollowingPrompts = false
            // Turned off, or stopped, meanwhile: nothing more of it is kept.
            guard canSend, isOn, !hasStopped else { return }
            applyTurns(read, now: now)
        }
    }

    /// What `followSentPrompts` read, on the prompts as they're kept now.
    private func applyTurns(_ read: [(prompt: SentPrompt, fork: String?, turn: SessionTurn?)], now: Date) {
        var prompts = settings.copilotSentPrompts
        for (prompt, fork, turn) in read {
            // Gone, or overlapped by another since it was read: what it read isn't its. Nor while another prompt is being
            // sent to its session, since it was read: what it read may be that one's turn.
            guard let index = prompts.firstIndex(where: { $0.id == prompt.id }), !prompts[index].overlapped,
                  followingPaused[prompts[index].session] == nil
            else { continue }
            if let fork {
                prompts[index].session = fork
                prompts[index].forkedFrom = prompt.session
                prompts[index].awaitsFork = false
            }
            let id = prompts[index].id
            // Only once it changed: what shows it redraws as it does.
            if let turn, promptTurns[id] != turn { promptTurns[id] = turn }
            let waited = now.timeIntervalSince(prompt.sentAt)
            if turn?.isOver == true {
                // Over twice in a row: not the end of a turn that ran as it was sent, which the prompt's own follows.
                if let first = promptsOver[id], now.timeIntervalSince(first) >= 2 {
                    prompts[index].ended = Self.phase(of: turn)
                    promptsOver[id] = nil
                } else if promptsOver[id] == nil {
                    promptsOver[id] = now
                }
            } else {
                promptsOver[id] = nil
                let neverTaken = turn.map { $0.phase == .waiting } ?? true
                if neverTaken && (prompt.copied || prompt.awaitsFork) && waited > SentPrompt.pasteWait || waited > SentPrompt.followLimit {
                    prompts.remove(at: index)
                    promptTurns[id] = nil
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
