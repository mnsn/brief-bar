import BriefBarCore
import BriefBarUI
import Foundation
import Synchronization
import Testing

/// How often the tool told the app what sessions set changed.
private final class Announcements: Sendable {
    private let count = Mutex(0)

    func add() {
        count.withLock { $0 += 1 }
    }

    var total: Int { count.withLock { $0 } }
}

/// `pull_request_stage`: a Copilot session tells BriefBar the stage of the pull requests it works on, as its own, kept
/// under its key, and is told what the user set that it replaces.
@Suite struct PullRequestStageMCPTests {
    private static let session = "6f9619ff-8b86-d011-b42d-00c04fc964ff"
    private static let account = "Robin@contoso.com"
    private static let now = Date(timeIntervalSince1970: 1_791_979_200)

    private static func link(_ number: Int) -> String {
        "https://dev.azure.com/contoso/shop/_git/shop-web/pullrequest/\(number)"
    }

    private static func ref(_ number: Int) -> ItemRef {
        .pullRequest(organization: "contoso", number: number)
    }

    /// The app's settings, with Pull Request Order on.
    private static func settings(on: Bool = true) -> MemoryDefaults {
        let defaults = MemoryDefaults()
        if on { defaults.set(true, forKey: PullRequestOrderSetting.defaultsKey) }
        return defaults
    }

    /// What Azure DevOps reads of its pull requests now: those it lists, with their facts.
    private static let listed: [ItemRef: StageFacts] = [
        ref(4093): StageFacts(role: .author, votes: "", commit: "a1b2c3d"),
        ref(4094): StageFacts(role: .author, votes: "10", commit: "e4f5a6b"),
        ref(4095): StageFacts(role: .author, state: .merged),
        ref(4096): StageFacts(role: .author, isListed: false),
    ]

    private static func read(_ refs: [ItemRef]) -> MCPStages.Read {
        MCPStages.Read(account: account, facts: listed.filter { refs.contains($0.key) })
    }

    /// - Parameter refusal: why what's read can't be kept, as agents or Azure DevOps being off in the app say.
    private static func tools(
        _ defaults: MemoryDefaults, demo: Bool = false, session: String? = session,
        copilotOn: @escaping @Sendable () -> Bool = { true },
        read: @escaping @Sendable ([ItemRef]) async throws -> MCPStages.Read = { refs in read(refs) },
        refusal: @escaping @Sendable () -> String? = { nil },
        announcements: Announcements = Announcements(), now: @escaping @Sendable () -> Date = { now }
    ) -> [String: MCPTool] {
        let tools = PullRequestOrderMCP.tools(
            defaults: defaults, demo: demo, sourcesOn: { [.pullRequest] }, session: session,
            stages: MCPStages(read: read).guarded(by: refusal), copilotOn: copilotOn, announce: { announcements.add() },
            now: now
        )
        return Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func arguments(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    private static func set(_ tools: [String: MCPTool], _ json: String) async throws -> String {
        try await #require(tools["pull_request_stage"]).run(try arguments(json))
    }

    private static func failure(_ run: () async throws -> String) async -> String? {
        do {
            _ = try await run()
            return nil
        } catch {
            return String(describing: error)
        }
    }

    private static func kept(_ defaults: MemoryDefaults) -> SessionStage? {
        SessionStages.load(ItemRef.session(session)!, from: defaults)
    }

    @Test func itsListedWithPullRequestOrdersToolsOnlyWithAzureDevOpsStages() {
        #expect(Self.tools(Self.settings(on: false)).isEmpty)
        let tools = PullRequestOrderMCP.tools(
            defaults: Self.settings(), demo: false, sourcesOn: { [] }, session: nil,
            stages: MCPStages { _ in MCPStages.Read(account: nil, facts: [:]) }
        )
        #expect(tools.map(\.name) == ["order_pull_requests", "pull_request_order", "forget_pull_request_order", "pull_request_stage"])
        #expect(tools.last?.readOnly == false)
        let none = PullRequestOrderMCP.tools(defaults: Self.settings(), demo: false, sourcesOn: { [] }, session: nil)
        #expect(!none.map(\.name).contains("pull_request_stage"))
    }

    /// The stage it sets is this session's, kept under its key with what would end it as Azure DevOps reads the pull
    /// request now, and the app's told.
    @Test func aSessionSetsAStageAsItsOwn() async throws {
        let defaults = Self.settings()
        let announcements = Announcements()
        let tools = Self.tools(defaults, announcements: announcements)

        let answer = try await Self.set(tools, #"{"pull_requests": ["\#(Self.link(4093))"], "stage": "user_review"}"#)
        #expect(answer == """
            BriefBar shows !4093 in contoso in Your review now, set by this session; the user sees who set it, and can \
            change it.
            """)
        let mark = try #require(Self.kept(defaults)?.marks[Self.ref(4093)])
        #expect(mark == StageMark(stage: .yourReview, at: Self.now, by: ItemRef.session(Self.session)))
        #expect(announcements.total == 1)

        // By numbers with organization; In progress keeps the commit, Teammate's review the votes.
        _ = try await Self.set(tools, #"{"pull_requests": [4093, "!4094"], "organization": "contoso", "stage": "in_progress"}"#)
        #expect(Self.kept(defaults)?.marks[Self.ref(4093)]?.commit == "a1b2c3d")
        _ = try await Self.set(tools, #"{"pull_requests": ["4094"], "organization": "contoso", "stage": "teammate_review"}"#)
        #expect(Self.kept(defaults)?.marks[Self.ref(4094)]?.votes == "10")
        #expect(Self.kept(defaults)?.marks[Self.ref(4094)]?.stage == .teammateReview)
        #expect(announcements.total == 3)
    }

    /// The answer says what the user set that it replaces, while it stands: they can put theirs back.
    @Test func itSaysWhatTheUserSetThatItReplaces() async throws {
        let defaults = Self.settings()
        var marks = StageMarks()
        _ = marks.set(StageMark(stage: .teammateReview, at: Self.now - 180, votes: ""), of: Self.ref(4093), for: "robin@contoso.com", at: Self.now)
        _ = marks.set(StageMark(stage: .teammateReview, at: Self.now - 600, votes: ""), of: Self.ref(4094), for: "robin@contoso.com", at: Self.now)
        marks.save(to: defaults)
        let tools = Self.tools(defaults)

        let one = try await Self.set(tools, #"{"pull_requests": ["\#(Self.link(4093))"], "stage": "in_progress"}"#)
        #expect(one.hasSuffix("""
            change it.
            The user had set Teammate's review 3m ago; yours replaces it, and they can put theirs back.
            """))

        // What the user set on !4094 ended as its votes changed: nothing to put back. The same stage replaces nothing.
        let two = try await Self.set(tools, #"{"pull_requests": [4093, 4094], "organization": "contoso", "stage": "teammate_review"}"#)
        #expect(two == """
            BriefBar shows !4093 and !4094 in contoso in Teammate's review now, set by this session; the user sees who set \
            it, and can change it.
            """)
        let three = try await Self.set(tools, #"{"pull_requests": [4093, 4094], "organization": "contoso", "stage": "user_review"}"#)
        #expect(three.hasSuffix("""
            change it.
            The user had set Teammate's review on !4093 in contoso 3m ago; yours replaces it, and they can put theirs back.
            """))
    }

    /// Clear takes away only what this session set.
    @Test func clearTakesAwayOnlyWhatThisSessionSet() async throws {
        let defaults = Self.settings()
        let announcements = Announcements()
        let tools = Self.tools(defaults, announcements: announcements)
        _ = try await Self.set(tools, #"{"pull_requests": ["\#(Self.link(4093))"], "stage": "user_review"}"#)
        let other = try #require(ItemRef.session("2b8d4f60-9a1c-4e3b-b7d5-6f8e9a0b1c2d"))
        SessionStages.change(other, in: defaults, now: Self.now) { $0.set(StageMark(stage: .inProgress, at: Self.now), of: Self.ref(4093)) }

        let cleared = try await Self.set(tools, #"{"pull_requests": [4093, 4094], "organization": "contoso", "stage": "clear"}"#)
        #expect(cleared == """
            BriefBar no longer shows the stage this session set on !4093 in contoso: it works it out again, or shows what \
            the user set.
            This session set no stage on !4094 in contoso.
            """)
        #expect(Self.kept(defaults) == nil)
        #expect(SessionStages.load(other, from: defaults)?.marks[Self.ref(4093)] != nil)
        #expect(announcements.total == 2)

        _ = try await Self.set(tools, #"{"pull_requests": ["4093"], "organization": "contoso", "stage": "clear"}"#)
        #expect(announcements.total == 2)
    }

    /// One BriefBar doesn't list, or that merged, is left as it is, with a line that says why; with none set, it's refused.
    @Test func itSaysWhichItDidntSet() async throws {
        let defaults = Self.settings()
        let tools = Self.tools(defaults)
        let answer = try await Self.set(
            tools, #"{"pull_requests": [4093, 4095, 4096, 4097], "organization": "contoso", "stage": "user_review"}"#
        )
        #expect(answer == """
            BriefBar shows !4093 in contoso in Your review now, set by this session; the user sees who set it, and can \
            change it.
            Not !4095 in contoso: it merged.
            Not !4096 in contoso: BriefBar doesn't list it now.
            Not !4097 in contoso: BriefBar doesn't list it now.
            """)
        #expect(Self.kept(defaults)?.marks.keys.sorted() == [Self.ref(4093)])

        let none = await Self.failure {
            try await Self.set(tools, #"{"pull_requests": [4095], "organization": "contoso", "stage": "user_review"}"#)
        }
        #expect(none == "Not !4095 in contoso: it merged.")
    }

    @Test func itsRefusedSayingWhy() async throws {
        let defaults = Self.settings()
        let tools = Self.tools(defaults)
        func refusal(_ json: String, tools: [String: MCPTool] = tools) async -> String? {
            await Self.failure { try await Self.set(tools, json) }
        }
        #expect(await refusal(#"{"pull_requests": ["https://github.com/octo/app/pull/12"], "stage": "user_review"}"#) ==
            "Stages are for Azure DevOps' pull requests only, for now: leave Pull Request octo/app#12 out.")
        #expect(await refusal(#"{"pull_requests": ["4093"], "stage": "user_review"}"#) ==
            "Send organization with numbers, such as 5101: BriefBar can't tell organizations apart from a number.")
        #expect(await refusal(#"{"pull_requests": ["nonsense"], "stage": "user_review"}"#)?.hasPrefix("BriefBar can't read “nonsense”") == true)
        #expect(await refusal(#"{"pull_requests": [], "stage": "user_review"}"#) ==
            "Name the pull requests in pull_requests: their links, or their numbers with organization.")
        let many = (4000..<4021).map(String.init).joined(separator: ", ")
        #expect(await refusal(#"{"pull_requests": [\#(many)], "organization": "contoso", "stage": "user_review"}"#) ==
            "Name at most 20 pull requests at once.")
        #expect(await refusal(#"{"pull_requests": [4093], "organization": "contoso"}"#) ==
            "Give stage: in_progress, user_review, teammate_review or clear.")
        #expect(await refusal(#"{"pull_requests": [4093], "organization": "contoso", "stage": "can_merge"}"#) == """
            BriefBar sets Can merge, Waits and Merged itself, from what Azure DevOps shows and the order: give stage as \
            in_progress, user_review, teammate_review or clear.
            """)
        #expect(await refusal(#"{"pull_requests": [4093], "organization": "contoso", "stage": "done"}"#) ==
            "There's no stage “done”: give stage as in_progress, user_review, teammate_review or clear.")
        // Only its own session's.
        let other = #"{"pull_requests": [4093], "organization": "contoso", "stage": "user_review", "session": "2b8d4f60-9a1c-4e3b-b7d5-6f8e9a0b1c2d"}"#
        #expect(await refusal(other)?.hasPrefix("A session tells BriefBar only its own work") == true)
        let unknown = Self.tools(defaults, session: nil)
        #expect(await refusal(#"{"pull_requests": [4093], "organization": "contoso", "stage": "user_review"}"#, tools: unknown) ==
            "BriefBar can't tell which Copilot session you are: send session, your session's ID.")
        // What the source says when it can't read, such as being off.
        let off = Self.tools(defaults, read: { _ in throw MCPToolError(AgentAccess.refusal(source: "Azure DevOps")) })
        #expect(await refusal(#"{"pull_requests": [4093], "organization": "contoso", "stage": "user_review"}"#, tools: off) ==
            AgentAccess.refusal(source: "Azure DevOps"))
        let noCopilot = Self.tools(defaults, copilotOn: { false })
        #expect(await refusal(#"{"pull_requests": [4093], "organization": "contoso", "stage": "user_review"}"#, tools: noCopilot) ==
            AgentAccess.refusal(source: "GitHub Copilot"))
        #expect(Self.kept(defaults) == nil)

        // Pull Request Order turned off since `--mcp` started.
        defaults.set(false, forKey: PullRequestOrderSetting.defaultsKey)
        #expect(await refusal(#"{"pull_requests": [4093], "organization": "contoso", "stage": "user_review"}"#)?
            .hasPrefix("Pull Request Order is off in BriefBar") == true)
    }

    /// It's set as Azure DevOps read it, at the time it did: what the app read before, or while it read, counts nothing
    /// against it (`StageFacts.readAt`).
    @Test func itsSetAtTheTimeItsRead() async throws {
        let defaults = Self.settings()
        let clock = Mutex(Self.now)
        let tools = Self.tools(defaults, read: { refs in
            clock.withLock { $0 += 90 }
            return Self.read(refs)
        }, now: { clock.withLock { $0 } })
        _ = try await Self.set(tools, #"{"pull_requests": [4093], "organization": "contoso", "stage": "in_progress"}"#)
        #expect(Self.kept(defaults)?.marks[Self.ref(4093)]?.at == Self.now + 90)
    }

    /// Whether it may is asked again once Azure DevOps has read the pull requests, as that takes a while: what's turned off
    /// meanwhile keeps it from keeping anything, saying so.
    @Test func whatsTurnedOffWhileItReadsKeepsItFromKeepingAnything() async throws {
        let json = #"{"pull_requests": [4093], "organization": "contoso", "stage": "user_review"}"#

        let orderOff = Self.settings()
        let order = Self.tools(orderOff, read: { refs in
            orderOff.set(false, forKey: PullRequestOrderSetting.defaultsKey)
            return Self.read(refs)
        })
        #expect(await Self.failure { try await Self.set(order, json) }?.hasPrefix("Pull Request Order is off in BriefBar") == true)
        #expect(Self.kept(orderOff) == nil)

        let copilotOff = Self.settings()
        let copilot = Mutex(true)
        let noCopilot = Self.tools(copilotOff, copilotOn: { copilot.withLock { $0 } }, read: { refs in
            copilot.withLock { $0 = false }
            return Self.read(refs)
        })
        #expect(await Self.failure { try await Self.set(noCopilot, json) } == AgentAccess.refusal(source: "GitHub Copilot"))
        #expect(Self.kept(copilotOff) == nil)

        // Agents, or Azure DevOps, as what reads the pull requests says.
        let agentsOff = Self.settings()
        let refusal = Mutex<String?>(nil)
        let noAgents = Self.tools(agentsOff, read: { refs in
            refusal.withLock { $0 = "Agents are off in BriefBar." }
            return Self.read(refs)
        }, refusal: { refusal.withLock { $0 } })
        #expect(await Self.failure { try await Self.set(noAgents, json) } == "Agents are off in BriefBar.")
        #expect(Self.kept(agentsOff) == nil)
        let clear = #"{"pull_requests": [4093], "organization": "contoso", "stage": "clear"}"#
        #expect(await Self.failure { try await Self.set(noAgents, clear) } == "Agents are off in BriefBar.")
    }

    @Test func theDemoKeepsItInMemory() async throws {
        let defaults = MemoryDefaults()
        let announcements = Announcements()
        let tools = Self.tools(defaults, demo: true, announcements: announcements)
        let answer = try await Self.set(tools, #"{"pull_requests": ["\#(Self.link(4093))"], "stage": "user_review"}"#)
        #expect(answer.hasSuffix("change it. (The demo keeps it in memory.)"))
        #expect(Self.kept(defaults)?.marks[Self.ref(4093)]?.stage == .yourReview)
        #expect(announcements.total == 0)
    }
}
