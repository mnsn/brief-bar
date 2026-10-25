import BriefBarCore
import Foundation

public enum LaunchError: Error, Sendable, Equatable, CustomStringConvertible {
    case copilotNotFound
    case git(GitError)
    case couldntStart(String)

    public var description: String {
        switch self {
        case .copilotNotFound: return "The Copilot CLI isn't installed. Install it with brew install copilot-cli."
        case .git(let error): return error.description
        case .couldntStart(let message): return "Copilot couldn't start: \(message)"
        }
    }
}

/// Sends a task to Copilot: a new worktree of the repository, at the latest base branch for a work item or at a pull
/// request's latest commit for a pull request, and the Copilot CLI working in it on its own, with your environment, your
/// sign-in, your MCP servers and your instructions, until it calls the task done. Or the same session again, in its
/// worktree, to go on with it. Nothing opens: BriefBar follows the run from its session log.
public struct CopilotLauncher: Sendable {
    public struct Request: Sendable {
        public var subject: TaskSubject
        public var prompt: String
        public var options: CopilotRunOptions
        /// A folder in the repository's main checkout.
        public var repository: URL
        /// Where worktrees go; next to the repository when nil.
        public var worktreesFolder: URL?
        /// An earlier run to go on with: its session, in its worktree, rather than a new one.
        public var continuing: CopilotRun?

        public init(
            subject: TaskSubject, prompt: String, options: CopilotRunOptions, repository: URL, worktreesFolder: URL?,
            continuing: CopilotRun? = nil
        ) {
            self.subject = subject
            self.prompt = prompt
            self.options = options
            self.repository = repository
            self.worktreesFolder = worktreesFolder
            self.continuing = continuing
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

    /// - Parameters:
    ///   - environment: what Copilot and git run with; by default, your login shell's (`LoginEnvironment`).
    ///   - locate: finds `copilot` in that environment; by default, `CopilotCLI.locate`.
    public init(
        outputFolder: URL, runner: any ProcessRunning = ProcessRunner(),
        environment: (@Sendable () async -> [String: String])? = nil,
        locate: @escaping @Sendable ([String: String]) -> URL? = { CopilotCLI.locate(environment: $0) }
    ) {
        self.outputFolder = outputFolder
        self.runner = runner
        self.environment = environment ?? { await LoginEnvironment.load(runner: runner) }
        self.locate = locate
    }

    /// Gets the worktree ready and starts Copilot in it. `onExit` hears how its process ended, if BriefBar is still
    /// running then. Going on with an earlier run, its session's ID is the run's, and its worktree is kept.
    public func launch(
        _ request: Request, id: String = UUID().uuidString.lowercased(), now: Date = Date(),
        onExit: @escaping @Sendable (Int32) -> Void
    ) async throws -> CopilotRun {
        let id = request.continuing?.id ?? id
        guard UUID(uuidString: id)?.uuidString.lowercased() == id else {
            throw LaunchError.couldntStart("a session's ID is a lowercase UUID")
        }
        let environment = await environment()
        guard let copilot = locate(environment) else { throw LaunchError.copilotNotFound }
        let git = Git(
            executable: LoginEnvironment.which("git", in: environment) ?? URL(fileURLWithPath: "/usr/bin/git"),
            environment: environment, runner: runner
        )
        let repository: GitRepository
        let worktree: URL
        var made = false
        do {
            repository = try await git.repository(at: request.repository)
            if let continuing = request.continuing {
                // Its worktree, as the earlier run left it: what it changed is what this one goes on with.
                guard FileManager.default.fileExists(atPath: continuing.worktree.path) else {
                    throw LaunchError.couldntStart("its worktree, \(continuing.worktree.path), isn't there anymore")
                }
                worktree = continuing.worktree
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
                let folder = request.worktreesFolder ?? WorktreeLocation.defaultFolder(for: repository.root)
                worktree = WorktreeLocation.path(in: folder, repository: repository.name, name: request.subject.worktreeName) {
                    FileManager.default.fileExists(atPath: $0.path)
                }
                try FileManager.default.createDirectory(at: worktree.deletingLastPathComponent(), withIntermediateDirectories: true)
                if branch == repository.baseBranch, case .workItem = request.subject {
                    try await git.addWorktree(of: repository, at: worktree)
                } else {
                    try await git.addWorktree(of: repository, at: worktree, branch: branch)
                }
                made = true
            }
        } catch let error as GitError {
            throw LaunchError.git(error)
        }

        let copilotHome = CopilotCLI.home(environment: environment)
        let config = LocalFile.tail(of: copilotHome.appendingPathComponent("config.json"), maxBytes: 1 << 20)
        let trusted = config.map(CopilotCLI.trustedFolders) ?? []
        let arguments = CopilotCommand.arguments(
            prompt: PromptTemplate.render(request.prompt, baseBranch: repository.baseBranch), options: request.options,
            sessionId: id, name: request.continuing == nil ? CopilotCommand.sessionName(for: request.subject) : nil, directory: worktree,
            trustFolder: CopilotCLI.isTrusted(repository.root, trusted: trusted)
        )
        var run: CopilotRun
        switch request.subject {
        case .workItem(let item):
            run = CopilotRun(
                id: id, workItem: item.reference, options: request.options, repository: repository.root, worktree: worktree,
                startedAt: now, process: DetachedProgram.Handle(pid: 0, startedAt: nil), pullRequest: request.continuing?.pullRequest
            )
        case .pullRequest(let pullRequest, let action):
            run = CopilotRun(
                id: id, workItem: nil, onPullRequest: pullRequest.reference, action: action, options: request.options,
                repository: repository.root, worktree: worktree, startedAt: now, process: DetachedProgram.Handle(pid: 0, startedAt: nil),
                pullRequest: pullRequest.url
            )
        }
        do {
            try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            run.process = try DetachedProgram.start(
                copilot, arguments: arguments, environment: environment, output: run.output(in: outputFolder), onExit: onExit
            )
            return run
        } catch {
            try? FileManager.default.removeItem(at: run.output(in: outputFolder))
            if made { try? await git.removeWorktree(at: worktree, of: repository.root, force: true) }
            throw LaunchError.couldntStart(String(describing: error))
        }
    }
}
