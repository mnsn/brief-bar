import BriefBarCore
import CopilotCore
import Foundation

/// How a task sent to Copilot stands.
public enum RunPhase: String, Sendable, Codable, Equatable {
    /// Getting its worktree ready, before Copilot starts.
    case preparing
    case working
    /// Copilot called it done.
    case finished
    /// It couldn't start, or Copilot reported an error.
    case failed
    /// It ended before Copilot called it done: you stopped it, or it was ended.
    case stopped

    public var isActive: Bool { self == .preparing || self == .working }
}

/// A task BriefBar sent to Copilot, as it keeps it across launches in its preferences: which work item or pull request,
/// what for, where, and with which model. Not titles, nor anything Copilot wrote. Any program running as you can change
/// the preferences, so the files BriefBar reads for a run aren't kept there: they follow from its session's ID, which is
/// checked to be one (`CopilotRun.isValid`).
public struct CopilotRun: Sendable, Codable, Equatable, Identifiable {
    /// The ID of Copilot's session, a UUID: one that BriefBar chose, or the Copilot app's session's that it went on with.
    public var id: String
    /// The work item it's for; for a task on a pull request, the work item whose task opened that pull request, when it
    /// went on with that task's session; nil otherwise.
    public var workItem: WorkItemReference?
    /// The pull request it works on, and what for; nil for a work item's.
    public var onPullRequest: PullRequestReference?
    public var action: PullRequestAction?
    public var options: CopilotRunOptions
    /// The repository's main checkout.
    public var repository: URL
    public var worktree: URL
    public var startedAt: Date
    public var process: DetachedProgram.Handle
    /// How it ended, once BriefBar saw it end, so that it says so only once.
    public var ended: RunPhase?
    /// The pull request it opened, once found.
    public var pullRequest: URL?
    /// You stopped it, so it's nothing to look at, nor to hear about, even after BriefBar restarts. Nil otherwise, as
    /// runs that BriefBar kept before it had this were.
    public var stoppedByYou: Bool?
    /// It went on with one of the Copilot app's sessions, in the folder that session works in, rather than in a worktree
    /// of BriefBar's: BriefBar never removes that folder, and goes on with it in the app rather than in Terminal. Nil
    /// otherwise, as runs that BriefBar kept before it had this were.
    public var isAppSession: Bool?
    /// The session it forked, when it works in a fork of one, a new session with that one's whole history, in a worktree of
    /// its own (`CopilotLauncher.Request.forking`): its ID, to say so, and not to read anything by, unless it's checked to be
    /// a session's. Nil otherwise, as runs that BriefBar kept before it had this were.
    public var forkedFrom: String?
    /// The comment threads of its pull request it took on, by their IDs, each with when: one at a time with Fix, or those
    /// that waited on you, with Fix Comments. Going on with a session whose changes aren't pushed keeps those it took on
    /// before, with how that went (`threads(goingOnWith:on:taking:for:at:)`), so each thread can say what became of it. Nil
    /// for a task that took on none, and for runs that BriefBar kept before it had this.
    public var threads: [TakenThread]?

    public init(
        id: String, workItem: WorkItemReference?, onPullRequest: PullRequestReference? = nil, action: PullRequestAction? = nil,
        options: CopilotRunOptions, repository: URL, worktree: URL, startedAt: Date, process: DetachedProgram.Handle,
        ended: RunPhase? = nil, pullRequest: URL? = nil, stoppedByYou: Bool? = nil, isAppSession: Bool? = nil,
        forkedFrom: String? = nil, threads: [TakenThread]? = nil
    ) {
        self.id = id
        self.workItem = workItem
        self.onPullRequest = onPullRequest
        self.action = action
        self.options = options
        self.repository = repository
        self.worktree = worktree
        self.startedAt = startedAt
        self.process = process
        self.ended = ended
        self.pullRequest = pullRequest
        self.stoppedByYou = stoppedByYou
        self.isAppSession = isAppSession
        self.forkedFrom = forkedFrom
        self.threads = threads
    }

    /// Its ID is a session's, as BriefBar writes them: a lowercase UUID, which can't step out of a folder; and it's for a
    /// work item or a pull request.
    public var isValid: Bool {
        UUID(uuidString: id)?.uuidString.lowercased() == id && (workItem != nil || onPullRequest != nil)
    }

    /// "work item 4217" or "pull request 4071", for messages: the pull request, for a task on the one its work item's
    /// task opened.
    public var subjectName: String {
        if let onPullRequest { return "pull request \(onPullRequest.id)" }
        if let workItem { return "work item \(workItem.id)" }
        return "this task"
    }

    /// It works in a worktree BriefBar made for a pull request, detached at its latest commit: a pull request's task, not
    /// one that went on with a work item's task, which kept its own checkout, nor with one of the Copilot app's sessions.
    public var worksInPullRequestWorktree: Bool {
        onPullRequest != nil && workItem == nil && isAppSession != true
    }

    /// When Copilot started on it: when its process started, as macOS records it, or else when BriefBar started it. Going on
    /// with a session, or forking one, its log has that session's history too: what the log says from before then, this run
    /// didn't (`RunStatus.derive`).
    public var launchedAt: Date {
        process.startedAt ?? startedAt
    }

    /// Copilot's log of the session, in the Copilot CLI's folder (`CopilotCLI.home`).
    public func events(in copilotHome: URL) -> URL {
        copilotHome.appendingPathComponent("session-state", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    /// What Copilot printed, in BriefBar's folder for that.
    public func output(in folder: URL) -> URL {
        folder.appendingPathComponent("\(id).log")
    }

    /// The threads a task keeps once it goes on with `previous`'s session, or starts in a session of its own when that's
    /// nil, for `action`, at `now`: those `previous` took on, with how it ended, while its changes aren't pushed, as after a
    /// fix, or a Push & Reply that didn't finish, and only on the same pull request, since a thread's ID is its pull
    /// request's own; then `taken`, which it takes on now, in their place. Push & Reply ships what's there, and the threads
    /// it's sent for that it doesn't have, fixed by prompts sent to the session rather than by its runs, as they were. Nil
    /// when it keeps none.
    /// - Parameter pullRequest: the pull request it's on, if it's on one.
    public static func threads(
        goingOnWith previous: CopilotRun?, on pullRequest: PullRequestReference?, taking taken: [Int], for action: PullRequestAction?,
        at now: Date
    ) -> [TakenThread]? {
        var kept: [TakenThread] = []
        if let previous, let before = previous.threads, let pullRequest, previous.onPullRequest?.matches(pullRequest) == true,
           previous.action?.changesCode == true || (previous.action == .pushAndReply && previous.ended != .finished) {
            // Gone on with, it ended: one BriefBar didn't see end, it stopped.
            kept = before.map { thread in
                var thread = thread
                if thread.ended == nil { thread.ended = previous.ended ?? .stopped }
                return thread
            }
        }
        if action == .pushAndReply {
            let held = Set(kept.map(\.id))
            kept += taken.filter { !held.contains($0) }.map { TakenThread(id: $0, since: now) }
        } else {
            let ids = Set(taken)
            kept = kept.filter { !ids.contains($0.id) } + taken.map { TakenThread(id: $0, since: now) }
        }
        return kept.isEmpty ? nil : kept
    }
}

/// A comment thread of the pull request a task took on (`CopilotRun.threads`): by its ID, never what it says, with when,
/// and how the task that took it on ended, once a later task went on with the same session.
public struct TakenThread: Sendable, Codable, Equatable, Hashable {
    public var id: Int
    /// When the task that took it on started.
    public var since: Date
    /// How that task ended, once a later one went on with its session; nil while it's the session's latest.
    public var ended: RunPhase?

    public init(id: Int, since: Date, ended: RunPhase? = nil) {
        self.id = id
        self.since = since
        self.ended = ended
    }
}

/// What a run is doing, or how it ended.
public struct RunStatus: Sendable, Equatable {
    public var phase: RunPhase
    public var since: Date?
    /// What it's doing while it works; what it said when it finished; why it failed.
    public var detail: String?

    public init(phase: RunPhase, since: Date? = nil, detail: String? = nil) {
        self.phase = phase
        self.since = since
        self.detail = detail
    }

    /// From whether Copilot's process still runs, then, once it's gone, from Copilot's log of the session. While it
    /// runs, it's working whatever the log says: in autopilot, Copilot goes on after a turn that looks like its last,
    /// and after an error. Its log and output are complete only once it's gone, so read them after finding it gone.
    /// - Parameters:
    ///   - log: nil until Copilot has written one.
    ///   - startedAt: when Copilot started on it (`CopilotRun.launchedAt`). A phase its log was put in before then, and not
    ///     since, is the history of a session it went on with, or forked, not how this run went, and counts as nothing
    ///     written yet; one it put the log in again, as with an error after the session's error, dates from when it did.
    ///   - exitStatus: how its process ended, when BriefBar saw it end.
    ///   - stoppedByYou: you stopped it.
    ///   - output: what it printed, which says why when it couldn't start.
    public static func derive(
        log: SessionLogState?, startedAt: Date? = nil, isRunning: Bool, exitStatus: Int32?, stoppedByYou: Bool, output: String?
    ) -> RunStatus {
        var log = log
        var phaseSince = log?.phaseSince
        if let startedAt, let state = log {
            if let setAt = state.phaseSetAt, setAt < startedAt {
                log = nil
                phaseSince = nil
            } else if let since = phaseSince, since < startedAt {
                phaseSince = state.phaseSetAt
            }
        }
        if isRunning {
            return RunStatus(phase: .working, detail: log?.phase == .running ? log?.currentStep : nil)
        }
        switch log?.phase {
        case .finished?:
            return RunStatus(phase: .finished, since: phaseSince, detail: log?.summary)
        case .failed?:
            return RunStatus(phase: .failed, since: phaseSince, detail: log?.errorMessage ?? lastLine(output))
        case .interrupted?:
            return RunStatus(phase: .stopped, since: phaseSince)
        case .running?, .unknown?, nil:
            if stoppedByYou {
                return RunStatus(phase: .stopped, since: log?.lastEventAt)
            }
            guard let log, log.phase == .running else {
                // The CLI follows an option it refuses with its usage and a hint to try --help: the error says why.
                let reason = lastLine(output, where: isError) ?? lastLine(output)
                    ?? exitStatus.map { "Copilot exited with status \($0) before it started working." }
                return RunStatus(phase: .failed, since: log?.lastEventAt, detail: reason ?? "Copilot ended before it started working.")
            }
            if exitStatus == 0 {
                // It ended cleanly without calling the task done.
                return RunStatus(phase: .finished, since: log.lastEventAt, detail: log.summary)
            }
            if let exitStatus {
                return RunStatus(phase: .failed, since: log.lastEventAt, detail: lastLine(output) ?? "Copilot exited with status \(exitStatus).")
            }
            return RunStatus(phase: .stopped, since: log.lastEventAt)
        }
    }

    static func lastLine(_ text: String?, where matches: (String) -> Bool = { _ in true }) -> String? {
        text?.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && matches($0) }
            .map { String($0.prefix(300)) }
    }

    /// "Error: …" or "error: …", as the CLI says what went wrong.
    static func isError(_ line: String) -> Bool {
        line.lowercased().hasPrefix("error:")
    }
}

/// What Copilot said at the end of a run, from its session log.
public enum RunTranscript {
    /// The summary it called the task done with, and its last message to you.
    public static func lastWords(events: URL, maxBytes: Int = 4 << 20) -> (summary: String?, message: String?) {
        let words = SessionTranscript.lastWords(events: events, maxBytes: maxBytes)
        return (words.summary?.text, words.message?.text)
    }

    /// The pull request a run that ended opened: the last link to one in the summary it called the task done with, else in
    /// its last message, else in what it printed. Going on with a session, or forking one, its log has that session's
    /// history too: from `since` on (`CopilotRun.launchedAt`), only what Copilot said then counts, not a link the session
    /// gave before. A link the run carries over from the one it went on with isn't looked for again.
    public static func openedPullRequest(events: URL, printed: String?, since: Date? = nil) -> URL? {
        let words = SessionTranscript.lastWords(events: events)
        let said = [words.summary, words.message].compactMap { $0 }.filter { words in
            guard let since else { return true }
            return words.date.map { $0 >= since } ?? false
        }
        return (said.map(\.text) + [printed].compactMap { $0 }).lazy.compactMap { pullRequest(in: $0) }.first
    }

    /// The last link to a pull request in a text: Azure DevOps' (dev.azure.com or visualstudio.com) or GitHub's, to the
    /// pull request's page. A link that's part of another, in its query say, doesn't count.
    public static func pullRequest(in text: String) -> URL? {
        text.components(separatedBy: linkBreaks).reversed().lazy.compactMap { pullRequestPage(of: $0) }.first
    }

    /// What ends a link in prose and Markdown: spaces, brackets, quotes and backticks.
    private static let linkBreaks = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "()<>[]\"'`"))
    /// What can come before or after a link without being part of it: emphasis and punctuation.
    private static let linkMarks = CharacterSet(charactersIn: "*_~.,;:!?")

    /// The page of the pull request that a word links to, without a query or fragment; nil when it links to anything else.
    private static func pullRequestPage(of word: String) -> URL? {
        guard let link = URLComponents(string: word.trimmingCharacters(in: linkMarks), encodingInvalidCharacters: true),
              link.scheme?.lowercased() == "https", link.user == nil, link.password == nil, link.port == nil,
              let host = link.percentEncodedHost?.lowercased()
        else { return nil }
        let segments = link.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        // GitHub: owner/repository/pull/number. Azure DevOps: one to three names, then _git/repository/pullrequest/number.
        let route: (keyword: String, index: Int)
        if host == "github.com" {
            route = ("pull", 2)
        } else if isAzureDevOps(host), let git = segments.firstIndex(where: { $0.lowercased() == "_git" }), (1...3).contains(git) {
            route = ("pullrequest", git + 2)
        } else {
            return nil
        }
        let number = route.index + 1
        guard segments.count > number, segments[route.index].lowercased() == route.keyword,
              segments[...number].allSatisfy({ !$0.isEmpty }), segments[number].allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        return URL(string: "https://\(host)/\(segments[...number].joined(separator: "/"))")
    }

    /// Whether the host is dev.azure.com, or an organization's own, with a name of a single word.
    private static func isAzureDevOps(_ host: String) -> Bool {
        guard host != "dev.azure.com" else { return true }
        guard host.hasSuffix(".visualstudio.com") else { return false }
        let organization = host.dropLast(".visualstudio.com".count)
        return !organization.isEmpty && organization.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}

/// Follows runs' session logs off the main thread, reading only what's new each time.
public actor RunMonitor {
    private var readers: [String: EventLogReader] = [:]

    public init() {}

    /// What a session log says now; nil until Copilot has written one, and for a symbolic link, which isn't followed.
    public func log(id: String, events: URL) -> SessionLogState? {
        guard !LocalFile.isLink(events) else { return nil }
        let reader = readers[id] ?? EventLogReader(url: events)
        readers[id] = reader
        reader.update()
        return reader.isLoaded ? reader.state : nil
    }

    public func forget(_ id: String) {
        readers[id] = nil
    }
}
