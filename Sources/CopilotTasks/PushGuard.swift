import BriefBarCore
import CopilotCore
import Foundation
import Synchronization

/// Push & Reply's check of each push, as Copilot makes it, in one of BriefBar's own Push & Reply tasks: the Copilot CLI
/// asks it about each shell command, before running it, through the `preToolUse` hook of the plugin BriefBar gives that
/// task alone (`PushGuardPlugin`, `--push-guard`). A command that pushes nothing runs. A push runs only in the form the
/// prompt names, `git push origin <commit>:refs/heads/<branch>`, optionally `git -C <worktree> …`, where `<commit>` is
/// what the worktree has checked out, with the options that keep it to that branch when git's configuration would push
/// more (`Git.pushOptions`), while git finds no merge in it of what the branch the prompt names doesn't have
/// (`Git.checkPush`), and then Azure DevOps says the pull request is active and merges into that branch. Pushed another way,
/// Copilot is told the command to run instead, and can try again; one that would force, delete or push more than the
/// branch, or that it would bring in what it mustn't, or that BriefBar can't check, is stopped, and the task fails with
/// why (`PushStop`). On top of the launcher's checks before Copilot starts, and the prompt's, which stay as they are.
public struct PushGuard: Sendable {
    /// What BriefBar says of a shell command Copilot is about to run.
    public enum Verdict: Sendable, Equatable {
        /// It runs: it pushes nothing, or its push passed.
        case allow
        /// It doesn't run, and Copilot is told how to push instead, to try again: what Copilot reads.
        case retry(String)
        /// It doesn't run, and Copilot is told to stop: what Copilot reads, which the task's line says too, once it's over.
        case stop(String)

        /// What the hook prints for it: nothing, to let it run, else the CLI's decision to deny it, with why.
        public var output: Data? {
            let reason: String
            switch self {
            case .allow: return nil
            case .retry(let why), .stop(let why): reason = why
            }
            return try? JSONSerialization.data(
                withJSONObject: ["permissionDecision": "deny", "permissionDecisionReason": reason],
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        }

        /// What it was, for the log: no reason, which names branches and commits.
        public var kind: String {
            switch self {
            case .allow: "allowed"
            case .retry: "asked to run it another way"
            case .stop: "stopped"
            }
        }
    }

    /// What a retry's reason starts with.
    public static let retryMarker = "BriefBar's push check: "
    /// What BriefBar says of a command longer than it reads: it doesn't run, since what BriefBar didn't read may push.
    public static func tooLong(_ bytes: Int) -> Verdict {
        .retry(retryMarker + "this command is longer than BriefBar reads (\(bytes / 1_048_576) MiB), so it didn't run. Run it in smaller parts.")
    }
    /// How long the check takes at most: the hook's limit is 300 seconds (`PushGuardPlugin.timeout`), after which the CLI
    /// lets the call through.
    public static let limit: TimeInterval = 240

    /// The folder the task works in, the pull request's branch, and the branch it merges into, as the prompt names them.
    public var worktree: URL
    public var source: String
    public var target: String
    let git: Git
    /// Reads the branch the pull request merges into now, as Azure DevOps says: throws when it can't be read, and
    /// `PullRequestNotActive` once it was completed or abandoned.
    let targetNow: @Sendable () async throws -> String
    let limit: TimeInterval

    public init(
        worktree: URL, source: String, target: String, git: Git, limit: TimeInterval = PushGuard.limit,
        targetNow: @escaping @Sendable () async throws -> String
    ) {
        self.worktree = worktree
        self.source = source
        self.target = target
        self.git = git
        self.limit = limit
        self.targetNow = targetNow
    }

    // MARK: Checking

    /// What BriefBar says of what the hook was given: the CLI's `preToolUse` input, `{toolName, toolArgs, …}`.
    public func check(_ payload: Data) async -> Verdict {
        let pushes: [(push: PushCommand.Push, form: PushCommand.Push.Form)]
        let isUnreadable: Bool
        switch Self.read(payload) {
        case .decided(let verdict):
            return verdict
        case .command(let command):
            let read = PushCommand(command)
            pushes = read.pushes.map { ($0, $0.form(worktree: worktree, branch: source)) }
            isUnreadable = read.isUnreadable
        }
        if let unsafe = pushes.lazy.compactMap(\.form.unsafe).first { return .stop(Self.stop(Self.why(unsafe))) }
        let found = pushes.filter { $0.form != .dryRun }
        guard !found.isEmpty || isUnreadable else { return .allow }
        let late = Verdict.stop(Self.stop("BriefBar couldn't check it in time."))
        return await Self.first(within: limit, otherwise: late) { await self.verify(found, isUnreadable: isUnreadable) }
    }

    /// What BriefBar says without checking: a push, or a command it can't read that may push, is stopped, with `reason`;
    /// anything else runs. As when the check can't run, such as with Azure DevOps off.
    public static func check(_ payload: Data, cantCheck reason: String) -> Verdict {
        switch read(payload) {
        case .decided(let verdict):
            return verdict
        case .command(let command):
            let read = PushCommand(command)
            guard read.isUnreadable || read.pushes.contains(where: { $0.form(worktree: URL(fileURLWithPath: "/"), branch: "") != .dryRun })
            else { return .allow }
            return .stop(stop(reason))
        }
    }

    /// A push in the form the prompt names, checked: the worktree's commit; the options git's configuration needs to push
    /// only the branch; what it would bring in; and last, so that what it says is as late as can be, the branch the pull
    /// request merges into now, and whether it's still active.
    private func verify(_ pushes: [(push: PushCommand.Push, form: PushCommand.Push.Form)], isUnreadable: Bool) async -> Verdict {
        let exact: (push: PushCommand.Push, commit: String)? =
            if !isUnreadable, pushes.count == 1, case .exact(let commit) = pushes[0].form { (pushes[0].push, commit) } else { nil }
        let several = pushes.count > 1
        let head: String
        do {
            head = try await git.commit(checkedOutIn: worktree)
        } catch {
            guard exact == nil else {
                return .stop(Self.stop("BriefBar couldn't read which commit the worktree has checked out: \(Self.words(error))"))
            }
            return .retry(retry(nil, options: [], isUnreadable: isUnreadable, several: several))
        }
        let options: [String]
        do {
            options = try await git.pushOptions(in: worktree)
        } catch {
            guard exact == nil else {
                return .stop(Self.stop("BriefBar couldn't read git's configuration in the worktree: \(Self.words(error))"))
            }
            return .retry(retry(head, options: [], isUnreadable: isUnreadable, several: several))
        }
        guard let (push, commit) = exact else {
            return .retry(retry(head, options: options, isUnreadable: isUnreadable, several: several))
        }
        guard commit == head else {
            return .retry(Self.retryMarker + "\(commit) isn't the commit the worktree has checked out. Push the one it has, in a command of its own, exactly: \(command(head, options: options)).")
        }
        let missing = options.filter { option in !push.arguments.contains { $0.isLiteral && $0.value == option } }
        guard missing.isEmpty else {
            return .retry(Self.retryMarker + "git's configuration in the worktree would push more than the branch with it, so it needs \(missing.joined(separator: " and ")). Run exactly: \(command(head, options: options)).")
        }
        do {
            if try await git.checkPush(in: worktree, source: source, target: target, commit: commit) == .foreignMerge {
                return .stop(Self.stop("what it would push has a merge of commits that \(QuotedText.commandWord(target)) doesn't have, which would bring another branch's work into the pull request."))
            }
        } catch {
            return .stop(Self.stop("BriefBar couldn't check what it would push: \(Self.words(error))"))
        }
        do {
            guard try await targetNow() == target else {
                return .stop(Self.stop("the pull request merges into another branch now than the one this task's prompt names."))
            }
        } catch let closed as PullRequestNotActive {
            return .stop(Self.stop(Self.why(closed)))
        } catch {
            return .stop(Self.stop("BriefBar couldn't read which branch the pull request merges into: \(Self.words(error))"))
        }
        return .allow
    }

    // MARK: What Copilot reads

    /// The push the check lets through: the worktree's commit, by its ID, or `<commit>` when that isn't known, to the pull
    /// request's branch, from the worktree, whatever folder the shell is in, with `options`, which keep it to that branch.
    func command(_ commit: String?, options: [String] = []) -> String {
        (["git -C \(QuotedText.commandWord(worktree.path)) push"] + options
            + ["origin \(commit ?? "<commit>"):refs/heads/\(QuotedText.commandWord(source))"]).joined(separator: " ")
    }

    private func retry(_ head: String?, options: [String], isUnreadable: Bool, several: Bool) -> String {
        let what = isUnreadable ? "BriefBar couldn't read this command, so it didn't run."
            : several ? "push once, in a command of its own." : "push only the commit the worktree has checked out, by its ID, to the pull request's branch, without force."
        let commit = head == nil ? ", where <commit> is what git rev-parse HEAD says there" : ""
        return Self.retryMarker + what + " Once your changes are committed, run exactly: \(command(head, options: options))\(commit)."
    }

    /// A stop's reason, as Copilot reads it and the log keeps it.
    static func stop(_ why: String) -> String {
        PushStop.marker + why + PushStop.ending
    }

    private static func why(_ unsafe: PushCommand.Push.Unsafe) -> String {
        switch unsafe {
        case .force: "it would force the pull request's branch, which can drop what's on it."
        case .delete: "it would delete what's on the remote."
        case .more: "it would push more than the pull request's branch."
        }
    }

    private static func why(_ closed: PullRequestNotActive) -> String {
        switch closed.status {
        case "completed", "abandoned": "the pull request was \(closed.status)."
        default: "the pull request isn't active."
        }
    }

    /// What went wrong, in a line, short.
    private static func words(_ error: Error) -> String {
        let text = (error as? GitError)?.description ?? String(describing: error)
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 300 ? String(line.prefix(299)) + "…" : line
    }

    // MARK: Reading the hook's input

    private enum Reading {
        case decided(Verdict)
        case command(String)
    }

    /// The shell command the hook's input says Copilot is about to run, from its `toolArgs`, which the CLI sends as a JSON
    /// string, or an object. Another tool runs; input it can't read is stopped when it says push, as it may be one.
    private static func read(_ payload: Data) -> Reading {
        let unreadable: Reading = String(decoding: payload, as: UTF8.self).contains("push")
            ? .decided(.stop(stop("BriefBar couldn't read the command."))) : .decided(.allow)
        guard let input = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let tool = input["toolName"] as? String
        else { return unreadable }
        guard tool == "bash" else { return .decided(.allow) }
        var arguments = input["toolArgs"] as? [String: Any]
        if let text = input["toolArgs"] as? String {
            arguments = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        }
        guard let command = arguments?["command"] as? String else { return unreadable }
        return .command(command)
    }

    // MARK: In time

    /// What `work` says, unless `limit` passes first: then `late`, and the work is cancelled, without waiting for it.
    static func first(
        within limit: TimeInterval, otherwise late: Verdict, _ work: @escaping @Sendable () async -> Verdict
    ) async -> Verdict {
        let answer = Answer()
        return await withCheckedContinuation { continuation in
            let worker = Task {
                let verdict = await work()
                if answer.claim() { continuation.resume(returning: verdict) }
            }
            let timer = Task {
                try? await Task.sleep(for: .seconds(limit))
                guard !Task.isCancelled, answer.claim() else { return }
                worker.cancel()
                continuation.resume(returning: late)
            }
            answer.whenAnswered { timer.cancel() }
        }
    }

    /// Who answers first: the work, or the timer.
    private final class Answer: Sendable {
        private let state = Mutex<(answered: Bool, then: (@Sendable () -> Void)?)>((false, nil))

        /// Whether this is the first answer.
        func claim() -> Bool {
            let (first, then) = state.withLock { state -> (Bool, (@Sendable () -> Void)?) in
                guard !state.answered else { return (false, nil) }
                state.answered = true
                return (true, state.then)
            }
            then?()
            return first
        }

        /// Runs `then` once it's answered, now if it is.
        func whenAnswered(_ then: @escaping @Sendable () -> Void) {
            let now = state.withLock { state -> Bool in
                guard !state.answered else { return true }
                state.then = then
                return false
            }
            if now { then() }
        }
    }
}
