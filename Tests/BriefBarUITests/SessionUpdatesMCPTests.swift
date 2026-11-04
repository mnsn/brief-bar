import BriefBarCore
import BriefBarUI
import Foundation
import Synchronization
import Testing

/// How often the tools told the app what sessions told changed.
private final class Told: Sendable {
    private let count = Mutex(0)

    func add() {
        count.withLock { $0 += 1 }
    }

    var total: Int { count.withLock { $0 } }
}

@Suite struct SessionUpdatesMCPTests {
    private static let session = "6f9619ff-8b86-d011-b42d-00c04fc964ff"
    private static let sessionRef = ItemRef.session(session)!
    private static let other = "a3d9c5e1-7b2f-4e84-9c16-5f8e2d0b7a11"
    private static let now = Date(timeIntervalSince1970: 1_791_979_200)
    private static let allOn: Set<SourceID> = [.azureDevOps, .copilot, .github]
    private static let task = ItemRef.workItem(organization: "contoso", id: 5124)
    private static let pullRequest = ItemRef.pullRequest(organization: "contoso", number: 4102)

    /// The app's settings, with Updates from Copilot Sessions on.
    private static func settings(on: Bool = true) -> MemoryDefaults {
        let defaults = MemoryDefaults()
        if on { defaults.set(true, forKey: SessionUpdatesSetting.defaultsKey) }
        return defaults
    }

    private static func tools(
        _ defaults: MemoryDefaults, demo: Bool = false, sourcesOn: Set<SourceID> = allOn, session: String? = session,
        told: Told = Told()
    ) -> [String: MCPTool] {
        let tools = SessionUpdatesMCP.tools(
            defaults: defaults, demo: demo, sourcesOn: { sourcesOn }, session: session, id: "this", announce: { told.add() },
            now: { now }
        )
        return Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func call(_ tool: MCPTool?, _ json: String) async throws -> String {
        let tool = try #require(tool)
        return try await tool.run(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
    }

    private static func failure(_ tool: MCPTool?, _ json: String) async -> String? {
        do {
            _ = try await call(tool, json)
            return nil
        } catch {
            return String(describing: error)
        }
    }

    // MARK: When they're there

    @Test func listedOnlyWithTheSettingOnOrInTheDemo() {
        #expect(Self.tools(Self.settings(on: false)).isEmpty)
        #expect(Self.tools(Self.settings()).keys.sorted() == ["changed_in_azure_devops", "working_on"])
        #expect(Self.tools(Self.settings(on: false), demo: true).count == 2)
        #expect(Self.tools(Self.settings()).values.allSatisfy { !$0.readOnly })
    }

    @Test func refusedOnceTurnedOff() async {
        let defaults = Self.settings()
        let tools = Self.tools(defaults)
        defaults.set(false, forKey: SessionUpdatesSetting.defaultsKey)
        let refusal = await Self.failure(tools["working_on"], #"{"work_items": ["5124"], "organization": "contoso"}"#)
        #expect(refusal?.contains("Updates from Copilot Sessions is off") == true)
        #expect(SessionReports.load(from: defaults, now: Self.now).isEmpty)
    }

    // MARK: working_on

    @Test func keepsWhatTheSessionWorksOn() async throws {
        let defaults = Self.settings()
        let told = Told()
        let tools = Self.tools(defaults, told: told)
        let answer = try await Self.call(tools["working_on"], """
            {"work_items": ["5124", "https://dev.azure.com/contoso/Shop/_workitems/edit/5125"],
             "pull_requests": ["!4102", "https://github.com/octo/app/pull/12"], "organization": "contoso"}
            """)
        #expect(answer.hasPrefix(
            "BriefBar shows this session on Work Items 5124 and 5125 and Pull Requests !4102 and octo/app#12 now."
        ))
        #expect(told.total == 1)
        let report = try #require(SessionReports.load(Self.sessionRef, from: defaults))
        #expect(report.workingOn == [
            Self.task, .workItem(organization: "contoso", id: 5125), Self.pullRequest,
            .gitHubPullRequest(repository: "octo/app", number: 12),
        ])

        let stopped = try await Self.call(tools["working_on"], "{}")
        #expect(stopped == "BriefBar no longer shows this session on anything.")
        #expect(SessionReports.load(Self.sessionRef, from: defaults) == nil)
    }

    @Test func tellsOnlyItsOwnSessionsWork() async throws {
        let tools = Self.tools(Self.settings())
        let theirs = await Self.failure(tools["working_on"], #"{"work_items": ["5124"], "organization": "contoso", "session": "\#(Self.other)"}"#)
        #expect(theirs?.contains("A session tells BriefBar only its own work") == true)
        _ = try await Self.call(tools["working_on"], #"{"work_items": ["5124"], "organization": "contoso", "session": "\#(Self.session)"}"#)

        // Without the Copilot CLI's word, `session` says which.
        let defaults = Self.settings()
        let unknown = Self.tools(defaults, session: nil)
        let noSession = await Self.failure(unknown["working_on"], #"{"work_items": ["5124"], "organization": "contoso"}"#)
        #expect(noSession?.contains("can't tell which Copilot session you are") == true)
        _ = try await Self.call(unknown["working_on"], #"{"work_items": ["5124"], "organization": "contoso", "session": "\#(Self.other)"}"#)
        #expect(SessionReports.load(ItemRef.session(Self.other)!, from: defaults)?.workingOn == [Self.task])
    }

    @Test func saysWhatItCantShowOrRead() async throws {
        let defaults = Self.settings()
        let noGitHub = Self.tools(defaults, sourcesOn: [.azureDevOps, .copilot])
        let answer = try await Self.call(noGitHub["working_on"], #"{"pull_requests": ["https://github.com/octo/app/pull/12", "!4102"], "organization": "contoso"}"#)
        #expect(answer.contains("Not Pull Request octo/app#12: GitHub is off in BriefBar."))
        #expect(SessionReports.load(Self.sessionRef, from: defaults)?.workingOn == [Self.pullRequest])

        let noCopilot = Self.tools(defaults, sourcesOn: [.azureDevOps])
        #expect(await Self.failure(noCopilot["working_on"], "{}")?.contains("GitHub Copilot is off in BriefBar") == true)

        let tools = Self.tools(defaults)
        #expect(await Self.failure(tools["working_on"], #"{"work_items": ["5124"]}"#)?.contains("Send organization") == true)
        #expect(await Self.failure(tools["working_on"], #"{"work_items": ["soon"]}"#)?.contains("can't read “soon”") == true)
        let many = (1...21).map { "\"\($0)\"" }.joined(separator: ", ")
        #expect(await Self.failure(tools["working_on"], #"{"work_items": [\#(many)], "organization": "contoso"}"#)?.contains("at most 20") == true)
    }

    // MARK: changed_in_azure_devops

    @Test func asksTheAppToReadAgainAndKeepsWhatItOpened() async throws {
        let defaults = Self.settings()
        let told = Told()
        let tools = Self.tools(defaults, told: told)
        let answer = try await Self.call(tools["changed_in_azure_devops"], """
            {"opened": ["https://dev.azure.com/contoso/Shop/_apis/git/repositories/8c1f/pullRequests/4102"],
             "work_items": ["5124", "5101"], "organization": "contoso"}
            """)
        #expect(answer == """
            BriefBar reads Work Items 5124 and 5101 and Pull Request !4102 again shortly, if it's running, rather than at \
            its next refresh.
            It shows Pull Request !4102 as opened by this session.
            """)
        #expect(told.total == 2)
        let reread = RereadRequests.take(after: .distantPast, from: defaults, now: Self.now).map(\.ref)
        #expect(Set(reread) == [Self.pullRequest, Self.task, .workItem(organization: "contoso", id: 5101)])
        #expect(defaults.object(forKey: RereadRequests.keyPrefix + "this") != nil)
        #expect(SessionReports.load(Self.sessionRef, from: defaults)?.opened == [Self.pullRequest: Self.now])
    }

    @Test func readsAgainForAnyAgentButKeepsWhoOpenedOnlyForASession() async throws {
        let defaults = Self.settings()
        let unknown = Self.tools(defaults, session: nil)
        let answer = try await Self.call(unknown["changed_in_azure_devops"], #"{"opened": ["4102"], "organization": "contoso"}"#)
        #expect(answer.contains("It can't tell which session opened Pull Request !4102"))
        #expect(RereadRequests.take(after: .distantPast, from: defaults, now: Self.now).map(\.ref) == [Self.pullRequest])
        #expect(SessionReports.load(from: defaults, now: Self.now).isEmpty)

        let noCopilot = Self.tools(defaults, sourcesOn: [.azureDevOps])
        let withoutCopilot = try await Self.call(noCopilot["changed_in_azure_devops"], #"{"opened": ["4102"], "organization": "contoso"}"#)
        #expect(withoutCopilot.contains("GitHub Copilot is off in BriefBar"))
        #expect(SessionReports.load(from: defaults, now: Self.now).isEmpty)

        let noAzureDevOps = Self.tools(defaults, sourcesOn: [.copilot])
        #expect(await Self.failure(noAzureDevOps["changed_in_azure_devops"], #"{"work_items": ["5124"], "organization": "contoso"}"#)?
            .contains("Azure DevOps is off in BriefBar") == true)
        let tools = Self.tools(defaults)
        #expect(await Self.failure(tools["changed_in_azure_devops"], "{}")?.contains("Name what you changed") == true)
        #expect(await Self.failure(tools["changed_in_azure_devops"], #"{"pull_requests": ["https://github.com/octo/app/pull/12"]}"#)?
            .contains("reads only Azure DevOps again") == true)
    }

    @Test func theDemoKeepsItInMemoryAndTellsNoApp() async throws {
        let defaults = Self.settings(on: false)
        let told = Told()
        let tools = Self.tools(defaults, demo: true, told: told)
        let answer = try await Self.call(tools["working_on"], #"{"work_items": ["5124"], "organization": "contoso"}"#)
        #expect(answer.contains("(The demo keeps it in memory.)"))
        _ = try await Self.call(tools["changed_in_azure_devops"], #"{"work_items": ["5124"], "organization": "contoso"}"#)
        #expect(told.total == 0)
    }
}
