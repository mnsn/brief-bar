import BriefBarCore
import Foundation
import Testing

@Suite struct SessionReportsTests {
    /// Midday in UTC.
    private static let now = Date(timeIntervalSince1970: 1_791_979_200)
    private static let day: TimeInterval = 86_400
    private static let session = ItemRef.session("6f9619ff-8b86-d011-b42d-00c04fc964ff")!
    private static let other = ItemRef.session("a3d9c5e1-7b2f-4e84-9c16-5f8e2d0b7a11")!
    private static let task = ItemRef.workItem(organization: "contoso", id: 5124)
    private static let story = ItemRef.workItem(organization: "contoso", id: 5101)
    private static let pullRequest = ItemRef.pullRequest(organization: "contoso", number: 4102)
    private static let another = ItemRef.pullRequest(organization: "contoso", number: 4118)
    private static let gitHub = ItemRef.gitHubPullRequest(repository: "octo/app", number: 12)

    // MARK: A session's report

    @Test func replacesWhatItWorksOnAndClearsIt() {
        var report = SessionReport(session: Self.session)
        report.setWorkingOn([Self.task, Self.pullRequest, Self.task, Self.other], at: Self.now)
        #expect(report.workingOn == [Self.task, Self.pullRequest])
        #expect(report.workingOnSince == Self.now)
        report.setWorkingOn([Self.story], at: Self.now)
        #expect(report.workingOn == [Self.story])
        report.setWorkingOn([], at: Self.now)
        #expect(report.workingOn.isEmpty)
        #expect(report.isEmpty)
    }

    @Test func keepsTwentyItemsAndTheNewestFiftyPullRequestsOpened() {
        var report = SessionReport(session: Self.session)
        report.setWorkingOn((1...25).map { ItemRef.workItem(organization: "contoso", id: $0) }, at: Self.now)
        #expect(report.workingOn.count == SessionReports.mostItems)
        #expect(report.workingOn.first == ItemRef.workItem(organization: "contoso", id: 1))
        for number in 1...60 {
            report.addOpened([ItemRef.pullRequest(organization: "contoso", number: number)], at: Self.now + Double(number))
        }
        report.addOpened([Self.task], at: Self.now)
        #expect(report.opened.count == SessionReports.mostOpened)
        #expect(report.opened[ItemRef.pullRequest(organization: "contoso", number: 60)] != nil)
        #expect(report.opened[ItemRef.pullRequest(organization: "contoso", number: 10)] == nil)
        #expect(report.opened[Self.task] == nil)
    }

    @Test func forgetsWhatsPastItsTime() {
        var report = SessionReport(session: Self.session)
        report.setWorkingOn([Self.task], at: Self.now - 8 * Self.day)
        report.addOpened([Self.pullRequest], at: Self.now - 31 * Self.day)
        report.addOpened([Self.another], at: Self.now - Self.day)
        report.expire(now: Self.now)
        #expect(report.workingOn.isEmpty)
        #expect(report.workingOnSince == nil)
        #expect(report.workingOnBegan.isEmpty)
        #expect(Array(report.opened.keys) == [Self.another])

        var recent = SessionReport(session: Self.session)
        recent.setWorkingOn([Self.task], at: Self.now - 6 * Self.day)
        recent.expire(now: Self.now)
        #expect(recent.workingOn == [Self.task])
    }

    /// When it began to say it works on each is kept while it goes on saying so, whatever else it tells, and starts again
    /// once it said it stopped: as saved, too.
    @Test func remembersWhenItBeganEachUntilItStops() throws {
        var report = SessionReport(session: Self.session)
        report.setWorkingOn([Self.task, Self.pullRequest], at: Self.now - 3_600)
        report.setWorkingOn([Self.pullRequest, Self.story], at: Self.now - 600)
        #expect(report.workingOnBegan == [Self.pullRequest: Self.now - 3_600, Self.story: Self.now - 600])
        #expect(report.workingOnSince == Self.now - 600)
        report.setWorkingOn([], at: Self.now - 300)
        #expect(report.workingOnBegan.isEmpty)
        report.setWorkingOn([Self.pullRequest, Self.gitHub], at: Self.now)
        #expect(report.workingOnBegan == [Self.pullRequest: Self.now, Self.gitHub: Self.now])
        report.forget([.gitHubPullRequest])
        #expect(report.workingOnBegan == [Self.pullRequest: Self.now])

        let defaults = MemorySettings()
        SessionReports.change(Self.session, in: defaults, now: Self.now - 3_600) { $0.setWorkingOn([Self.pullRequest], at: Self.now - 3_600) }
        SessionReports.change(Self.session, in: defaults, now: Self.now) { $0.setWorkingOn([Self.pullRequest, Self.task], at: Self.now) }
        let kept = try #require(SessionReports.load(Self.session, from: defaults))
        #expect(kept.workingOnBegan == [Self.pullRequest: Self.now - 3_600, Self.task: Self.now])
        #expect(SessionReports.load(from: defaults, now: Self.now)[Self.session] == kept)
    }

    /// What was kept before BriefBar kept when each began began, as far as it knows, when it last told it; and a date later
    /// than that, which no session told, isn't taken.
    @Test func takesWhatItLastToldAsWhenItBeganWhenThatWasntKept() throws {
        let defaults = MemorySettings()
        let since = Self.now.timeIntervalSinceReferenceDate - 600
        let record = """
            {"opened": {}, "session": "session//\(Self.session.id)", "since": \(since),
             "began": {"workItem/contoso/5124": \(since - 3_000), "pullRequest/contoso/4102": \(since + 60)},
             "workingOn": ["workItem/contoso/5124", "pullRequest/contoso/4102", "workItem/contoso/5101"]}
            """
        defaults.set(Data(record.utf8), forKey: SessionReports.key(for: Self.session))
        let report = try #require(SessionReports.load(Self.session, from: defaults))
        #expect(report.workingOnBegan == [Self.task: Self.now - 3_600, Self.pullRequest: Self.now - 600, Self.story: Self.now - 600])

        let old = """
            {"opened": {}, "session": "session//\(Self.other.id)", "since": \(since), "workingOn": ["workItem/contoso/5124"]}
            """
        defaults.set(Data(old.utf8), forKey: SessionReports.key(for: Self.other))
        #expect(SessionReports.load(Self.other, from: defaults)?.workingOnBegan == [Self.task: Self.now - 600])
    }

    // MARK: Saving

    @Test func keepsEachSessionUnderItsOwnKey() {
        let defaults = MemorySettings()
        SessionReports.change(Self.session, in: defaults, now: Self.now) { $0.setWorkingOn([Self.task], at: Self.now) }
        SessionReports.change(Self.other, in: defaults, now: Self.now) { $0.addOpened([Self.pullRequest], at: Self.now) }
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(SessionReports.keyPrefix) }.sorted()
        #expect(keys == [SessionReports.key(for: Self.session), SessionReports.key(for: Self.other)].sorted())

        let loaded = SessionReports.load(from: defaults, now: Self.now)
        #expect(loaded[Self.session]?.workingOn == [Self.task])
        #expect(loaded[Self.other]?.opened == [Self.pullRequest: Self.now])

        SessionReports.change(Self.session, in: defaults, now: Self.now) { $0.setWorkingOn([], at: Self.now) }
        #expect(defaults.object(forKey: SessionReports.key(for: Self.session)) == nil)
        #expect(SessionReports.load(from: defaults, now: Self.now).reports.keys.sorted() == [Self.other])
    }

    @Test func skipsWhatItCantRead() throws {
        let defaults = MemorySettings()
        defaults.set(Data("nonsense".utf8), forKey: SessionReports.keyPrefix + "nonsense")
        let record = """
            {"opened": {"pullRequest/contoso/4102": 0, "not a reference": 0}, "session": "session//\(Self.session.id)",
             "since": 0, "workingOn": ["workItem/contoso/5124", "workItem/con toso/1"]}
            """
        defaults.set(Data(record.utf8), forKey: SessionReports.key(for: Self.session))
        // Under another session's key: not that session's.
        defaults.set(Data(record.utf8), forKey: SessionReports.key(for: Self.other))
        let loaded = SessionReports.load(from: defaults, now: Date(timeIntervalSinceReferenceDate: 60))
        #expect(loaded.reports.keys.sorted() == [Self.session])
        let report = try #require(loaded[Self.session])
        #expect(report.workingOn == [Self.task])
        #expect(Array(report.opened.keys) == [Self.pullRequest])
    }

    @Test(.onTestThreads) func dropsTheSessionsThatToldLongestAgo() {
        let defaults = MemorySettings()
        for minute in 0..<SessionReports.mostSessions {
            let session = ItemRef.session(UUID().uuidString)!
            let date = Self.now - Double(SessionReports.mostSessions - minute) * 60
            SessionReports.change(session, in: defaults, now: date) { $0.setWorkingOn([Self.task], at: date) }
        }
        let oldest = SessionReports.load(from: defaults, now: Self.now).reports.values.min { ($0.lastTold ?? .now) < ($1.lastTold ?? .now) }
        SessionReports.change(Self.session, in: defaults, now: Self.now) { $0.setWorkingOn([Self.task], at: Self.now) }
        let kept = SessionReports.load(from: defaults, now: Self.now)
        #expect(kept.reports.count == SessionReports.mostSessions)
        #expect(kept[Self.session] != nil)
        #expect(oldest.map { kept[$0.session] == nil } == true)
    }

    @Test func forgetsASourcesThings() {
        let defaults = MemorySettings()
        SessionReports.change(Self.session, in: defaults, now: Self.now) {
            $0.setWorkingOn([Self.task, Self.gitHub], at: Self.now)
            $0.addOpened([Self.pullRequest], at: Self.now)
        }
        SessionReports.forget([.gitHubPullRequest], in: defaults, now: Self.now)
        #expect(SessionReports.load(Self.session, from: defaults)?.workingOn == [Self.task])
        SessionReports.forget([.workItem, .pullRequest], in: defaults, now: Self.now)
        #expect(SessionReports.load(Self.session, from: defaults) == nil)

        SessionReports.change(Self.other, in: defaults, now: Self.now) { $0.setWorkingOn([Self.story], at: Self.now) }
        RereadRequests.add([Self.task], id: "one", to: defaults, now: Self.now)
        defaults.set(true, forKey: SessionUpdatesSetting.defaultsKey)
        SessionReports.forgetAll(in: defaults)
        #expect(defaults.dictionaryRepresentation().keys.sorted() == [SessionUpdatesSetting.defaultsKey])
    }

    // MARK: What shows

    @Test func showsWhatListedSessionsToldUntilADayIdle() {
        var working = SessionReport(session: Self.session)
        working.setWorkingOn([Self.task], at: Self.now)
        working.addOpened([Self.pullRequest], at: Self.now)
        var unlisted = SessionReport(session: Self.other)
        unlisted.setWorkingOn([Self.story], at: Self.now)
        let reports = SessionReports([working, unlisted])

        let listing = SessionReports.Listing(sessions: [Self.session])
        #expect(reports.workingOn(listing, now: Self.now) == [Self.session: [Self.task]])
        #expect(reports.opened(listing, now: Self.now) == [Self.session: [Self.pullRequest]])
        #expect(reports.opened(listing, now: Self.now + 31 * Self.day).isEmpty)
        #expect(reports.workingOn(listing, now: Self.now + 8 * Self.day).isEmpty)
        #expect(Set(reports.links(listing, now: Self.now)) == [
            ItemLink(Self.session, Self.task, origin: .session)!, ItemLink(Self.session, Self.pullRequest, origin: .copilot)!,
        ])

        let idleAnHour = SessionReports.Listing(sessions: [Self.session], idleSince: [Self.session: Self.now - 3_600])
        #expect(reports.workingOn(idleAnHour, now: Self.now) == [Self.session: [Self.task]])
        let idleADay = SessionReports.Listing(sessions: [Self.session], idleSince: [Self.session: Self.now - Self.day])
        #expect(reports.workingOn(idleADay, now: Self.now).isEmpty)
        #expect(reports.links(idleADay, now: Self.now) == [ItemLink(Self.session, Self.pullRequest, origin: .copilot)!])
        #expect(reports.links(SessionReports.Listing(), now: Self.now).isEmpty)
    }

    @Test func aSessionsWorkReachesTheWorkItemsOfItsPullRequest() {
        let graph = LinkGraph(links: [
            ItemLink(Self.session, Self.pullRequest, origin: .session)!, ItemLink(Self.pullRequest, Self.task, origin: .azureDevOps)!,
        ])
        let connection = graph.connections(of: Self.task).first { $0.item == Self.session }
        #expect(connection?.via == Self.pullRequest)
        #expect(graph.origins(Self.session, Self.pullRequest) == [.session])
        #expect(LinkOrigin.copilot < .session && LinkOrigin.session < .branch)
    }

    // MARK: What to read again

    @Test func keepsWhatToReadAgainForTenMinutesAndTakesEachOnce() {
        let defaults = MemorySettings()
        RereadRequests.add([Self.task], id: "old", to: defaults, now: Self.now - 700)
        RereadRequests.add([Self.story], id: "new", to: defaults, now: Self.now - 120)
        RereadRequests.add([Self.pullRequest], id: "new", to: defaults, now: Self.now - 5)
        var (requests, taken) = RereadRequests.take(since: [:], from: defaults, now: Self.now)
        #expect(requests.map(\.ref) == [Self.story, Self.pullRequest])
        #expect(defaults.object(forKey: RereadRequests.keyPrefix + "old") == nil)
        #expect(RereadRequests.take(since: taken, from: defaults, now: Self.now).requests.isEmpty)

        // Saved after those were taken by a call that started before them, as two calls of one --mcp can: still taken.
        RereadRequests.add([Self.task], id: "new", to: defaults, now: Self.now - 60)
        (requests, taken) = RereadRequests.take(since: taken, from: defaults, now: Self.now)
        #expect(requests.map(\.ref) == [Self.task])
        // What's there as the app starts counts as taken.
        RereadRequests.add([Self.story], id: "another", to: defaults, now: Self.now)
        #expect(RereadRequests.take(since: RereadRequests.taken(in: defaults), from: defaults, now: Self.now).requests.isEmpty)

        let many = MemorySettings()
        RereadRequests.add((1...60).map { ItemRef.workItem(organization: "contoso", id: $0) }, id: "many", to: many, now: Self.now)
        let all = RereadRequests.take(since: [:], from: many, now: Self.now).requests
        #expect(all.count == RereadRequests.most)
        #expect(all.contains { $0.ref == ItemRef.workItem(organization: "contoso", id: 60) })
    }

    /// What's past its time goes from the preferences too, not only from what's read: a record that tells nothing more,
    /// and what's expired in another; one that can't be read stays.
    @Test func prunesWhatsPastItsTimeFromThePreferences() {
        let defaults = MemorySettings()
        let then = Self.now - 8 * Self.day
        SessionReports.change(Self.session, in: defaults, now: then) { $0.setWorkingOn([Self.task], at: then) }
        SessionReports.change(Self.other, in: defaults, now: then) {
            $0.setWorkingOn([Self.story], at: then)
            $0.addOpened([Self.pullRequest], at: then)
        }
        defaults.set(Data("nonsense".utf8), forKey: SessionReports.keyPrefix + "nonsense")
        SessionReports.prune(in: defaults, now: Self.now)
        #expect(defaults.object(forKey: SessionReports.key(for: Self.session)) == nil)
        let kept = SessionReports.load(Self.other, from: defaults)
        #expect(kept?.workingOn.isEmpty == true)
        #expect(kept?.opened == [Self.pullRequest: then])
        #expect(defaults.object(forKey: SessionReports.keyPrefix + "nonsense") != nil)
    }

    // MARK: What agents name

    @Test func readsWhatAgentsName() {
        let workItem: Set<ItemRef.Kind> = [.workItem]
        let pullRequest: Set<ItemRef.Kind> = [.pullRequest, .gitHubPullRequest]
        #expect(ItemRef.named("5124", as: workItem, organization: " Contoso ") == Self.task)
        #expect(ItemRef.named("#5124", as: workItem, organization: "contoso") == Self.task)
        #expect(ItemRef.named("!4102", as: pullRequest, organization: "contoso") == Self.pullRequest)
        #expect(ItemRef.named("4102", as: pullRequest, organization: nil) == nil)
        #expect(ItemRef.named("4102", as: pullRequest, organization: "con toso") == nil)
        #expect(ItemRef.named("https://dev.azure.com/contoso/Shop/_workitems/edit/5124", as: workItem, organization: nil) == Self.task)
        #expect(ItemRef.named("https://dev.azure.com/contoso/Shop/_apis/wit/workItems/5124?api-version=7.1", as: workItem, organization: nil) == Self.task)
        #expect(ItemRef.named("https://dev.azure.com/contoso/_apis/wit/workItems/5124", as: workItem, organization: nil) == Self.task)
        #expect(
            ItemRef.named("https://dev.azure.com/contoso/Shop/_apis/git/repositories/8c1f/pullRequests/4102", as: pullRequest, organization: nil)
                == Self.pullRequest
        )
        #expect(ItemRef.named("https://contoso.visualstudio.com/Shop/_apis/git/pullRequests/4102", as: pullRequest, organization: nil) == Self.pullRequest)
        #expect(ItemRef.named("https://github.com/octo/app/pull/12", as: pullRequest, organization: nil) == Self.gitHub)
        #expect(ItemRef.named("https://github.com/octo/app/pull/12", as: [.pullRequest], organization: nil) == nil)
        #expect(ItemRef.named("https://dev.azure.com/contoso/Shop/_workitems/edit/5124", as: pullRequest, organization: "contoso") == nil)
        #expect(ItemRef.from(link: "https://dev.azure.com/contoso/Shop/_apis/wit/workItems/5124/updates") == nil)
        #expect(ItemRef.from(link: "https://dev.azure.com/contoso/Shop/_apis/git/repositories/8c1f/pullRequests/4102/threads") == nil)
    }
}
