import BriefBarCore
import BriefBarUI
import Foundation
import Synchronization
import Testing

/// How often the tools told the app its orders changed.
private final class Announcements: Sendable {
    private let count = Mutex(0)

    func add() {
        count.withLock { $0 += 1 }
    }

    var total: Int { count.withLock { $0 } }
}

@Suite struct PullRequestOrderMCPTests {
    private static let session = "6f9619ff-8b86-d011-b42d-00c04fc964ff"
    /// Midday in UTC, the same day in every time zone but the farthest.
    private static let now = Date(timeIntervalSince1970: 1_791_979_200)

    private static func link(_ number: Int) -> String {
        "https://dev.azure.com/contoso/shop/_git/shop-web/pullrequest/\(number)"
    }

    /// The app's settings, with Pull Request Order on.
    private static func settings(on: Bool = true) -> MemoryDefaults {
        let defaults = MemoryDefaults()
        if on { defaults.set(true, forKey: PullRequestOrderSetting.defaultsKey) }
        return defaults
    }

    private static func tools(
        _ defaults: MemoryDefaults, demo: Bool = false, sourcesOn: Set<ItemRef.Kind> = [.pullRequest, .gitHubPullRequest],
        session: String? = session, announcements: Announcements = Announcements()
    ) -> [String: MCPTool] {
        let tools = PullRequestOrderMCP.tools(
            defaults: defaults, demo: demo, sourcesOn: { sourcesOn }, session: session, announce: { announcements.add() },
            now: { now }
        )
        return Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func arguments(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    /// As the user put it: x1 before x2, x2 before x3, x4 any time, x5 after x2 and before x6.
    private static let userExample = """
        {"pull_requests": [
          {"link": "\(link(4101))"},
          {"link": "\(link(4102))", "after": ["4101"]},
          {"link": "\(link(4103))", "after": "!4102",
           "review": {"when": "after", "after": [4102], "reason": "builds_on_changes"}},
          {"link": "\(link(4104))", "review": "now"},
          {"link": "\(link(4105))", "after": [4102]},
          {"link": "\(link(4106))", "after": ["\(link(4105))"]}
        ]}
        """

    private static func failure(_ run: () async throws -> String) async -> String? {
        do {
            _ = try await run()
            return nil
        } catch {
            return String(describing: error)
        }
    }

    @Test func agentsGetNoToolUntilPullRequestOrderIsOn() {
        #expect(Self.tools(Self.settings(on: false)).isEmpty)

        let tools = PullRequestOrderMCP.tools(defaults: Self.settings(), demo: false, sourcesOn: { [] }, session: nil)
        #expect(tools.map(\.name) == ["order_pull_requests", "pull_request_order", "forget_pull_request_order"])
        #expect(tools.map(\.readOnly) == [false, true, false])
    }

    @Test func aSessionTellsAnOrderReadsItBackAndForgetsIt() async throws {
        let defaults = Self.settings()
        let announcements = Announcements()
        let tools = Self.tools(defaults, announcements: announcements)
        let order = try #require(tools["order_pull_requests"])

        let told = try await order.run(try Self.arguments(Self.userExample))

        let plan = try #require(DeclaredOrders.load(from: defaults).plans.first)
        let id = plan.id.uuidString.lowercased()
        #expect(plan.declaredBy == ItemRef.session(Self.session))
        #expect(announcements.total == 1)
        #expect(told == """
            BriefBar keeps this order now, as order \(id) at revision 1. Send it again, whole, with its ID and revision \
            whenever it changes.

            - !4101 in contoso: merges before !4102.
            - !4102 in contoso: merges after !4101.
            - !4103 in contoso: merges after !4102. Review after !4102: builds on its changes.
            - !4105 in contoso: merges after !4102.
            - !4106 in contoso: merges after !4105.
            - !4104 in contoso: any time. Can be reviewed now.
            """)

        // Told again, without its ID: the same one.
        let again = try await order.run(try Self.arguments(Self.userExample))
        #expect(again.hasPrefix("BriefBar keeps this order already, as order \(id) at revision 1."))
        #expect(DeclaredOrders.load(from: defaults).plans.count == 1)
        #expect(announcements.total == 1)

        let read = try await #require(tools["pull_request_order"]).run(.object([:]))
        #expect(read.hasPrefix("""
            ## Order \(id) at revision 1

            Told by your session, \(Self.session), last on 2026-10-14.

            - !4101 in contoso: merges before !4102.
            """))

        let replaced = try await order.run(try Self.arguments("""
            {"order": "\(id)", "revision": 1, "pull_requests": ["\(Self.link(4101))", {"link": "\(Self.link(4102))", "after": [4101]}]}
            """))
        #expect(replaced.hasPrefix("BriefBar replaced order \(id), which is at revision 2 now."))
        let stale = await Self.failure {
            try await order.run(try Self.arguments(#"{"order": "\#(id)", "revision": 1, "pull_requests": ["\#(Self.link(4101))"]}"#))
        }
        #expect(stale == "The order changed since revision 1, and is at revision 2 now: read it again, then send it again.")

        let forget = try #require(tools["forget_pull_request_order"])
        #expect(await Self.failure { try await forget.run(try Self.arguments(#"{"order": "\#(id)", "revision": 1}"#)) } != nil)
        #expect(try await forget.run(try Self.arguments(#"{"order": "\#(id)", "revision": 2}"#)) == "BriefBar forgot order \(id).")
        #expect(DeclaredOrders.load(from: defaults).plans.isEmpty)
        #expect(announcements.total == 3)
        #expect(try await #require(tools["pull_request_order"]).run(.object([:]))
            == "No session has told BriefBar an order of pull requests.")
    }

    /// Turning Pull Request Order off keeps the orders, and the tools of an agent that started with it on say it's off.
    @Test func turnedOffEveryCallIsRefusedAndTheOrdersStay() async throws {
        let defaults = Self.settings()
        let tools = Self.tools(defaults)
        _ = try await #require(tools["order_pull_requests"]).run(try Self.arguments(Self.userExample))

        defaults.set(false, forKey: PullRequestOrderSetting.defaultsKey)

        for name in ["order_pull_requests", "pull_request_order", "forget_pull_request_order"] {
            let refusal = await Self.failure { try await #require(tools[name]).run(try Self.arguments(Self.userExample)) }
            #expect(refusal?.hasPrefix("Pull Request Order is off in BriefBar") == true, "\(name)")
        }
        #expect(DeclaredOrders.load(from: defaults).plans.count == 1)
    }

    @Test func aPullRequestWhoseSourceIsOffIsRefused() async throws {
        let defaults = Self.settings()
        let order = try #require(Self.tools(defaults, sourcesOn: [.pullRequest])["order_pull_requests"])

        let refusal = await Self.failure {
            try await order.run(try Self.arguments("""
                {"pull_requests": ["\(Self.link(4101))", {"link": "https://github.com/octo/storefront/pull/7", "after": [4101]}]}
                """))
        }

        #expect(refusal?.hasPrefix("GitHub is off in BriefBar, so it keeps no order with octo/storefront#7") == true)
        #expect(DeclaredOrders.load(from: defaults).plans.isEmpty)
    }

    @Test func whatAnAgentSendsIsCheckedAndWhatsWrongIsSaid() async throws {
        let order = try #require(Self.tools(Self.settings())["order_pull_requests"])
        let cases: [(String, String)] = [
            (#"{}"#, "Give pull_requests"),
            (#"{"pull_requests": [{"after": ["4101"]}]}"#, "Give each pull request in pull_requests with its link"),
            (#"{"pull_requests": [{"link": "\#(Self.link(4101))", "after": [true]}]}"#, "Name each pull request in after"),
            (#"{"pull_requests": [{"link": "\#(Self.link(4101))", "review": {"when": "later"}}]}"#, "Give review's when"),
            (#"{"pull_requests": [{"link": "\#(Self.link(4101))", "review": 3}]}"#, "Give review as"),
            (
                #"{"pull_requests": ["\#(Self.link(4101))", {"link": "\#(Self.link(4102))", "review": {"after": [4101]}}]}"#,
                "Say why to review it after them, with reason: one of builds_on_changes, same_code, stacked_diff, needs_decision."
            ),
            (#"{"revision": "first", "pull_requests": ["\#(Self.link(4101))"]}"#, "Give the revision as a whole number"),
            (#"{"pull_requests": ["https://example.com/4101"]}"#, "‘https://example.com/4101’ isn't a link to a pull request"),
            (#"{"pull_requests": ["\#(Self.link(4101))"], "session": "me"}"#, "‘me’ isn't a Copilot session's ID or link."),
        ]
        for (json, said) in cases {
            let failure = await Self.failure { try await order.run(try Self.arguments(json)) }
            #expect(failure?.hasPrefix(said) == true, "\(json): \(failure ?? "kept")")
        }
    }

    /// An order is the session's that started BriefBar for the agent, unless the agent names another.
    @Test func theSessionAnAgentNamesIsKept() async throws {
        let defaults = Self.settings()
        let other = "0b6c1f44-6a1e-4c55-9d0e-3f0a6f1c2a01"
        let order = try #require(Self.tools(defaults, session: nil)["order_pull_requests"])

        _ = try await order.run(try Self.arguments(#"{"pull_requests": ["\#(Self.link(4101))"], "session": "\#(other)"}"#))
        _ = try await order.run(try Self.arguments(#"{"pull_requests": ["\#(Self.link(4102))"]}"#))

        #expect(DeclaredOrders.load(from: defaults).plans.map(\.declaredBy) == [ItemRef.session(other), nil])
        let read = try await #require(Self.tools(defaults)["pull_request_order"]).run(.object([:]))
        #expect(read.contains("Told by session \(other), last on"))
        #expect(read.contains("Told without saying by which session, last on"))
    }

    @Test func theDemoKeepsItsOrdersInMemoryAndTellsTheAppNothing() async throws {
        let announcements = Announcements()
        let order = try #require(Self.tools(Self.settings(on: false), demo: true, announcements: announcements)["order_pull_requests"])

        let told = try await order.run(try Self.arguments(Self.userExample))

        #expect(told.contains("at revision 1. (The demo keeps it in memory.)"))
        #expect(announcements.total == 0)
    }
}
