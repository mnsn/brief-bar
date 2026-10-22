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

/// Sends a task to Copilot: a new worktree of the repository at the latest base branch, and the Copilot CLI working in
/// it on its own, with your environment, your sign-in, your MCP servers and your instructions, until it calls the task
/// done. Nothing opens: BriefBar follows the run from its session log.
public struct CopilotLauncher: Sendable {
    public struct Request: Sendable {
        public var workItem: TaskWorkItem
        public var prompt: String
        public var options: CopilotRunOptions
        /// A folder in the repository's main checkout.
        public var repository: URL
        /// Where worktrees go; next to the repository when nil.
        public var worktreesFolder: URL?

        public init(workItem: TaskWorkItem, prompt: String, options: CopilotRunOptions, repository: URL, worktreesFolder: URL?) {
            self.workItem = workItem
            self.prompt = prompt
            self.options = options
            self.repository = repository
            self.worktreesFolder = worktreesFolder
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
    /// running then.
    public func launch(
        _ request: Request, id: String = UUID().uuidString.lowercased(), now: Date = Date(),
        onExit: @escaping @Sendable (Int32) -> Void
    ) async throws -> CopilotRun {
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
        do {
            repository = try await git.repository(at: request.repository)
            try await git.fetch(repository)
            let folder = request.worktreesFolder ?? WorktreeLocation.defaultFolder(for: repository.root)
            worktree = WorktreeLocation.path(in: folder, repository: repository.name, workItem: request.workItem.id) {
                FileManager.default.fileExists(atPath: $0.path)
            }
            try FileManager.default.createDirectory(at: worktree.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await git.addWorktree(of: repository, at: worktree)
        } catch let error as GitError {
            throw LaunchError.git(error)
        }

        let copilotHome = CopilotCLI.home(environment: environment)
        let config = LocalFile.tail(of: copilotHome.appendingPathComponent("config.json"), maxBytes: 1 << 20)
        let trusted = config.map(CopilotCLI.trustedFolders) ?? []
        let arguments = CopilotCommand.arguments(
            prompt: PromptTemplate.render(request.prompt, baseBranch: repository.baseBranch), options: request.options,
            sessionId: id, name: CopilotCommand.sessionName(for: request.workItem), directory: worktree,
            trustFolder: CopilotCLI.isTrusted(repository.root, trusted: trusted)
        )
        var run = CopilotRun(
            id: id, workItem: request.workItem.reference, options: request.options, repository: repository.root,
            worktree: worktree, startedAt: now, process: DetachedProgram.Handle(pid: 0, startedAt: nil)
        )
        do {
            try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            run.process = try DetachedProgram.start(
                copilot, arguments: arguments, environment: environment, output: run.output(in: outputFolder), onExit: onExit
            )
            return run
        } catch {
            try? FileManager.default.removeItem(at: run.output(in: outputFolder))
            try? await git.removeWorktree(at: worktree, of: repository.root, force: true)
            throw LaunchError.couldntStart(String(describing: error))
        }
    }
}
