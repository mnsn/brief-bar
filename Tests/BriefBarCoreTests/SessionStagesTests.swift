import BriefBarCore
import Foundation
import Testing

/// The stages Copilot sessions set, each session's under its own key, as what sessions tell is kept.
@Suite struct SessionStagesTests {
    /// Midday in UTC.
    private static let now = Date(timeIntervalSince1970: 1_791_979_200)
    private static let day: TimeInterval = 86_400
    private static let session = ItemRef.session("6f9619ff-8b86-d011-b42d-00c04fc964ff")!
    private static let other = ItemRef.session("a3d9c5e1-7b2f-4e84-9c16-5f8e2d0b7a11")!
    private static let pullRequest = ItemRef.pullRequest(organization: "contoso", number: 4102)
    private static let another = ItemRef.pullRequest(organization: "contoso", number: 4118)
    private static let task = ItemRef.workItem(organization: "contoso", id: 5124)
    private static let gitHub = ItemRef.gitHubPullRequest(repository: "octo/app", number: 12)

    private static func mark(_ stage: PullRequestStage, _ at: Date, votes: String? = nil, commit: String? = nil) -> StageMark {
        StageMark(stage: stage, at: at, votes: votes, commit: commit)
    }

    // MARK: One session's

    /// Each mark is the session's, whoever the mark said; only a stage you can set, on a pull request.
    @Test func keepsOnlyStagesASessionCanSetOnPullRequestsAsItsOwn() {
        var stage = SessionStage(session: Self.session)
        stage.set(StageMark(stage: .yourReview, at: Self.now, by: Self.other), of: Self.pullRequest)
        stage.set(Self.mark(.canMerge, Self.now), of: Self.another)
        stage.set(Self.mark(.merged, Self.now), of: Self.another)
        stage.set(Self.mark(.inProgress, Self.now), of: Self.task)
        stage.set(Self.mark(.teammateReview, Self.now), of: Self.gitHub)
        #expect(stage.marks[Self.pullRequest] == StageMark(stage: .yourReview, at: Self.now, by: Self.session))
        #expect(stage.marks[Self.another] == nil)
        #expect(stage.marks[Self.task] == nil)
        #expect(stage.marks[Self.gitHub]?.by == Self.session)

        stage.set(Self.mark(.teammateReview, Self.now + 60, votes: "10"), of: Self.pullRequest)
        #expect(stage.marks[Self.pullRequest]?.stage == .teammateReview)
        #expect(stage.marks[Self.pullRequest]?.votes == "10")
        let cleared = stage.clear(Self.pullRequest)
        let again = stage.clear(Self.pullRequest)
        #expect(cleared && !again)
    }

    @Test func keepsTheNewestFiftyAndForgetsThoseOlderThanThirtyDays() {
        var stage = SessionStage(session: Self.session)
        for number in 1...60 {
            stage.set(Self.mark(.yourReview, Self.now + Double(number)), of: .pullRequest(organization: "contoso", number: number))
        }
        #expect(stage.marks.count == SessionStages.mostPullRequests)
        #expect(stage.marks[.pullRequest(organization: "contoso", number: 60)] != nil)
        #expect(stage.marks[.pullRequest(organization: "contoso", number: 10)] == nil)

        var old = SessionStage(session: Self.session)
        old.set(Self.mark(.yourReview, Self.now - 31 * Self.day), of: Self.pullRequest)
        old.set(Self.mark(.inProgress, Self.now - 29 * Self.day), of: Self.another)
        old.expire(now: Self.now)
        #expect(Array(old.marks.keys) == [Self.another])
    }

    // MARK: What shows

    /// What a session set shows only while the Copilot app lists it, the earliest first.
    @Test func showsWhatListedSessionsSetOnly() {
        var mine = SessionStage(session: Self.session)
        mine.set(Self.mark(.teammateReview, Self.now - 60), of: Self.pullRequest)
        var theirs = SessionStage(session: Self.other)
        theirs.set(Self.mark(.yourReview, Self.now - 600), of: Self.pullRequest)
        theirs.set(Self.mark(.yourReview, Self.now - 40 * Self.day), of: Self.another)
        let stages = SessionStages([mine, theirs])

        let both = stages.marks(listed: [Self.session, Self.other], now: Self.now)
        #expect(both[Self.pullRequest]?.map(\.by) == [Self.other, Self.session])
        #expect(both[Self.another] == nil)
        #expect(stages.marks(listed: [Self.session], now: Self.now)[Self.pullRequest]?.map(\.by) == [Self.session])
        #expect(stages.marks(listed: [], now: Self.now).isEmpty)
    }

    // MARK: Saving

    @Test func keepsEachSessionUnderItsOwnKeyWithWhatEndsItsStages() throws {
        let defaults = MemorySettings()
        SessionStages.change(Self.session, in: defaults, now: Self.now) {
            $0.set(Self.mark(.teammateReview, Self.now, votes: "10,10"), of: Self.pullRequest)
            $0.set(Self.mark(.inProgress, Self.now, commit: "8c1f"), of: Self.another)
        }
        SessionStages.change(Self.other, in: defaults, now: Self.now) { $0.set(Self.mark(.yourReview, Self.now), of: Self.pullRequest) }
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(SessionStages.keyPrefix) }.sorted()
        #expect(keys == ["order.stage.\(Self.other.id)", "order.stage.\(Self.session.id)"].sorted())
        // Yours are kept under another key, which the prefix doesn't find.
        #expect(!StageMarks.defaultsKey.hasPrefix(SessionStages.keyPrefix))

        let kept = try #require(SessionStages.load(Self.session, from: defaults))
        #expect(kept.marks[Self.pullRequest] == StageMark(stage: .teammateReview, at: Self.now, by: Self.session, votes: "10,10"))
        #expect(kept.marks[Self.another] == StageMark(stage: .inProgress, at: Self.now, by: Self.session, commit: "8c1f"))
        #expect(SessionStages.load(from: defaults, now: Self.now)[Self.other]?.marks.keys.sorted() == [Self.pullRequest])
        #expect(SessionStages.keepsAny(in: defaults))

        // References, codes and dates only.
        let saved = String(decoding: try #require(defaults.data(forKey: SessionStages.key(for: Self.session))), as: UTF8.self)
        #expect(saved.contains("\"stage\":\"teammateReview\"") && saved.contains("\"pullRequest\":\"\(Self.pullRequest)\""))

        SessionStages.change(Self.session, in: defaults, now: Self.now) {
            $0.clear(Self.pullRequest)
            $0.clear(Self.another)
        }
        #expect(defaults.object(forKey: SessionStages.key(for: Self.session)) == nil)
    }

    /// A stage of a later version's, or an entry that isn't one, drops alone; a record under another session's key, or
    /// one that isn't a session's, isn't read.
    @Test func readsWhatItCanOfARecord() throws {
        let defaults = MemorySettings()
        let at = Self.now.timeIntervalSinceReferenceDate
        let record = """
            {"session": "\(Self.session)", "stages": [
              {"pullRequest": "\(Self.pullRequest)", "stage": "yourReview", "at": \(at)},
              {"pullRequest": "\(Self.another)", "stage": "blockedByLegal", "at": \(at)},
              {"pullRequest": "not a reference", "stage": "inProgress", "at": \(at)},
              {"stage": "inProgress"}
            ]}
            """
        defaults.set(Data(record.utf8), forKey: SessionStages.key(for: Self.session))
        defaults.set(Data(record.utf8), forKey: SessionStages.key(for: Self.other))
        defaults.set(Data("{\"session\": \"\(Self.task)\", \"stages\": []}".utf8), forKey: "order.stage.5124")
        let loaded = SessionStages.load(from: defaults, now: Self.now)
        #expect(Array(loaded.sessions.keys) == [Self.session])
        #expect(loaded[Self.session]?.marks.keys.sorted() == [Self.pullRequest])
    }

    /// Past its time, it goes from what's kept, but only from a record still as it was read.
    @Test func prunesWhatsPastItsTime() throws {
        let defaults = MemorySettings()
        SessionStages.change(Self.session, in: defaults, now: Self.now - 31 * Self.day) {
            $0.set(Self.mark(.yourReview, Self.now - 31 * Self.day), of: Self.pullRequest)
        }
        SessionStages.change(Self.other, in: defaults, now: Self.now - 2 * Self.day) {
            $0.set(Self.mark(.yourReview, Self.now - 31 * Self.day), of: Self.pullRequest)
            $0.set(Self.mark(.inProgress, Self.now - Self.day), of: Self.another)
        }
        #expect(SessionStages.load(from: defaults, now: Self.now)[Self.session] == nil)
        SessionStages.prune(in: defaults, now: Self.now)
        #expect(defaults.object(forKey: SessionStages.key(for: Self.session)) == nil)
        #expect(try #require(SessionStages.load(Self.other, from: defaults)).marks.keys.sorted() == [Self.another])
    }

    /// The app ends a session's stage that no longer stands only as it read it: once the session set it again, it stays.
    @Test func endsOnlyTheMarkThatWasRead() throws {
        let defaults = MemorySettings()
        SessionStages.change(Self.session, in: defaults, now: Self.now) {
            $0.set(Self.mark(.inProgress, Self.now - 600), of: Self.pullRequest)
            $0.set(Self.mark(.yourReview, Self.now - 600), of: Self.another)
        }
        #expect(!SessionStages.end(Self.pullRequest, of: Self.session, setAt: Self.now - 601, in: defaults))
        #expect(!SessionStages.end(Self.pullRequest, of: Self.other, setAt: Self.now - 600, in: defaults))
        #expect(SessionStages.end(Self.pullRequest, of: Self.session, setAt: Self.now - 600, in: defaults))
        #expect(try #require(SessionStages.load(Self.session, from: defaults)).marks.keys.sorted() == [Self.another])
        #expect(SessionStages.end(Self.another, of: Self.session, setAt: Self.now - 600, in: defaults))
        #expect(defaults.object(forKey: SessionStages.key(for: Self.session)) == nil)
    }

    /// At most a hundred sessions' stages: those that set one longest ago go first.
    @Test func keepsAHundredSessions() {
        let defaults = MemorySettings()
        let sessions = (0..<101).map { ItemRef.session(String(format: "00000000-0000-4000-8000-%012d", $0))! }
        for (index, session) in sessions.enumerated() {
            let at = Self.now - Double(200 - index) * 60
            SessionStages.change(session, in: defaults, now: at) { $0.set(Self.mark(.yourReview, at), of: Self.pullRequest) }
        }
        let kept = SessionStages.load(from: defaults, now: Self.now)
        #expect(kept.sessions.count == SessionStages.mostSessions)
        #expect(kept[sessions[0]] == nil)
        #expect(kept[sessions[100]] != nil)
    }

    /// Turning Azure DevOps off forgets what sessions set on its pull requests; turning GitHub Copilot off forgets them
    /// all; Forget Stages… too.
    @Test func forgetsBySourceAndAll() {
        let defaults = MemorySettings()
        SessionStages.change(Self.session, in: defaults, now: Self.now) {
            $0.set(Self.mark(.yourReview, Self.now), of: Self.pullRequest)
            $0.set(Self.mark(.yourReview, Self.now), of: Self.gitHub)
        }
        SessionStages.change(Self.other, in: defaults, now: Self.now) { $0.set(Self.mark(.yourReview, Self.now), of: Self.another) }

        SessionStages.forget([.workItem, .pullRequest], in: defaults, now: Self.now)
        let left = SessionStages.load(from: defaults, now: Self.now)
        #expect(Array(left.sessions.keys) == [Self.session])
        #expect(left[Self.session]?.marks.keys.sorted() == [Self.gitHub])

        var inMemory = SessionStages(Array(left.sessions.values))
        inMemory.forget([.session])
        #expect(inMemory.isEmpty)
        SessionStages.forget([.session], in: defaults, now: Self.now)
        #expect(!SessionStages.keepsAny(in: defaults))

        SessionStages.change(Self.session, in: defaults, now: Self.now) { $0.set(Self.mark(.yourReview, Self.now), of: Self.pullRequest) }
        defaults.set(Data("{}".utf8), forKey: StageMarks.defaultsKey)
        SessionStages.forgetAll(in: defaults)
        #expect(!SessionStages.keepsAny(in: defaults))
        #expect(defaults.object(forKey: StageMarks.defaultsKey) != nil)
    }
}
