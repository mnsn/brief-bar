import BriefBarCore
import Foundation

public enum LaunchError: Error, Sendable, Equatable, CustomStringConvertible {
    case copilotNotFound
    case git(GitError)
    case couldntStart(String)
    /// The Copilot app has the session open: a turn the CLI ran in it now is one the app would never see.
    case openInApp
    /// Another of the Copilot app's sessions runs a turn in the same checkout now: their work would mix.
    case sharedCheckout
    /// The Copilot CLI didn't fork the session (`CopilotLauncher.Request.forking`): why, in a sentence.
    case cantFork(String)
    /// Push & Reply would push a merge of commits the branch the pull request merges into doesn't have
    /// (`Git.checkPush(in:source:target:)`): that branch.
    case foreignMerge(target: String)
    /// BriefBar couldn't check what Push & Reply would push: what git said.
    case cantCheckPush(String)
    /// The pull request merges into another branch now than the one Push & Reply's prompt names, and the session was checked
    /// against (`TaskPullRequest.targetBranch`): that branch.
    case retargeted(String)
    /// BriefBar couldn't read which branch the pull request merges into now (`Request.targetNow`): why.
    case cantReadTarget(String)

    public var description: String {
        switch self {
        case .copilotNotFound: return "The Copilot CLI isn't installed. Install it with brew install copilot-cli."
        case .git(let error): return error.description
        case .couldntStart(let message): return "Copilot couldn't start: \(message)"
        case .openInApp:
            return "The Copilot app has this session open, and wouldn't see what Copilot did in it from here. Open it in Copilot, and send it there."
        case .sharedCheckout:
            return "Another Copilot session is working in the same checkout now, so Copilot didn't start there on its own. Send it again once that's done, or open the session in Copilot."
        case .cantFork(let reason): return reason
        case .foreignMerge(let target):
            return "This session holds a merge that \(target) doesn't have, so Copilot didn't push from it. Fix the pull request in a new session."
        case .cantCheckPush(let message):
            return "BriefBar couldn't check what this session would push, so Copilot didn't push from it: \(message)"
        case .retargeted(let target):
            return "The pull request merges into \(target) now, not the branch its prompt named, so Copilot didn't push from this session. Send Push & Reply again, for a prompt that names \(target)."
        case .cantReadTarget(let why):
            return "BriefBar couldn't read which branch the pull request merges into, so Copilot didn't push from this session: \(why)"
        }
    }
}

/// Sends a task to Copilot: a new worktree of the repository, at the latest base branch for a work item or at a pull
/// request's latest commit for a pull request, and the Copilot CLI working in it on its own, with your environment, your
/// sign-in, your MCP servers and your instructions, until it calls the task done. Or a session that's already there, to
/// go on with it: an earlier task's, in its worktree, or one of the Copilot app's, in the folder it works in, unless the
/// app has it open. Or a fork of such a session, which has its whole history, in a new worktree of its own. Nothing opens:
/// BriefBar follows the run from its session log.
public struct CopilotLauncher: Sendable {
    public struct Request: Sendable {
        public var subject: TaskSubject
        public var prompt: String
        public var options: CopilotRunOptions
        /// A folder in the repository's main checkout, which a fork's worktree is made from too; going on with one of the
        /// Copilot app's sessions, the folder it works in.
        public var repository: URL
        /// Where worktrees go; next to the repository when nil.
        public var worktreesFolder: URL?
        /// A session to go on with, rather than a new one: an earlier run's, in its worktree, or one of the Copilot app's
        /// (`CopilotRun.isAppSession`), in the folder it works in.
        public var continuing: CopilotRun?
        /// A session to fork, rather than start a new one or go on with one: an earlier run's, or one of the Copilot app's.
        /// Copilot works in its fork, a new session with its whole history, as the Copilot CLI saved it, in a new worktree,
        /// `<worktree>-fork`, detached at the commit its checkout has (`Git.head(of:in:)`); or, when it doesn't work in a
        /// checkout that shares this repository's commits, where a new task's worktree would start. The session itself, its
        /// history and its checkout, stay as they were, even while it works, or the Copilot app has it open; and so do its
        /// changes that aren't committed, which the fork's worktree doesn't have, as with the CLI's own `/fork worktree`.
        public var forking: CopilotRun?
        /// For Push & Reply, reads the branch the pull request merges into now, as Azure DevOps says: right before git
        /// checks what the session would push against `targetBranch`, the one its prompt names, and again right before
        /// Copilot starts. When it's another, or it throws, as when it can't be read, Copilot doesn't start
        /// (`LaunchError.retargeted`, `LaunchError.cantReadTarget`). Nil when nothing reads it.
        public var targetNow: (@Sendable () async throws -> String)?

        public init(
            subject: TaskSubject, prompt: String, options: CopilotRunOptions, repository: URL, worktreesFolder: URL?,
            continuing: CopilotRun? = nil, forking: CopilotRun? = nil, targetNow: (@Sendable () async throws -> String)? = nil
        ) {
            self.subject = subject
            self.prompt = prompt
            self.options = options
            self.repository = repository
            self.worktreesFolder = worktreesFolder
            self.continuing = continuing
            self.forking = forking
            self.targetNow = targetNow
        }

        public init(workItem: TaskWorkItem, prompt: String, options: CopilotRunOptions, repository: URL, worktreesFolder: URL?) {
            self.init(subject: .workItem(workItem), prompt: prompt, options: options, repository: repository, worktreesFolder: worktreesFolder)
        }

        public var workItem: TaskWorkItem? {
            if case .workItem(let item) = subject { return item }
            return nil
        }
    }

    /// Where what each run prints goes.
    let outputFolder: URL
    let runner: any ProcessRunning
    let environment: @Sendable () async -> [String: String]
    let locate: @Sendable ([String: String]) -> URL?
    /// The Copilot app's folder: whose sessions it keeps out of, when one of them runs a turn in the same checkout.
    let appHome: URL
    /// Where the forks it couldn't delete yet are kept, each deleted before the next task; nowhere when nil.
    let leftovers: (any LeftoverForks)?

    /// - Parameters:
    ///   - environment: what Copilot and git run with; by default, your login shell's (`LoginEnvironment`).
    ///   - locate: finds `copilot` in that environment; by default, `CopilotCLI.locate`.
    ///   - appHome: the Copilot app's folder; by default, `AppSessions.home()`.
    ///   - leftovers: where the forks it couldn't delete yet are kept, with BriefBar's runs, each deleted before the next
    ///     task; nowhere when nil.
    public init(
        outputFolder: URL, runner: any ProcessRunning = ProcessRunner(),
        environment: (@Sendable () async -> [String: String])? = nil,
        locate: @escaping @Sendable ([String: String]) -> URL? = { CopilotCLI.locate(environment: $0) },
        appHome: URL = AppSessions.home(), leftovers: (any LeftoverForks)? = nil
    ) {
        self.appHome = appHome
        self.leftovers = leftovers
        self.outputFolder = outputFolder
        self.runner = runner
        self.environment = environment ?? { await LoginEnvironment.load(runner: runner) }
        self.locate = locate
    }

    /// Gets the worktree ready and starts Copilot in it. `onExit` hears how its process ended, if BriefBar is still
    /// running then. Going on with a session, its ID is the run's, and its worktree or folder is kept; it doesn't start
    /// while the Copilot app has that session open (`LaunchError.openInApp`). Forking one, the fork's ID is the run's,
    /// which the CLI chooses: `forked` hears it once the fork is made, before its worktree is, and before Copilot starts, so
    /// that how it ends can be told by it; if the task can't start, the fork is deleted.
    /// - Parameter id: the new session's ID; for a fork, the CLI chooses it.
    public func launch(
        _ request: Request, id: String = UUID().uuidString.lowercased(), now: Date = Date(),
        forked: (@Sendable (String) -> Void)? = nil, onExit: @escaping @Sendable (Int32) -> Void
    ) async throws -> CopilotRun {
        guard request.continuing == nil || request.forking == nil else {
            throw LaunchError.couldntStart("a task goes on with a session or forks one, not both")
        }
        var id = request.continuing?.id ?? id
        for session in [id, request.forking?.id].compactMap({ $0 }) where !AppSessions.isSessionID(session) {
            throw LaunchError.couldntStart("a session's ID is a lowercase UUID")
        }
        let environment = await environment()
        guard let copilot = locate(environment) else { throw LaunchError.copilotNotFound }
        let home = CopilotCLI.home(environment: environment)
        if let continuing = request.continuing {
            // While the app has it open, its history is in the app's memory: a turn run here would fork it.
            if AppSessions.isOpen(id, home: home) { throw LaunchError.openInApp }
            if continuing.isAppSession == true, !FileManager.default.fileExists(atPath: continuing.events(in: home).path) {
                throw LaunchError.couldntStart("the Copilot CLI has no session \(id) in \(UserPath.abbreviate(home.path))")
            }
        }
        if let forking = request.forking, !FileManager.default.fileExists(atPath: forking.events(in: home).path) {
            throw LaunchError.couldntStart("the Copilot CLI has no session \(forking.id) in \(UserPath.abbreviate(home.path))")
        }
        let git = Git(
            executable: LoginEnvironment.which("git", in: environment) ?? URL(fileURLWithPath: "/usr/bin/git"),
            environment: environment, runner: runner
        )
        let repository: GitRepository
        do {
            repository = try await git.repository(at: request.repository)
            if case .pullRequest(let pullRequest, _) = request.subject {
                try await git.validate(repository, for: pullRequest)
            }
        } catch let error as GitError {
            throw LaunchError.git(error)
        }
        // The fork first: it takes a moment, and says at once when this Copilot CLI can't make one. Forks left over from
        // before go before it, or before any other task.
        let forker = SessionForker(copilot: copilot, environment: environment, leftovers: leftovers)
        var fork: String?
        if let forking = request.forking {
            let made = try await forker.fork(forking.id, name: CopilotCommand.sessionName(for: request.subject))
            fork = made
            id = made
            forked?(made)
        } else {
            await forker.deleteLeftovers()
        }
        let worktree: URL
        var made = false
        do {
            if let continuing = request.continuing {
                // Its worktree, or the app's session's folder, as the session left it: what it changed is what this run
                // goes on with.
                guard FileManager.default.fileExists(atPath: continuing.worktree.path) else {
                    throw LaunchError.couldntStart("its worktree, \(continuing.worktree.path), isn't there anymore")
                }
                worktree = continuing.worktree
            } else {
                // A fork's starts where the session's checkout is, when it's this repository's.
                let head: String?
                if let forking = request.forking {
                    head = await git.head(of: forking.worktree, in: repository)
                } else {
                    head = nil
                }
                let folder = request.worktreesFolder ?? WorktreeLocation.defaultFolder(for: repository.root)
                let name = request.subject.worktreeName + (request.forking == nil ? "" : "-fork")
                worktree = WorktreeLocation.path(in: folder, repository: repository.name, name: name) {
                    FileManager.default.fileExists(atPath: $0.path)
                }
                if let head {
                    try FileManager.default.createDirectory(at: worktree.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try await git.addWorktree(of: repository, at: worktree, commit: head)
                } else {
                    let branch: String
                    switch request.subject {
                    case .workItem:
                        try await git.fetch(repository)
                        branch = repository.baseBranch
                    case .pullRequest(let pullRequest, _):
                        try await git.fetch(repository, branch: pullRequest.sourceBranch)
                        branch = pullRequest.sourceBranch
                    }
                    try FileManager.default.createDirectory(at: worktree.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if branch == repository.baseBranch, case .workItem = request.subject {
                        try await git.addWorktree(of: repository, at: worktree)
                    } else {
                        try await git.addWorktree(of: repository, at: worktree, branch: branch)
                    }
                }
                made = true
            }
        } catch {
            if let fork { await forker.discard(fork) }
            if let error = error as? GitError { throw LaunchError.git(error) }
            throw error
        }
        // Push & Reply pushes what the session's checkout holds: never a merge of commits the branch the pull request merges
        // into doesn't have, as when it was retargeted after its conflicts were resolved there. A new session's worktree
        // starts at the branch's latest commit, with nothing to push yet.
        if case .pullRequest(let pullRequest, .pushAndReply) = request.subject, request.continuing != nil || request.forking != nil {
            // Against the branch the prompt names, while the pull request merges into it, as Azure DevOps says now: the
            // list may not have read a retarget yet.
            var refusal = await Self.targetProblem(of: request, pullRequest)
            if refusal == nil {
                do {
                    if try await git.checkPush(in: worktree, source: pullRequest.sourceBranch, target: pullRequest.targetBranch) == .foreignMerge {
                        refusal = .foreignMerge(target: pullRequest.targetBranch)
                    }
                } catch {
                    refusal = .cantCheckPush((error as? GitError)?.description ?? String(describing: error))
                }
            }
            // Again, once git is done, right before Copilot starts.
            if refusal == nil { refusal = await Self.targetProblem(of: request, pullRequest) }
            if let refusal {
                if made { try? await git.removeWorktree(at: worktree, of: repository.root, force: true) }
                if let fork { await forker.discard(fork) }
                throw refusal
            }
        }
        // Again, after the git commands above, right before it starts: the app may have opened the session meanwhile, or
        // another of its sessions started a turn in the same checkout.
        if request.continuing != nil {
            if AppSessions.isOpen(id, home: CopilotCLI.home(environment: environment)) { throw LaunchError.openInApp }
            if AppSessions.anotherRunsATurn(inCheckoutOf: worktree, besides: id, home: appHome) { throw LaunchError.sharedCheckout }
        }

        // A new session is named for what it's for; one that's there, a fork included, keeps its name.
        let isNew = request.continuing == nil && request.forking == nil
        // Only a work item's prompt has the base branch to fill in. A pull request's has no placeholders, but quotes what
        // others wrote, such as a suggested change, which may hold `{baseBranch}` as it's written: it goes as it is.
        let prompt = request.workItem == nil ? request.prompt : PromptTemplate.render(request.prompt, baseBranch: repository.baseBranch)
        let arguments = CopilotCommand.arguments(
            prompt: prompt, options: request.options,
            sessionId: id, name: isNew ? CopilotCommand.sessionName(for: request.subject) : nil, directory: worktree,
            denied: request.subject.deniedTools
        )
        // Going on with a fork, it's still that session's fork.
        let forkedFrom = request.forking?.id ?? request.continuing?.forkedFrom
        var run: CopilotRun
        switch request.subject {
        case .workItem(let item):
            run = CopilotRun(
                id: id, workItem: item.reference, options: request.options, repository: repository.root, worktree: worktree,
                startedAt: now, process: DetachedProgram.Handle(pid: 0, startedAt: nil), pullRequest: request.continuing?.pullRequest,
                isAppSession: request.continuing?.isAppSession, forkedFrom: forkedFrom
            )
        case .pullRequest(let pullRequest, let action):
            // Going on with the session of the work item's task that opened it, the run stays that work item's too; a fork
            // of it is a task of its own.
            run = CopilotRun(
                id: id, workItem: request.continuing?.workItem, onPullRequest: pullRequest.reference, action: action,
                options: request.options, repository: repository.root, worktree: worktree, startedAt: now,
                process: DetachedProgram.Handle(pid: 0, startedAt: nil), pullRequest: pullRequest.url,
                isAppSession: request.continuing?.isAppSession, forkedFrom: forkedFrom
            )
        }
        do {
            try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            run.process = try DetachedProgram.start(
                copilot, arguments: arguments, environment: environment, output: run.output(in: outputFolder), onExit: onExit
            )
        } catch {
            try? FileManager.default.removeItem(at: run.output(in: outputFolder))
            if made { try? await git.removeWorktree(at: worktree, of: repository.root, force: true) }
            if let fork { await forker.discard(fork) }
            throw LaunchError.couldntStart(String(describing: error))
        }
        // The fork is the task's session now, no longer one to delete.
        if let fork { await forker.forget(fork) }
        return run
    }

    /// Why Push & Reply mustn't go now, by the branch the pull request merges into as `Request.targetNow` reads it: another
    /// than the one its prompt names, or none it could read. Nil when it's that one, or nothing reads it.
    static func targetProblem(of request: Request, _ pullRequest: TaskPullRequest) async -> LaunchError? {
        guard let targetNow = request.targetNow else { return nil }
        do {
            let target = try await targetNow()
            return target == pullRequest.targetBranch ? nil : .retargeted(target)
        } catch {
            return .cantReadTarget(String(describing: error))
        }
    }
}
