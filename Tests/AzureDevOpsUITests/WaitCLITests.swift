import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation
import Synchronization
import Testing
@testable import AzureDevOpsUI

/// `BriefBar --wait`, for agents: which pull request it waits on and for how long, who may, and how a wait ends. With
/// stand-ins for Azure DevOps and the clock, on the demo's made-up pull requests, which never use the Azure CLI or Azure
/// DevOps.
@Suite struct WaitCLITests {
    private let organization = DemoData.organization
    private let link = "https://dev.azure.com/contoso/Storefront/_git/payments-api/pullrequest/4102"
    private let start = Date(timeIntervalSince1970: 1_792_317_600)

    private func request(_ arguments: [String], org: [String] = [], app: [String] = []) -> Result<WaitCLI.Request, WaitCLI.Ended> {
        WaitCLI.request(arguments, organizations: org, appOrganizations: app)
    }

    // MARK: Arguments

    @Test func takesALinkOrANumber() throws {
        #expect(try request(["--wait", link]).get() == WaitCLI.Request(key: PRKey(organization, 4102), minutes: 90))
        #expect(try request(["--wait", "4102", "--timeout", "15"], app: [organization]).get()
            == WaitCLI.Request(key: PRKey(organization, 4102), minutes: 15))
        // --org rather than the app's, and the number as the lists write it.
        #expect(try request(["--wait", "!4102", "--org", "fabrikam"], org: ["fabrikam"], app: [organization, "other"]).get().key
            == PRKey("fabrikam", 4102))
        // An organization's name is the same in any letter case.
        #expect(try request(["--wait", "4102"], app: [organization, organization.uppercased()]).get().key == PRKey(organization, 4102))
        #expect(try request(["--wait", link, "--timeout", "120"]).get().minutes == 120)
    }

    @Test func refusesWhatItCantWaitOn() {
        let refused: [(arguments: [String], app: [String])] = [
            (["--wait"], [organization]),
            (["--wait", "--timeout", "5"], [organization]),
            (["--wait", "4102"], [organization, "fabrikam"]),
            (["--wait", "4102"], []),
            (["--wait", "the big one"], [organization]),
            (["--wait", "-3"], [organization]),
            (["--wait", link, "--timeout"], []),
            (["--wait", link, "--timeout", "0"], []),
            (["--wait", link, "--timeout", "121"], []),
            (["--wait", link, "--timeout", "an hour"], []),
        ]
        for (arguments, app) in refused {
            guard case .failure(let ended) = request(arguments, app: app) else {
                Issue.record("Took \(arguments)")
                continue
            }
            #expect(ended.exit == .usage && ended.output.isEmpty)
            #expect(ended.error.hasSuffix("\n" + WaitCLI.usageLine))
        }
    }

    /// `--org` with a name: the options take the word after it for one, even another option, and leave out one without,
    /// so it would read the app's organization, or one called “--timeout”.
    @Test func refusesAnOrgWithoutAName() {
        let arguments: [[String]] = [
            ["--wait", "4102", "--org"],
            ["--wait", "4102", "--org", "--timeout", "5"],
            ["--wait", "4102", "--org", " "],
            ["--wait", link, "--timeout", "5", "--org"],
        ]
        for arguments in arguments {
            // As the options read them, as for any of its modes.
            let named = AzureDevOpsCommandLine.Options(CommandLineOptions(arguments: arguments, demo: false)).organizations
            guard case .failure(let ended) = request(arguments, org: named, app: [organization]) else {
                Issue.record("Took \(arguments)")
                continue
            }
            #expect(ended.exit == .usage && ended.error == "--org takes an organization's name.\n\(WaitCLI.usageLine)")
        }
    }

    /// Its exit codes, as `--help` says them, and its timeout's.
    @Test func saysWhatItsExitCodesMean() {
        #expect(WaitCLI.Exit.allCases.map(\.rawValue) == Array(0...7))
        let usage = AzureDevOpsCommandLine.usage.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(usage.contains("""
            Exits with 0 when the build passed, 1 when it can't read it, 2 on wrong usage, 3 at the timeout, 4 when a build \
            failed, 5 for comments, 6 for conflicts, 7 once it's completed or abandoned.
            """))
        #expect(usage.contains("from 1 to \(WaitCLI.mostMinutes) (\(WaitCLI.defaultMinutes) by default)"))
        #expect(AzureDevOpsCommandLine.flags.contains(WaitCLI.flag))
        #expect(WaitCLI.starting(WaitCLI.Request(key: PRKey(organization, 4099), minutes: 15))
            == "Waiting up to 15 minutes for !4099's next build, comments that wait on you, or merge conflicts…")
    }

    /// As `--mcp` answers: only while you let agents use BriefBar, and Azure DevOps is on in the app.
    @Test func waitsOnlyWhileAgentsAndAzureDevOpsAreOn() {
        #expect(WaitCLI.refusal(nil) == AgentAccess.refusal(.off))
        let defaults = MemoryDefaults()
        #expect(WaitCLI.refusal(defaults) == AgentAccess.refusal(.off))
        AgentAccess.turnOn(in: defaults)
        #expect(WaitCLI.refusal(defaults) == AgentAccess.refusal(source: "Azure DevOps"))
        var choices = SourceChoices.load(from: defaults)
        choices.turnOn(.azureDevOps, version: AzureDevOpsSource.descriptionVersion, at: Date())
        choices.save(to: defaults)
        #expect(WaitCLI.refusal(defaults) == nil)
        // Paused, as after an update that gives agents more, until you've looked.
        AgentAccess.turnOn(in: defaults, version: AgentAccess.version - 1)
        #expect(WaitCLI.refusal(defaults) != nil)
        #expect(WaitCLI.refusal(defaults) == AgentAccess.refusal(AgentAccess.state(in: defaults)))
    }

    /// The command `pull_request` gives agents: this copy of BriefBar, as a shell reads its path.
    @Test func writesTheCommandForAgents() throws {
        let pullRequest = try #require(URL(string: "https://dev.azure.com/contoso/Storefront/_git/shop-web/pullrequest/4088"))
        #expect(WaitCLI.command(executable: "/Applications/BriefBar.app/Contents/MacOS/BriefBar", link: pullRequest, demo: false)
            == "/Applications/BriefBar.app/Contents/MacOS/BriefBar --wait \(pullRequest.absoluteString) --timeout 90")
        #expect(WaitCLI.command(executable: "/Users/me/My Apps/BriefBar.app/Contents/MacOS/BriefBar", link: pullRequest, demo: true)
            == "'/Users/me/My Apps/BriefBar.app/Contents/MacOS/BriefBar' --demo --wait \(pullRequest.absoluteString) --timeout 90")
    }

    // MARK: Waiting

    /// Stand-ins for Azure DevOps and the clock: each read gives the next snapshot, and the last one again once they run out;
    /// sleeping moves the clock on.
    private final class Script: Sendable {
        private struct State {
            var reads: [PulseSnapshot]
            var count = 0
            var refusals: [String?]
            var now: Date
            var slept: [TimeInterval] = []
        }

        private let state: Mutex<State>

        init(_ reads: [PulseSnapshot], refusals: [String?] = [], now: Date) {
            state = Mutex(State(reads: reads, refusals: refusals, now: now))
        }

        var reads: Int { state.withLock { $0.count } }
        var slept: [TimeInterval] { state.withLock { $0.slept } }

        func read() -> PulseSnapshot {
            state.withLock { state in
                defer { state.count += 1 }
                return state.reads[min(state.count, state.reads.count - 1)]
            }
        }

        func refusal() -> String? {
            state.withLock { state in state.refusals.isEmpty ? nil : state.refusals.removeFirst() }
        }

        func now() -> Date { state.withLock { $0.now } }

        func sleep(_ seconds: TimeInterval) {
            state.withLock { state in
                state.now += seconds
                state.slept.append(seconds)
            }
        }
    }

    private func waiter(_ script: Script, _ number: Int, minutes: Int = 90, status: WaitCLI.Found = .status(.active)) -> WaitCLI.Waiter {
        WaitCLI.Waiter(
            request: WaitCLI.Request(key: PRKey(organization, number), minutes: minutes),
            read: { script.read() },
            status: { status },
            prompt: { action, record in "The prompt to \(action.agentName) !\(record.pullRequest.key.number)." },
            refusal: { script.refusal() },
            now: { script.now() },
            sleep: { script.sleep($0) }
        )
    }

    /// The demo's pull request, as a read at this minute of the wait has it, with it and its details read then.
    private func read(_ number: Int, at minute: Int, _ change: (inout PRRecord) -> Void = { _ in }) throws -> PulseSnapshot {
        var record = try #require(DemoData.records(now: start).first { $0.id.number == number })
        let at = start.addingTimeInterval(TimeInterval(minute) * 60)
        record.details?.fetchedAt = at
        change(&record)
        return PulseSnapshot(records: [record], hasLoaded: true, linkedReadAt: [record.id: at])
    }

    private func pageOf(_ number: Int, in repository: String) -> String {
        "https://dev.azure.com/contoso/Storefront/_git/\(repository)/pullrequest/\(number)"
    }

    /// !4099's infra CI runs as the wait begins, and fails at the third read.
    @Test func endsAsSoonAsABuildFails() async throws {
        let failed = try read(4099, at: 2) { record in
            record.details?.checks[0].state = .failed
            record.details?.checks[0].completedAt = start.addingTimeInterval(100)
        }
        let script = Script([try read(4099, at: 0), try read(4099, at: 1), failed], now: start)
        let ended = await waiter(script, 4099).run()
        #expect(ended.exit == .buildFailed && ended.error.isEmpty)
        #expect(ended.output == """
            !4099's build failed: “infra CI”.
            \(pageOf(4099, in: "infra"))

            The prompt to fix_build !4099.
            """)
        #expect(script.reads == 3 && script.slept == [60, 60])
    }

    @Test func passesOnceItsBuildsHave() async throws {
        let passed = try read(4099, at: 1) { record in
            record.details?.checks[0].state = .passed
            record.details?.checks[0].completedAt = start.addingTimeInterval(50)
        }
        let ended = await waiter(Script([try read(4099, at: 0), passed], now: start), 4099).run()
        #expect(ended.exit == .passed)
        #expect(ended.output == "!4099's build passed: “infra CI”.\n\(pageOf(4099, in: "infra"))")
    }

    /// Priya's comment on !4091, as the demo has it.
    @Test func endsOnCommentsThatWaitOnYou() async throws {
        let commented = DemoData.update(try read(4091, at: 1), at: start.addingTimeInterval(30))
        let ended = await waiter(Script([try read(4091, at: 0), commented], now: start), 4091).run()
        #expect(ended.exit == .comments)
        #expect(ended.output == """
            A comment thread on !4091 waits on you.
            \(pageOf(4091, in: "payments-api"))

            The prompt to fix_comments !4091.
            """)
    }

    /// Merge conflicts end it even when it had them as it began: no build runs until they're resolved.
    @Test func endsAtOnceOnConflicts() async throws {
        let script = Script([try read(4079, at: 0)], now: start)
        let ended = await waiter(script, 4079).run()
        #expect(ended.exit == .conflicts)
        #expect(ended.output == """
            !4079 has merge conflicts with main.
            \(pageOf(4079, in: "payments-api"))

            The prompt to resolve_conflicts !4079.
            """)
        #expect(script.reads == 1 && script.slept.isEmpty)
    }

    /// What happened in one read: each, and their prompts, a failed build first, whose exit code it is.
    @Test func saysEverythingThatHappenedAtOnce() async throws {
        let everything = DemoData.update(try read(4091, at: 1) { record in
            record.pullRequest.mergeStatus = "conflicts"
            record.details?.checks[0].state = .failed
            record.details?.checks[0].completedAt = start.addingTimeInterval(40)
        }, at: start.addingTimeInterval(30))
        let ended = await waiter(Script([try read(4091, at: 0), everything], now: start), 4091).run()
        #expect(ended.exit == .buildFailed)
        #expect(ended.output == """
            !4091's build failed: “payments-api CI”.
            !4091 has merge conflicts with main.
            A comment thread on !4091 waits on you.
            \(pageOf(4091, in: "payments-api"))

            The prompt to fix_build !4091.

            The prompt to resolve_conflicts !4091.

            The prompt to fix_comments !4091.
            """)
    }

    @Test func stopsAtItsTimeout() async throws {
        let script = Script([try read(4099, at: 0), try read(4099, at: 1), try read(4099, at: 2)], now: start)
        let ended = await waiter(script, 4099, minutes: 2).run()
        #expect(ended.exit == .timedOut)
        #expect(ended.output == "Stopped waiting for !4099 after 2 minutes: “infra CI” is still running.\n\(pageOf(4099, in: "infra"))")
        #expect(script.reads == 3 && script.slept == [60, 60])
        // With nothing under way.
        let quiet = await waiter(Script([try read(4091, at: 0), try read(4091, at: 1)], now: start), 4091, minutes: 1).run()
        #expect(quiet.exit == .timedOut)
        #expect(quiet.output.hasPrefix("Stopped waiting for !4091 after a minute: no build ran, nobody commented, and it has no merge conflicts.\n"))
    }

    /// Reads that fail, five in a row: its details stay as they were last read.
    @Test func stopsWhenItCantReadIt() async throws {
        let first = try read(4099, at: 0)
        var offline = first
        offline.problem = .offline
        let script = Script([first, offline], now: start)
        let ended = await waiter(script, 4099).run()
        #expect(ended.exit == .couldntRead && ended.output.isEmpty)
        #expect(ended.error == "Couldn't read !4099 5 times in a row. \(AzureDevOpsCommandLine.text(of: .offline))")
        #expect(script.reads == 6)

        let never = await waiter(Script([PulseSnapshot(hasLoaded: true)], now: start), 4099).run()
        #expect(never.exit == .couldntRead)
        #expect(never.error.hasPrefix("Couldn't read !4099 5 times in a row. Check that you're signed in to the Azure CLI (az login)"))
        // Its time ran out before it could.
        let late = await waiter(Script([PulseSnapshot(hasLoaded: true)], now: start), 4099, minutes: 1).run()
        #expect(late.exit == .couldntRead && late.error == "Couldn't read !4099 within a minute.")
    }

    /// A read that couldn't read the pull request itself, though its policies and threads could, isn't one: what it kept of
    /// the pull request, such as its conflicts, may be old. Here !4099's build passed in each, which ends nothing until a
    /// read has the pull request too; five in a row end the wait.
    @Test func aReadCountsOnlyOnceItReadThePullRequestToo() async throws {
        func passed(_ minute: Int, pullRequestReadAt: Date? = nil) throws -> PulseSnapshot {
            var snapshot = try read(4099, at: minute) { record in
                record.details?.checks[0].state = .passed
                record.details?.checks[0].completedAt = start.addingTimeInterval(TimeInterval(minute) * 60 - 10)
            }
            if let pullRequestReadAt { snapshot.linkedReadAt = [PRKey(organization, 4099): pullRequestReadAt] }
            return snapshot
        }
        let first = try read(4099, at: 0)
        let stale = try (1...5).map { try passed($0, pullRequestReadAt: start) }
        let script = Script([first] + stale, now: start)
        let ended = await waiter(script, 4099).run()
        #expect(ended.exit == .couldntRead && ended.output.isEmpty)
        #expect(ended.error.hasPrefix("Couldn't read !4099 5 times in a row. Check that you're signed in to the Azure CLI (az login)"))
        #expect(script.reads == 6)

        let then = Script([first, stale[0], stale[1], try passed(3)], now: start)
        #expect(await waiter(then, 4099).run().exit == .passed)
        #expect(then.reads == 4)
    }

    /// Policies it can't read leave the builds unknown, not none: such a read doesn't count, so a build that had passed
    /// before isn't news once they can be read; and five of them in a row end the wait.
    @Test func aReadCountsOnlyWithItsPolicies() async throws {
        func unknown(_ minute: Int) throws -> PulseSnapshot {
            try read(4091, at: minute) { record in
                record.details?.checks = []
                record.details?.checksKnown = false
            }
        }
        let script = Script(try (0..<5).map(unknown), now: start)
        let ended = await waiter(script, 4091).run()
        #expect(ended.exit == .couldntRead && script.reads == 5)
        #expect(ended.error == """
            Couldn't read !4091 5 times in a row. Its project doesn't let you read its policies, so BriefBar can't tell how its \
            builds stand.
            """)

        let readable = Script([try unknown(0), try unknown(1), try read(4091, at: 2), try read(4091, at: 3)], now: start)
        let timedOut = await waiter(readable, 4091, minutes: 3).run()
        #expect(timedOut.exit == .timedOut && readable.reads == 4)
        #expect(timedOut.output.hasPrefix("Stopped waiting for !4091 after 3 minutes: no build ran, nobody commented"))
    }

    /// One build passed, but another that blocks it expired, and nothing queues it again: it hasn't passed, so the wait goes
    /// on, and its timeout says which.
    @Test func passesOnlyOnceEveryBuildThatBlocksItHas() async throws {
        let tests = Check(name: "infra tests", kind: .build, state: .running, buildId: 77, definitionId: 41)
        func later(_ minute: Int) throws -> PulseSnapshot {
            try read(4099, at: minute) { record in
                record.details?.checks[0].state = .passed
                record.details?.checks[0].completedAt = start.addingTimeInterval(50)
                var expired = tests
                expired.state = .expired
                record.details?.checks.append(expired)
            }
        }
        let baseline = try read(4099, at: 0) { $0.details?.checks.append(tests) }
        let script = Script([baseline, try later(1), try later(2)], now: start)
        let ended = await waiter(script, 4099, minutes: 2).run()
        #expect(ended.exit == .timedOut)
        #expect(ended.output == """
            Stopped waiting for !4099 after 2 minutes: “infra tests” hasn't passed, and isn't running.
            \(pageOf(4099, in: "infra"))
            """)
    }

    @Test func endsOnceItsClosed() async throws {
        let closed = PulseSnapshot(hasLoaded: true, closedLinks: [PRKey(organization, 4099)])
        let completed = await waiter(Script([try read(4099, at: 0), closed], now: start), 4099, status: .status(.completed)).run()
        #expect(completed.exit == .closed && completed.output == "!4099 was completed.")
        let abandoned = await waiter(Script([closed], now: start), 4099, status: .status(.abandoned)).run()
        #expect(abandoned.exit == .closed && abandoned.output == "!4099 was abandoned.")
        // Gone, or not yours to read anymore.
        let gone = await waiter(Script([closed], now: start), 4099, status: .unreadable("Azure DevOps says it doesn't exist.")).run()
        #expect(gone.exit == .couldntRead && gone.error == "BriefBar can't read !4099: Azure DevOps says it doesn't exist.")
        let unreadable = await waiter(Script([closed], now: start), 4099).run()
        #expect(unreadable.exit == .couldntRead && unreadable.error == "BriefBar can't read !4099 now: you may no longer read it.")
    }

    /// Someone else's, open or closed as it began: one the engine found closed is read on its own, and it's yours once you
    /// created it, as the engine tells yours, whatever the letter case of your ID.
    @Test func waitsOnlyOnYourOwn() async throws {
        let ended = await waiter(Script([try read(4097, at: 0)], now: start), 4097).run()
        #expect(ended.exit == .usage && ended.error == "!4097 isn't yours: --wait waits only on your own pull requests.")
        let closed = PulseSnapshot(hasLoaded: true, closedLinks: [PRKey(organization, 4097)])
        #expect(await waiter(Script([closed], now: start), 4097, status: .notYours).run() == ended)

        let records = DemoData.records(now: start)
        let theirs = try #require(records.first { $0.id.number == 4097 })
        var completed = theirs.pullRequest
        completed.status = .completed
        #expect(WaitCLI.found(completed, me: theirs.me) == .notYours)
        let yours = try #require(records.first { $0.id.number == 4099 })
        var abandoned = yours.pullRequest
        abandoned.status = .abandoned
        #expect(WaitCLI.found(abandoned, me: yours.me.uppercased()) == .status(.abandoned))
    }

    /// Agents turned off, or Azure DevOps, meanwhile: before the next read.
    @Test func stopsOnceAgentsMayNot() async throws {
        let script = Script([try read(4099, at: 0), try read(4099, at: 1)], refusals: [nil, "Agents are off."], now: start)
        let ended = await waiter(script, 4099).run()
        #expect(ended.exit == .couldntRead && ended.error == "Agents are off.")
        #expect(script.reads == 1)
    }

    /// The demo waits a second for its one change, Priya's comment on !4091, and nothing more.
    @Test func theDemoWaitsForItsOneChange() async throws {
        func demo(_ number: Int) async -> WaitCLI.Ended {
            await WaitCLI.demo(WaitCLI.Request(key: PRKey(organization, number), minutes: 1))
        }
        let comments = await demo(4091)
        #expect(comments.exit == .comments)
        #expect(comments.output.hasPrefix("A comment thread on !4091 waits on you.\n\(pageOf(4091, in: "payments-api"))\n\n"))
        #expect(comments.output.contains("Address these review comments:"))
        #expect(comments.output.contains("Could you add a test for a negative total before you merge?"))
        #expect(await demo(4079).exit == .conflicts)
        #expect(await demo(4097).exit == .usage)
        #expect(await demo(1).exit == .couldntRead)
        let nothing = await demo(4099)
        #expect(nothing.exit == .timedOut && nothing.output == "That's all the demo does: nothing more happens to !4099.")
    }
}
