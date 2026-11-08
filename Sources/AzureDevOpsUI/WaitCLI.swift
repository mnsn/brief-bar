import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation

/// `--wait`: waits on one of your pull requests for an agent, such as a Copilot session that started it in the background
/// and ended its turn, which this ending then wakes. It ends on what the session would act on: its next build's result,
/// comments that wait on you, merge conflicts, or its closing; or at its timeout, 90 minutes unless it says otherwise, two
/// hours at most, since a session waiting on a pipeline that runs an hour stays busy for nothing, and wakes up whatever
/// the result. What it prints is what `pull_request_prompt` gives for what happened, and its exit code says which.
///
/// It reads that pull request alone, as the app reads one sent to you, every minute: its details, and once each failed
/// build's timeline (`PulseEngine`, with no organizations). Like `--mcp`, it answers only while you let agents use
/// BriefBar and Azure DevOps is on in the app, checked before each read. The demo waits a second for the demo's one change.
enum WaitCLI {
    static let flag = "--wait"
    /// How long it waits unless told otherwise, and at most, in minutes.
    static let defaultMinutes = 90
    static let mostMinutes = 120
    /// How often it reads the pull request.
    static let interval: TimeInterval = 60
    /// Reads in a row that fail before it stops.
    static let mostFailures = 5

    /// What its exit code says.
    enum Exit: Int32, CaseIterable {
        case passed = 0
        case couldntRead = 1
        case usage = 2
        case timedOut = 3
        case buildFailed = 4
        case comments = 5
        case conflicts = 6
        case closed = 7
    }

    /// The pull request to wait on, and for how long.
    struct Request: Equatable, Sendable {
        var key: PRKey
        var minutes: Int
    }

    /// How it ended: its exit code, what it prints, and what it says on standard error. An error for arguments it refuses.
    struct Ended: Error, Equatable, Sendable {
        var exit: Exit
        var output: String = ""
        var error: String = ""
    }

    /// What Azure DevOps says of a pull request the engine found closed, or couldn't read.
    enum Found: Equatable, Sendable {
        case status(PullRequest.Status)
        /// Someone else's, whatever its status: it waits only on yours.
        case notYours
        /// Why it couldn't be read.
        case unreadable(String)
    }

    /// What a pull request read on its own says, for one the engine found closed: its status, once it's yours, as the
    /// engine tells yours, by who created it; `me`, your ID there.
    static func found(_ pullRequest: PullRequest, me: String) -> Found {
        pullRequest.author.id == me.lowercased() ? .status(pullRequest.status) : .notYours
    }

    // MARK: Arguments

    /// `--wait <link or number> [--org <name>] [--timeout <minutes>]`. A number alone is in the one organization `--org`
    /// names, or the app reads.
    static func request(_ arguments: [String], organizations named: [String], appOrganizations: [String]) -> Result<Request, Ended> {
        func usage(_ message: String) -> Result<Request, Ended> {
            .failure(Ended(exit: .usage, error: "\(message)\n\(usageLine)"))
        }
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
            return usage("Name the pull request to wait on, by its link or its number.")
        }
        // Each --org with a name: the options take the word after it for one, even another option, and leave out one
        // without, which would read the app's organization instead.
        for org in arguments.indices where arguments[org] == "--org" {
            let name = org + 1 < arguments.count ? arguments[org + 1].trimmingCharacters(in: .whitespaces) : ""
            guard !name.isEmpty, !name.hasPrefix("--") else { return usage("--org takes an organization's name.") }
        }
        let target = arguments[index + 1].trimmingCharacters(in: .whitespaces)
        let key: PRKey
        if let link = PullRequestLink.find(in: target).first {
            key = link.key
        } else if let number = Int(target.hasPrefix("!") ? String(target.dropFirst()) : target), number > 0 {
            // Azure DevOps ignores the letter case of an organization's name.
            var organizations: [String] = []
            for name in named.isEmpty ? appOrganizations : named
            where !organizations.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                organizations.append(name)
            }
            guard organizations.count == 1, let organization = organizations.first else {
                return usage("Give !\(number)'s link, or its organization with --org.")
            }
            key = PRKey(organization, number)
        } else {
            return usage("“\(QuotedText.oneLine(target))” is neither a pull request's link nor its number.")
        }
        var minutes = defaultMinutes
        if let timeout = arguments.firstIndex(of: "--timeout") {
            guard timeout + 1 < arguments.count, let value = Int(arguments[timeout + 1]), (1...mostMinutes).contains(value) else {
                return usage("--timeout takes the minutes to wait, from 1 to \(mostMinutes).")
            }
            minutes = value
        }
        return .success(Request(key: key, minutes: minutes))
    }

    static let usageLine = "Usage: BriefBar --wait <pull request's link or number> [--org <name>] [--timeout <minutes, 1 to \(mostMinutes)>]"

    // MARK: Who may

    /// Why it can't wait, as `--mcp` would say: agents are off or paused, or Azure DevOps is off in the app. Nil when it can.
    static func refusal(_ defaults: UserDefaults?) -> String? {
        guard let defaults else { return AgentAccess.refusal(.off) }
        if let refusal = AgentAccess.refusal(AgentAccess.state(in: defaults)) { return refusal }
        guard SourceChoices.load(from: defaults).state(of: .azureDevOps, version: AzureDevOpsSource.descriptionVersion) == .on else {
            return AgentAccess.refusal(source: "Azure DevOps")
        }
        return nil
    }

    // MARK: Running

    /// Runs `--wait`, for the command line: prints how it ended, and returns its exit code.
    static func run(_ options: CommandLineOptions) -> Int32 {
        let work = AzureDevOpsCommandLine.Options(options)
        let appOrganizations = work.demo ? [DemoData.organization]
            : AzureDevOpsCommandLine.appDefaults?.stringArray(forKey: SettingsKey.organizations) ?? []
        let ended: Ended
        switch request(options.arguments, organizations: work.organizations, appOrganizations: appOrganizations) {
        case .failure(let refused):
            ended = refused
        case .success(let request):
            if work.demo {
                ended = AzureDevOpsCommandLine.wait { await demo(request) }
            } else if let refusal = refusal(AzureDevOpsCommandLine.appDefaults) {
                ended = Ended(exit: .couldntRead, error: refusal)
            } else {
                FileHandle.standardError.write(Data("\(starting(request))\n".utf8))
                let waiter = live(request)
                ended = AzureDevOpsCommandLine.wait { await waiter.run() }
            }
        }
        if !ended.output.isEmpty { print(ended.output) }
        if !ended.error.isEmpty { FileHandle.standardError.write(Data("\(ended.error)\n".utf8)) }
        return ended.exit.rawValue
    }

    /// What it says as it starts, on standard error.
    static func starting(_ request: Request) -> String {
        let minutes = request.minutes == 1 ? "a minute" : "\(request.minutes) minutes"
        return "Waiting up to \(minutes) for !\(request.key.number)'s next build, comments that wait on you, or merge conflicts…"
    }

    /// The wait on your own data: one engine that reads the pull request alone, and all of it, whenever the waiter asks,
    /// every minute (`PulseEngine.Configuration.waiting`).
    static func live(_ request: Request) -> Waiter {
        let client = ADOClient(tokens: AzureDevOpsCommandLine.tokens())
        let engine = PulseEngine(client: client, configuration: .waiting(interval: interval)) { _ in }
        let key = request.key
        return Waiter(
            request: request,
            read: {
                await engine.setLinkedPullRequests([key])
                await engine.refreshNow()
                return await engine.currentSnapshot()
            },
            status: {
                do {
                    let me = try await client.get(ADOEndpoint.connectionData(organization: key.organization), as: ADOConnectionData.self)
                        .authenticatedUser.id
                    let dto = try await client.get(ADOEndpoint.pullRequest(organization: key.organization, id: key.number), as: ADOPullRequest.self)
                    return found(PullRequest(organization: key.organization, dto), me: me)
                } catch {
                    return .unreadable(AzureDevOpsCommandLine.describe(error))
                }
            },
            prompt: { action, record in await PullRequestTasks.prompt(action, for: record, client: client, workplace: .agent) },
            refusal: { refusal(AzureDevOpsCommandLine.appDefaults) }
        )
    }

    /// The demo: the made-up pull request as it is, then a second later as the demo's one change leaves it, as `--watch`
    /// shows it, with nothing more after that.
    static func demo(_ request: Request) async -> Ended {
        let snapshot = DemoData.snapshot(now: Date())
        guard let baseline = snapshot.records.first(where: { $0.id == request.key }) else {
            return Ended(exit: .couldntRead, error: "!\(request.key.number) isn't among the demo's pull requests.")
        }
        guard baseline.role == .author else { return notYours(request.key) }
        let prompt: @Sendable (PullRequestAction, PRRecord) async -> String = { action, record in
            await PullRequestTasks.prompt(action, for: record, client: nil, workplace: .agent)
        }
        let atOnce = WaitOutcome.since(baseline, in: baseline)
        if !atOnce.isEmpty { return await ended(atOnce, on: baseline, prompt: prompt) }
        try? await Task.sleep(for: .seconds(1))
        let updated = DemoData.update(snapshot, at: Date())
        if let current = updated.records.first(where: { $0.id == request.key }) {
            let outcomes = WaitOutcome.since(baseline, in: current)
            if !outcomes.isEmpty { return await ended(outcomes, on: current, prompt: prompt) }
        }
        return Ended(exit: .timedOut, output: "That's all the demo does: nothing more happens to !\(request.key.number).")
    }

    static func notYours(_ key: PRKey) -> Ended {
        Ended(exit: .usage, error: "!\(key.number) isn't yours: --wait waits only on your own pull requests.")
    }

    /// Waits on one pull request, reading it with `read` every minute until something happens or its time is up: what it
    /// needs from Azure DevOps comes through its closures, so tests give their own.
    struct Waiter: Sendable {
        var request: Request
        /// Reads the pull request: the engine's snapshot after a refresh.
        var read: @Sendable () async -> PulseSnapshot
        /// The pull request's status, for one the engine found closed or couldn't read: or what went wrong reading it.
        var status: @Sendable () async -> Found
        /// The prompt for what happened, as `pull_request_prompt` writes it.
        var prompt: @Sendable (PullRequestAction, PRRecord) async -> String
        /// Why it can't go on, such as agents turned off meanwhile: checked before each read.
        var refusal: @Sendable () -> String?
        var now: @Sendable () -> Date = { Date() }
        var sleep: @Sendable (TimeInterval) async -> Void = { seconds in try? await Task.sleep(for: .seconds(seconds)) }

        func run() async -> Ended {
            let key = request.key
            let deadline = now().addingTimeInterval(TimeInterval(request.minutes) * 60)
            var baseline: PRRecord?
            var latest: PRRecord?
            // When the read before had read the pull request itself, and its details.
            var previous: (pullRequest: Date?, details: Date?) = (nil, nil)
            var failures = 0
            var problem: String?
            while true {
                if let refusal = refusal() { return Ended(exit: .couldntRead, error: refusal) }
                let snapshot = await read()
                if snapshot.closedLinks.contains(key) { return await closed() }
                // A read counts once it read both the pull request and its details again: one that fails leaves what it
                // couldn't read as it was, such as the pull request's conflicts while its policies are read anew.
                let record = snapshot.records.first { $0.id == key }
                let current = (pullRequest: snapshot.linkedReadAt[key], details: record?.details?.fetchedAt)
                let isFresh = current.pullRequest != nil && current.details != nil
                    && current.pullRequest != previous.pullRequest && current.details != previous.details
                previous = current
                if isFresh, let record, record.role != .author { return notYours(key) }
                // Policies you can't read leave its builds unknown, rather than none: such a read doesn't count either.
                if isFresh, let record, record.details?.checksKnown == true {
                    failures = 0
                    latest = record
                    let start = baseline ?? record
                    baseline = start
                    let outcomes = WaitOutcome.since(start, in: record)
                    if !outcomes.isEmpty { return await ended(outcomes, on: record, prompt: prompt) }
                } else {
                    failures += 1
                    problem = isFresh ? unreadablePolicies : snapshot.problem.map(AzureDevOpsCommandLine.text(of:)) ?? problem
                    if failures >= mostFailures {
                        let why = problem ?? "Check that you're signed in to the Azure CLI (az login), that you're online, and the link."
                        return Ended(exit: .couldntRead, error: "Couldn't read !\(key.number) \(failures) times in a row. \(why)")
                    }
                }
                let left = deadline.timeIntervalSince(now())
                guard left > 0 else { return timedOut(latest) }
                await sleep(min(interval, left))
            }
        }

        /// Why a read whose policies Azure DevOps didn't let it read doesn't count, as a pull request's details say it.
        private var unreadablePolicies: String {
            "Its project doesn't let you read its policies, so BriefBar can't tell how its builds stand."
        }

        /// The engine found it closed, or couldn't read it: which, as Azure DevOps says now; or, closed as it began,
        /// someone else's.
        private func closed() async -> Ended {
            let number = request.key.number
            switch await status() {
            case .notYours: return notYours(request.key)
            case .status(.completed): return Ended(exit: .closed, output: "!\(number) was completed.")
            case .status(.abandoned): return Ended(exit: .closed, output: "!\(number) was abandoned.")
            case .status: return Ended(exit: .couldntRead, error: "BriefBar can't read !\(number) now: you may no longer read it.")
            case .unreadable(let why): return Ended(exit: .couldntRead, error: "BriefBar can't read !\(number): \(why)")
            }
        }

        private func timedOut(_ latest: PRRecord?) -> Ended {
            let number = request.key.number
            let minutes = request.minutes == 1 ? "a minute" : "\(request.minutes) minutes"
            guard let latest else {
                return Ended(exit: .couldntRead, error: "Couldn't read !\(number) within \(minutes).")
            }
            // Nothing runs, though a build that blocks it hasn't passed: it may have to be queued again.
            let running = WaitOutcome.running(in: latest)
            let stalled = WaitOutcome.stalled(in: latest)
            let what: String
            if !running.isEmpty {
                what = names(running) + (running.count == 1 ? " is" : " are") + " still "
                    + (running.allSatisfy { $0.state == .queued } ? "queued." : "running.")
            } else if !stalled.isEmpty {
                what = names(stalled) + (stalled.count == 1 ? " hasn't passed, and isn't running." : " haven't passed, and aren't running.")
            } else {
                what = "no build ran, nobody commented, and it has no merge conflicts."
            }
            return Ended(
                exit: .timedOut,
                output: "Stopped waiting for !\(number) after \(minutes): \(what)\n\(latest.pullRequest.webURL.absoluteString)"
            )
        }
    }

    // MARK: What it prints

    /// What happened, a line each, its link, then the prompt for each of them, as `pull_request_prompt` gives it: the exit
    /// code is the first one's.
    static func ended(
        _ outcomes: [WaitOutcome], on record: PRRecord, prompt: @Sendable (PullRequestAction, PRRecord) async -> String
    ) async -> Ended {
        let pr = record.pullRequest
        let number = "!\(pr.key.number)"
        var lines: [String] = []
        var prompts: [String] = []
        var exits: [Exit] = []
        for outcome in outcomes {
            switch outcome {
            case .buildFailed(let builds):
                lines.append("\(number)'s build failed: \(names(builds)).")
                prompts.append(await prompt(.fixBuild, record))
                exits.append(.buildFailed)
            case .conflicts:
                lines.append("\(number) has merge conflicts with \(QuotedText.commandWord(pr.targetBranch)).")
                prompts.append(await prompt(.resolveConflicts, record))
                exits.append(.conflicts)
            case .comments(let threads):
                lines.append(threads.count == 1
                    ? "A comment thread on \(number) waits on you." : "\(threads.count) comment threads on \(number) wait on you.")
                prompts.append(await prompt(.fixComments, record))
                exits.append(.comments)
            case .buildPassed(let builds):
                lines.append("\(number)'s build passed: \(names(builds)).")
                exits.append(.passed)
            }
        }
        let output = ([lines.joined(separator: "\n") + "\n" + pr.webURL.absoluteString] + prompts).joined(separator: "\n\n")
        return Ended(exit: exits.first ?? .passed, output: output)
    }

    /// “shop-web CI” and “shop-web tests”: names others chose, each on its line, as the agent's other text quotes them.
    static func names(_ builds: [Check]) -> String {
        let quoted = builds.map { "“\(QuotedText.oneLine($0.name))”" }
        guard quoted.count > 1 else { return quoted.first ?? "Its build" }
        return quoted.dropLast().joined(separator: ", ") + " and " + quoted[quoted.count - 1]
    }

    // MARK: For agents

    /// The command that waits on a pull request, for `pull_request` to give agents: this copy of BriefBar, with its 90
    /// minutes said, which an agent lowers to what the build needs.
    static func command(executable: String, link: URL, demo: Bool) -> String {
        [QuotedText.commandWord(executable), demo ? "--demo" : nil, flag, QuotedText.commandWord(link.absoluteString), "--timeout",
         String(defaultMinutes)].compactMap { $0 }.joined(separator: " ")
    }
}
