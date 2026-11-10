import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation

/// `--push-guard`: Push & Reply's check of each push, as Copilot makes it, in one of BriefBar's own Push & Reply tasks
/// (`PushGuard`). The Copilot CLI runs it before each of the task's shell commands, through the hook of the plugin BriefBar
/// gives that task alone (`PushGuardPlugin`), with what it's about to run on its standard input. It prints the CLI's
/// decision to deny a push, with why, and nothing for anything else, and always exits with 0: a hook that fails denies
/// every command. For a push in the form the prompt names, it reads the pull request from Azure DevOps, with one request,
/// only while Azure DevOps is on in the app, and runs git in the task's worktree, with the CLI's environment, which BriefBar
/// gave it. It logs what it did with a push it denied, never what that was.
enum PushGuardCLI {
    static let flag = PushGuardPlugin.flag
    /// The most it reads of what the CLI gives it: a command longer than that doesn't run, since what's past it may push.
    static let mostInput = 1 << 20

    /// The task's pull request, the folder it works in, the pull request's branch and the one it merges into, as the
    /// prompt names them.
    struct Request: Equatable, Sendable {
        var key: PRKey
        var worktree: URL
        var source: String
        var target: String
    }

    struct Usage: Error, Equatable, CustomStringConvertible {
        var description: String
    }

    static let usageLine = "Usage: BriefBar \(flag) <pull request's link> \(PushGuardPlugin.worktreeOption)<folder> \(PushGuardPlugin.sourceOption)<branch> \(PushGuardPlugin.targetOption)<branch>"

    /// What its arguments name, as the plugin writes them: the link, the word after the flag, and each option once, with its
    /// value; or what's missing.
    static func request(_ arguments: [String]) -> Result<Request, Usage> {
        func value(_ option: String) -> String? {
            let values = arguments.filter { $0.hasPrefix(option) }.map { String($0.dropFirst(option.count)) }
            guard values.count == 1, let value = values.first, !value.isEmpty else { return nil }
            return value
        }
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count,
              let link = PullRequestLink.find(in: arguments[index + 1]).first
        else { return .failure(Usage(description: "Name the pull request by its link.")) }
        guard let worktree = value(PushGuardPlugin.worktreeOption), worktree.hasPrefix("/") else {
            return .failure(Usage(description: "\(PushGuardPlugin.worktreeOption) takes the full path of the folder the task works in."))
        }
        guard let source = value(PushGuardPlugin.sourceOption), let target = value(PushGuardPlugin.targetOption) else {
            return .failure(Usage(description: "\(PushGuardPlugin.sourceOption) and \(PushGuardPlugin.targetOption) take the pull request's branch and the one it merges into."))
        }
        return .success(Request(key: link.key, worktree: URL(fileURLWithPath: worktree, isDirectory: true), source: source, target: target))
    }

    /// Why it can't check a push: Azure DevOps is off in the app. Nil while it's on.
    static func refusal(_ defaults: UserDefaults?) -> String? {
        guard let defaults,
              SourceChoices.load(from: defaults).state(of: .azureDevOps, version: AzureDevOpsSource.descriptionVersion) == .on
        else { return "Azure DevOps is off in BriefBar, so it can't read the pull request." }
        return nil
    }

    /// What it says of what the CLI gave it, `payload`, all of it unless `isWhole` is false: with the arguments it was
    /// started with, unless `refusal` says it can't read Azure DevOps, through the check `check` makes for them. The demo
    /// checks nothing, and stops every push. What it couldn't read all of doesn't run.
    static func verdict(
        for payload: Data, isWhole: Bool = true, arguments: [String], demo: Bool, refusal: @Sendable () -> String?,
        check: @Sendable (Request) -> PushGuard
    ) async -> PushGuard.Verdict {
        guard isWhole else { return PushGuard.tooLong(mostInput) }
        guard !demo else { return PushGuard.check(payload, cantCheck: "BriefBar's demo pushes nothing.") }
        let request: Request
        switch self.request(arguments) {
        case .failure(let usage):
            return PushGuard.check(payload, cantCheck: "BriefBar's check didn't get what it needs: \(usage)")
        case .success(let named):
            request = named
        }
        if let refusal = refusal() { return PushGuard.check(payload, cantCheck: refusal) }
        return await check(request).check(payload)
    }

    /// Runs `--push-guard`, for the CLI's hook: prints the decision, if any, and returns 0.
    static func run(_ options: CommandLineOptions) -> Int32 {
        let (payload, isWhole) = input()
        let arguments = options.arguments
        let demo = options.demo
        let decision: PushGuard.Verdict = AzureDevOpsCommandLine.wait { () async -> PushGuard.Verdict in
            await Self.verdict(
                for: payload, isWhole: isWhole, arguments: arguments, demo: demo,
                refusal: { Self.refusal(AzureDevOpsCommandLine.appDefaults) }, check: { Self.live($0) }
            )
        }
        if let output = decision.output {
            FileHandle.standardOutput.write(output + Data("\n".utf8))
        }
        if decision != PushGuard.Verdict.allow {
            Log.app.info("Push & Reply's check of a push: \(decision.kind, privacy: .public)")
        }
        return 0
    }

    /// What the CLI writes it, to its end, so that the CLI's writing ends: the first `mostInput` bytes, and whether that's
    /// all of it.
    static func input(_ handle: FileHandle = .standardInput) -> (data: Data, isWhole: Bool) {
        var data = Data()
        var total = 0
        while let chunk = try? handle.read(upToCount: 64 << 10), !chunk.isEmpty {
            total += chunk.count
            if data.count < mostInput { data.append(chunk.prefix(mostInput - data.count)) }
        }
        return (data, total <= mostInput)
    }

    /// The check on your own data: the pull request from Azure DevOps, with your Azure CLI sign-in, as the app reads it, and
    /// git, with the environment BriefBar gave the CLI, your login shell's.
    static func live(_ request: Request) -> PushGuard {
        let environment = Attribution.environment
        let git = Git(
            executable: LoginEnvironment.which("git", in: environment) ?? URL(fileURLWithPath: "/usr/bin/git"), environment: environment
        )
        let client = ADOClient(tokens: AzureDevOpsCommandLine.tokens())
        let key = request.key
        return PushGuard(worktree: request.worktree, source: request.source, target: request.target, git: git) {
            do {
                let dto = try await client.get(ADOEndpoint.pullRequest(organization: key.organization, id: key.number), as: ADOPullRequest.self)
                let pullRequest = PullRequest(organization: key.organization, dto)
                guard pullRequest.status == .active else { throw PullRequestNotActive(status: pullRequest.status.rawValue) }
                return pullRequest.targetBranch
            } catch let closed as PullRequestNotActive {
                throw closed
            } catch {
                throw Unread(description: AzureDevOpsCommandLine.describe(error))
            }
        }
    }

    /// Why Azure DevOps couldn't be read, as the command line says it.
    struct Unread: Error, CustomStringConvertible {
        var description: String
    }
}
