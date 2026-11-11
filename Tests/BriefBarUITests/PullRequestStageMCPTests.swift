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
    private static let sessionRef = ItemRef.session(session)!
    private static let otherSession = "2b8d4f60-9a1c-4e3b-b7d5-6f8e9a0b1c2d"
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

    /// What Azure DevOps reads of its pull requests now: those it lists, with their facts. !4100 is Priya's, which she
    /// asked you to review.
    private static let listed: [ItemRef: StageFacts] = [
        ref(4093): StageFacts(role: .author, votes: "", commit: "a1b2c3d"),
        ref(4094): StageFacts(role: .author, votes: "10", commit: "e4f5a6b"),
        ref(4095): StageFacts(role: .author, state: .merged),
        ref(4096): StageFacts(role: .author, isListed: false),
        ref(4100): StageFacts(role: .reviewer, asksYou: "Priya asked you", votes: "0", commit: "c0ffee1", author: "Priya"),
    ]

    private static func read(_ refs: [ItemRef]) -> MCPStages.Read {
        MCPStages.Read(account: account, facts: listed.filter { refs.contains($0.key) })
    }

    /// - Parameters:
    ///   - refusal: why what's read can't be kept, as agents or Azure DevOps being off in the app say.
    ///   - listedSessions: the sessions whose stages BriefBar shows, this one unless a test says otherwise; nil when it
    ///     can't tell.
    ///   - sessionsOn: the Copilot app's listed sessions on each pull request.
    private static func tools(
        _ defaults: MemoryDefaults, demo: Bool = false, session: String? = session,
        copilotOn: @escaping @Sendable () -> Bool = { true },
        read: @escaping @Sendable ([ItemRef]) async throws -> MCPStages.Read = { refs in read(refs) },
        refusal: @escaping @Sendable () -> String? = { nil }, listedSessions: Set<ItemRef>? = [sessionRef],
        sessionsOn: [ItemRef: [StageSession]] = [:],
        announcements: Announcements = Announcements(), now: @escaping @Sendable () -> Date = { now }
    ) -> [String: MCPTool] {
        let tools = PullRequestOrderMCP.tools(
            defaults: defaults, demo: demo, sourcesOn: { [.pullRequest] }, session: session,
            stages: MCPStages(read: read, sessions: { listedSessions.map { MCPStages.Sessions(listed: $0, on: sessionsOn) } })
                .guarded(by: refusal), copilotOn: copilotOn,
            announce: { announcements.add() }, now: now
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

    /// It's listed with Pull Request Order's tools only with Azure DevOps' stages, and only for the Copilot session that
    /// started `--mcp`, as the Copilot CLI says: never in VS Code or Cursor, whose agents aren't Copilot sessions, and
    /// whose stages would show as another session's or never. It asks for no session.
    @Test func itsListedOnlyWithAzureDevOpsStagesForTheSessionThatStartedIt() throws {
        #expect(Self.tools(Self.settings(on: false)).isEmpty)
        func names(session: String?, stages: MCPStages?) -> [String] {
            PullRequestOrderMCP.tools(defaults: Self.settings(), demo: false, sourcesOn: { [] }, session: session, stages: stages)
                .map(\.name)
        }
        let stages = MCPStages { _ in MCPStages.Read(account: nil, facts: [:]) }
        #expect(names(session: Self.session, stages: stages)
            == ["order_pull_requests", "pull_request_order", "forget_pull_request_order", "pull_request_stage"])
        #expect(!names(session: Self.session, stages: nil).contains("pull_request_stage"))
        #expect(names(session: nil, stages: stages) == ["order_pull_requests", "pull_request_order", "forget_pull_request_order"])
        #expect(!names(session: "nonsense", stages: stages).contains("pull_request_stage"))

        let tool = try #require(Self.tools(Self.settings())["pull_request_stage"])
        #expect(tool.readOnly == false)
        #expect(tool.inputSchema["properties"]?["session"] == nil)
        #expect(tool.inputSchema["properties"]?["stage"] != nil)
    }

    /// One session can't set or clear another's stages, by naming it in `session`, which it isn't asked for.
    @Test func itSetsAndClearsOnlyItsOwnSessionsStages() async throws {
        let defaults = Self.settings()
        let other = try #require(ItemRef.session(Self.otherSession))
        SessionStages.change(other, in: defaults, now: Self.now) {
            $0.set(StageMark(stage: .yourReview, at: Self.now, by: other, votes: ""), of: Self.ref(4093))
        }
        let tools = Self.tools(defaults, listedSessions: [Self.sessionRef, other])
        for stage in ["clear", "in_progress"] {
            let json = #"{"pull_requests": [4093], "organization": "contoso", "stage": "\#(stage)", "session": "\#(Self.otherSession)"}"#
            let refusal = await Self.failure { try await Self.set(tools, json) }
            #expect(refusal?.hasPrefix("A session tells BriefBar only its own work, and you are session \(Self.session)") == true)
        }
        #expect(SessionStages.load(other, from: defaults)?.marks[Self.ref(4093)]?.stage == .yourReview)
        #expect(Self.kept(defaults) == nil)

        // Its own, repeated, is fine.
        let json = #"{"pull_requests": [4093], "organization": "contoso", "stage": "in_progress", "session": "\#(Self.session)"}"#
        _ = try await Self.set(tools, json)
        #expect(Self.kept(defaults)?.marks[Self.ref(4093)]?.stage == .inProgress)
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
        // With the votes as it read them, which end it as they change.
        let mark = try #require(Self.kept(defaults)?.marks[Self.ref(4093)])
        #expect(mark == StageMark(stage: .yourReview, at: Self.now, by: ItemRef.session(Self.session), votes: ""))
        #expect(announcements.total == 1)

        // By numbers with organization; In progress keeps the commit, Teammate's review the votes.
        _ = try await Self.set(tools, #"{"pull_requests": [4093, "!4094"], "organization": "contoso", "stage": "in_progress"}"#)
        #expect(Self.kept(defaults)?.marks[Self.ref(4093)]?.commit == "a1b2c3d")
        _ = try await Self.set(tools, #"{"pull_requests": ["4094"], "organization": "contoso", "stage": "teammate_review"}"#)
        #expect(Self.kept(defaults)?.marks[Self.ref(4094)]?.votes == "10")
        #expect(Self.kept(defaults)?.marks[Self.ref(4094)]?.stage == .teammateReview)
        #expect(announcements.total == 3)
    }

    /// The answer says what the user set that it replaces, while it stands: they can put theirs back while the
    /// session's lasts, and theirs goes once it ends.
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
            The user had set Teammate's review 3m ago; yours replaces it. They can put theirs back while yours lasts; \
            once yours ends, theirs goes too.
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
            The user had set Teammate's review on !4093 in contoso 3m ago; yours replaces it. They can put theirs back \
            while yours lasts; once yours ends, theirs goes too.
            """))
    }

    /// In progress over a Your review the user set, with nothing else set since, shows over it rather than replace it,
    /// as theirs lasts until they change it: they can put theirs back while it lasts, and once it ends, theirs shows
    /// again. What this session set there before, which this replaces, doesn't count; another session's other stage
    /// after theirs replaced it, so theirs goes once this ends. A Your review it says once it pushed follows theirs
    /// where theirs outlasts its In progress.
    @Test func inProgressOverTheUsersYourReviewShowsOverIt() async throws {
        let other = try #require(ItemRef.session(Self.otherSession))
        let defaults = Self.settings()
        var marks = StageMarks()
        for number in [4093, 4094] {
            _ = marks.set(StageMark(stage: .yourReview, at: Self.now - 120), of: Self.ref(number), for: "robin@contoso.com", at: Self.now)
        }
        marks.save(to: defaults)
        SessionStages.change(Self.sessionRef, in: defaults, now: Self.now - 60) {
            $0.set(StageMark(stage: .teammateReview, at: Self.now - 60, by: Self.sessionRef, votes: ""), of: Self.ref(4093))
        }
        SessionStages.change(other, in: defaults, now: Self.now - 60) {
            $0.set(StageMark(stage: .teammateReview, at: Self.now - 60, by: other, votes: "10"), of: Self.ref(4094))
        }
        let json = #"{"pull_requests": [4093, 4094], "organization": "contoso", "stage": "in_progress"}"#
        let answer = try await Self.set(Self.tools(defaults, listedSessions: [Self.sessionRef, other]), json)
        #expect(answer == """
            BriefBar shows !4093 and !4094 in contoso in In progress now, set by this session; the user sees who set \
            it, and can change it.
            The user had set Your review on !4093 in contoso 2m ago; yours shows over it. They can put theirs back \
            while yours lasts; once yours ends, theirs shows again.
            The user had set Your review on !4094 in contoso 2m ago; yours replaces it. They can put theirs back while \
            yours lasts; once yours ends, theirs goes too.
            """)

        let later = Self.tools(defaults, listedSessions: [Self.sessionRef, other], now: { Self.now + 60 })
        let ready = try await Self.set(later, #"{"pull_requests": [4093, 4094], "organization": "contoso", "stage": "user_review"}"#)
        #expect(ready.hasSuffix("""
            The user had set Your review on !4093 in contoso 3m ago already; yours lasts as theirs does, and goes with \
            it, rather than end once someone else votes.
            """))
        #expect(Self.kept(defaults)?.marks[Self.ref(4093)]?.votes == nil)
        #expect(Self.kept(defaults)?.marks[Self.ref(4094)]?.votes == "10")
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

    /// A Your review where the user's Your review outlasts what sessions set since, only In progress and Your reviews
    /// that followed it, keeps no votes, saying so: it lasts as theirs does, while theirs is there, rather than end as
    /// someone else votes, and theirs with it as the latest set. Its own that did so is no later stage. Where a listed
    /// session's other stage came after theirs, it keeps its votes, as anywhere; so does another stage the user set
    /// too, which ends as theirs does anyway.
    @Test func aYourReviewAfterTheUsersLastsAsTheirsDoes() async throws {
        let other = try #require(ItemRef.session(Self.otherSession))
        // You set Your review on both; this session had put !4093 in progress before, another set Teammate's review on
        // !4094 since.
        func defaults() -> MemoryDefaults {
            let defaults = Self.settings()
            var marks = StageMarks()
            for number in [4093, 4094] {
                _ = marks.set(StageMark(stage: .yourReview, at: Self.now - 120), of: Self.ref(number), for: "robin@contoso.com", at: Self.now)
            }
            marks.save(to: defaults)
            SessionStages.change(Self.sessionRef, in: defaults, now: Self.now - 300) {
                $0.set(StageMark(stage: .inProgress, at: Self.now - 300, by: Self.sessionRef, commit: "a1b2c3d"), of: Self.ref(4093))
            }
            SessionStages.change(other, in: defaults, now: Self.now - 60) {
                $0.set(StageMark(stage: .teammateReview, at: Self.now - 60, by: other, votes: "10"), of: Self.ref(4094))
            }
            return defaults
        }
        let json = #"{"pull_requests": [4093, 4094], "organization": "contoso", "stage": "user_review"}"#
        let listed = defaults()
        let tools = Self.tools(listed, listedSessions: [Self.sessionRef, other])
        let answer = try await Self.set(tools, json)
        #expect(answer == """
            BriefBar shows !4093 and !4094 in contoso in Your review now, set by this session; the user sees who set it, \
            and can change it.
            The user had set Your review on !4093 in contoso 2m ago already; yours lasts as theirs does, and goes \
            with it, rather than end once someone else votes.
            """)
        #expect(Self.kept(listed)?.marks[Self.ref(4093)] == StageMark(stage: .yourReview, at: Self.now, by: Self.sessionRef))
        #expect(Self.kept(listed)?.marks[Self.ref(4094)]?.votes == "10")
        _ = try await Self.set(tools, json)
        #expect(Self.kept(listed)?.marks[Self.ref(4093)]?.votes == nil)

        // Only the sessions the app lists count, as in the app.
        let unlisted = defaults()
        let both = try await Self.set(Self.tools(unlisted, listedSessions: [Self.sessionRef]), json)
        #expect(both.hasSuffix("""
            The user had set Your review on !4094 in contoso 2m ago already; yours lasts as theirs does, and goes \
            with it, rather than end once someone else votes.
            """))
        #expect(Self.kept(unlisted)?.marks.values.map(\.votes) == [nil, nil])

        let teammate = Self.settings()
        var marks = StageMarks()
        _ = marks.set(StageMark(stage: .teammateReview, at: Self.now - 120, votes: "10"), of: Self.ref(4094), for: "robin@contoso.com", at: Self.now)
        marks.save(to: teammate)
        let same = try await Self.set(Self.tools(teammate), #"{"pull_requests": [4094], "organization": "contoso", "stage": "teammate_review"}"#)
        #expect(same == """
            BriefBar shows !4094 in contoso in Teammate's review now, set by this session; the user sees who set it, and \
            can change it.
            """)
        #expect(Self.kept(teammate)?.marks[Self.ref(4094)]?.votes == "10")
    }

    /// Whether a Your review follows the user's is decided as it's kept, in one step, so it can't go stale: a newer stage
    /// of this session's, from a call of its own that lands meanwhile, here as the last check before keeping anything
    /// runs, came after theirs, so this one keeps its votes, as any does.
    @Test func whetherItFollowsTheUsersIsDecidedAsItsKept() async throws {
        let defaults = Self.settings()
        var marks = StageMarks()
        _ = marks.set(StageMark(stage: .yourReview, at: Self.now - 120), of: Self.ref(4093), for: "robin@contoso.com", at: Self.now)
        marks.save(to: defaults)
        let session = Self.sessionRef
        let checks = Mutex(0)
        let tools = Self.tools(defaults, refusal: {
            // The first check comes as it reads the pull request, the second just before it keeps anything.
            if checks.withLock({ $0 += 1; return $0 }) == 2 {
                SessionStages.change(session, in: defaults, now: Self.now - 30) {
                    $0.set(StageMark(stage: .teammateReview, at: Self.now - 30, by: session, votes: ""), of: Self.ref(4093))
                }
            }
            return nil
        })
        let answer = try await Self.set(tools, #"{"pull_requests": [4093], "organization": "contoso", "stage": "user_review"}"#)
        #expect(answer == """
            BriefBar shows !4093 in contoso in Your review now, set by this session; the user sees who set it, and can \
            change it.
            """)
        #expect(Self.kept(defaults)?.marks[Self.ref(4093)] == StageMark(stage: .yourReview, at: Self.now, by: session, votes: ""))
        #expect(checks.withLock { $0 } == 2)
    }

    /// What the user set as the session read the pull request came after what the session says, and shows: the answer says
    /// so, rather than that BriefBar shows the session's, or that it replaces theirs. A Your review the session sets there
    /// keeps its votes, as anywhere, rather than follow theirs, so that it ends as someone else votes once theirs goes.
    @Test func whatTheUserSetAsItReadThePullRequestShowsAsTheLater() async throws {
        let defaults = Self.settings()
        var marks = StageMarks()
        _ = marks.set(StageMark(stage: .yourReview, at: Self.now + 30), of: Self.ref(4093), for: "robin@contoso.com", at: Self.now + 30)
        _ = marks.set(
            StageMark(stage: .teammateReview, at: Self.now + 30, votes: "10"), of: Self.ref(4094), for: "robin@contoso.com",
            at: Self.now + 30
        )
        marks.save(to: defaults)
        let tools = Self.tools(defaults)
        let one = try await Self.set(tools, #"{"pull_requests": [4093], "organization": "contoso", "stage": "user_review"}"#)
        #expect(one == """
            The user set Your review on !4093 in contoso just now, after this session read it: BriefBar shows theirs, the \
            later.
            """)
        #expect(Self.kept(defaults)?.marks[Self.ref(4093)] == StageMark(stage: .yourReview, at: Self.now, by: Self.sessionRef, votes: ""))

        let two = try await Self.set(tools, #"{"pull_requests": [4094, 4100], "organization": "contoso", "stage": "user_review"}"#)
        #expect(two == """
            BriefBar shows !4100 in contoso in Your review now, set by this session; the user sees who set it, and can \
            change it.
            The user set Teammate's review on !4094 in contoso just now, after this session read it: BriefBar shows theirs, \
            the later.
            """)
    }

    /// Whether the stage the user set still stands, for them to put it back, is worked out as the app works it out, with
    /// the Copilot app's sessions on the pull request: one that finished writing it since ends the user's In progress.
    @Test func aLinkedSessionThatFinishedEndsTheUsersInProgressAsInTheApp() async throws {
        let defaults = Self.settings()
        var marks = StageMarks()
        let yours = StageMark(stage: .inProgress, at: Self.now - 120, commit: "a1b2c3d")
        _ = marks.set(yours, of: Self.ref(4093), for: "robin@contoso.com", at: Self.now)
        marks.save(to: defaults)
        let json = #"{"pull_requests": [4093], "organization": "contoso", "stage": "user_review"}"#

        // With nothing else on it, theirs stands: they can put it back.
        let alone = try await Self.set(Self.tools(defaults), json)
        #expect(alone.hasSuffix("""
            The user had set In progress 2m ago; yours replaces it. They can put theirs back while yours lasts; once \
            yours ends, theirs goes too.
            """))

        // A Copilot session on it finished writing it since: theirs ended, as in the app, with nothing to put back.
        let other = try #require(ItemRef.session(Self.otherSession))
        let finished = [Self.ref(4093): [StageSession(ref: other, activity: .finished, since: Self.now - 30)]]
        let tools = Self.tools(defaults, listedSessions: [Self.sessionRef, other], sessionsOn: finished)
        #expect(try await Self.set(tools, json) == """
            BriefBar shows !4093 in contoso in Your review now, set by this session; the user sees who set it, and can \
            change it.
            """)
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

    /// It puts only the user's own pull requests in progress, as BriefBar's own rule does for a session it sees writing:
    /// someone else's is left as it is, saying why. The other stages it sets on any.
    @Test func itPutsOnlyTheUsersOwnPullRequestsInProgress() async throws {
        let defaults = Self.settings()
        let tools = Self.tools(defaults)
        let someoneElses = "Not !4100 in contoso: it isn't the user's, and BriefBar puts only the user's own pull requests in progress."
        let refused = await Self.failure {
            try await Self.set(tools, #"{"pull_requests": [4100], "organization": "contoso", "stage": "in_progress"}"#)
        }
        #expect(refused == someoneElses)
        #expect(Self.kept(defaults) == nil)

        let both = try await Self.set(tools, #"{"pull_requests": [4093, 4100], "organization": "contoso", "stage": "in_progress"}"#)
        #expect(both.hasSuffix("change it.\n" + someoneElses))
        #expect(Self.kept(defaults)?.marks.keys.sorted() == [Self.ref(4093)])

        _ = try await Self.set(tools, #"{"pull_requests": [4100], "organization": "contoso", "stage": "user_review"}"#)
        #expect(Self.kept(defaults)?.marks[Self.ref(4100)]?.stage == .yourReview)
    }

    /// It says BriefBar shows a stage only where it does. A session the Copilot app doesn't list, such as one run in a
    /// terminal, keeps none, since BriefBar wouldn't show it; where `--mcp` can't tell which sessions the app lists, it
    /// keeps it, saying it shows it while the app lists this session.
    @Test func itSaysBriefBarShowsAStageOnlyWhereItDoes() async throws {
        let json = #"{"pull_requests": [4093], "organization": "contoso", "stage": "user_review"}"#
        let unlisted = Self.settings()
        let other = try #require(ItemRef.session(Self.otherSession))
        let announcements = Announcements()
        let terminal = Self.tools(unlisted, listedSessions: [other], announcements: announcements)
        #expect(await Self.failure { try await Self.set(terminal, json) } == """
            The Copilot app doesn't list this session, as with one run in a terminal, and BriefBar shows only the stages \
            of sessions it lists: it kept none.
            """)
        #expect(await Self.failure { try await Self.set(Self.tools(unlisted, listedSessions: []), json) } != nil)
        #expect(Self.kept(unlisted) == nil)
        #expect(announcements.total == 0)

        let unknown = Self.settings()
        #expect(try await Self.set(Self.tools(unknown, listedSessions: nil), json) == """
            BriefBar keeps !4093 in contoso in Your review, set by this session, and shows it while the Copilot app lists \
            this session; the user sees who set it, and can change it.
            """)
        #expect(Self.kept(unknown)?.marks[Self.ref(4093)]?.stage == .yourReview)
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
        for stage in ["can_merge", "approved"] {
            #expect(await refusal(#"{"pull_requests": [4093], "organization": "contoso", "stage": "\#(stage)"}"#) == """
                BriefBar sets Approved, Can merge, Waits and Merged itself, from what Azure DevOps shows and the order: \
                give stage as in_progress, user_review, teammate_review or clear.
                """)
        }
        #expect(await refusal(#"{"pull_requests": [4093], "organization": "contoso", "stage": "done"}"#) ==
            "There's no stage “done”: give stage as in_progress, user_review, teammate_review or clear.")
        // Only its own session's.
        let other = #"{"pull_requests": [4093], "organization": "contoso", "stage": "user_review", "session": "2b8d4f60-9a1c-4e3b-b7d5-6f8e9a0b1c2d"}"#
        #expect(await refusal(other)?.hasPrefix("A session tells BriefBar only its own work") == true)
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
