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

    public init(
        id: String, workItem: WorkItemReference?, onPullRequest: PullRequestReference? = nil, action: PullRequestAction? = nil,
        options: CopilotRunOptions, repository: URL, worktree: URL, startedAt: Date, process: DetachedProgram.Handle,
        ended: RunPhase? = nil, pullRequest: URL? = nil, stoppedByYou: Bool? = nil, isAppSession: Bool? = nil
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
    ///   - exitStatus: how its process ended, when BriefBar saw it end.
    ///   - stoppedByYou: you stopped it.
    ///   - output: what it printed, which says why when it couldn't start.
    public static func derive(
        log: SessionLogState?, isRunning: Bool, exitStatus: Int32?, stoppedByYou: Bool, output: String?
    ) -> RunStatus {
        if isRunning {
            return RunStatus(phase: .working, detail: log?.phase == .running ? log?.currentStep : nil)
        }
        switch log?.phase {
        case .finished?:
            return RunStatus(phase: .finished, since: log?.phaseSince, detail: log?.summary)
        case .failed?:
            return RunStatus(phase: .failed, since: log?.phaseSince, detail: log?.errorMessage ?? lastLine(output))
        case .interrupted?:
            return RunStatus(phase: .stopped, since: log?.phaseSince)
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
        guard let data = LocalFile.tail(of: events, maxBytes: maxBytes) else { return (nil, nil) }
        var summary: String?
        var message: String?
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            if summary == nil, line.starts(with: Self.taskComplete) {
                summary = text(line, key: "summary")
            } else if message == nil, line.starts(with: Self.assistantMessage) {
                message = text(line, key: "content", mainAgentOnly: true)
            }
            if summary != nil && message != nil { break }
        }
        return (summary, message)
    }

    private static let taskComplete = Data(#"{"type":"session.task_complete""#.utf8)
    private static let assistantMessage = Data(#"{"type":"assistant.message""#.utf8)

    private static func text(_ line: Data, key: String, mainAgentOnly: Bool = false) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let data = object["data"] as? [String: Any]
        else { return nil }
        if mainAgentOnly, data["parentToolCallId"] is String || object["agentId"] is String { return nil }
        let value = (data[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
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
