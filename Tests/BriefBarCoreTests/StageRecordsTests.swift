import Foundation
import Testing
@testable import BriefBarCore

/// The stages you set, as BriefBar keeps them: for each account, only yours and only what can be set, as references and
/// dates; refused rather than dropped at the cap; noted once a day as lists have them; and forgotten as they should be.
@Suite struct StageRecordsTests {
    static func pr(_ number: Int) -> ItemRef { OrderPlansTests.pr(number) }

    @Test func eachAccountKeepsItsOwn() {
        var marks = StageMarks()
        let contoso = marks.set(StageMark(stage: .yourReview, at: t(10)), of: Self.pr(4093), for: "Robin@Contoso.com", at: t(10))
        let fabrikam = marks.set(StageMark(stage: .teammateReview, at: t(20)), of: Self.pr(4093), for: "robin@fabrikam.com", at: t(20))
        #expect(contoso && fabrikam)
        #expect(marks.mark(of: Self.pr(4093), for: "robin@contoso.com")?.stage == .yourReview)
        #expect(marks.mark(of: Self.pr(4093), for: "ROBIN@FABRIKAM.COM")?.stage == .teammateReview)
        #expect(marks.mark(of: Self.pr(4093), for: "sam@contoso.com") == nil)

        let cleared = marks.clear(Self.pr(4093), for: "robin@contoso.com")
        let clearedAgain = marks.clear(Self.pr(4093), for: "robin@contoso.com")
        #expect(cleared && !clearedAgain)
        #expect(marks.accounts.keys.sorted() == ["robin@fabrikam.com"])
    }

    @Test func itKeepsOnlyYoursOnlyWhatCanBeSetAndOnlyPullRequests() {
        var marks = StageMarks()
        let canMerge = marks.set(StageMark(stage: .canMerge, at: t(10)), of: Self.pr(1), for: "robin", at: t(10))
        let session = ItemRef.session("7c1e2a90-4b3d-4f5e-8a6b-1c2d3e4f5a6b")!
        let sessions = marks.set(StageMark(stage: .yourReview, at: t(10), by: session), of: Self.pr(1), for: "robin", at: t(10))
        let workItem = marks.set(
            StageMark(stage: .yourReview, at: t(10)), of: .workItem(organization: "contoso", id: 5101), for: "robin", at: t(10)
        )
        #expect(!canMerge && !sessions && !workItem)
        #expect(marks.isEmpty)
    }

    @Test func atTheMostANewOneIsRefusedAndNoneDropped() {
        var marks = StageMarks()
        var kept = 0
        for number in 1...StageMarks.mostPerAccount {
            if marks.set(StageMark(stage: .yourReview, at: t(Double(number))), of: Self.pr(number), for: "robin", at: t(0)) {
                kept += 1
            }
        }
        #expect(kept == StageMarks.mostPerAccount)
        let oneMore = marks.set(StageMark(stage: .yourReview, at: t(1_000)), of: Self.pr(9_999), for: "robin", at: t(0))
        #expect(!oneMore)
        #expect(marks.accounts["robin"]?.count == StageMarks.mostPerAccount)

        // One it has can change, and another account has its own room.
        let changed = marks.set(StageMark(stage: .inProgress, at: t(1_000)), of: Self.pr(1), for: "robin", at: t(0))
        let samsFirst = marks.set(StageMark(stage: .yourReview, at: t(1_000)), of: Self.pr(9_999), for: "sam", at: t(0))
        #expect(changed && samsFirst)
        #expect(marks.mark(of: Self.pr(1), for: "robin")?.stage == .inProgress)
    }

    @Test func listsHavingThemIsNotedOnceADayAndUnlistedOnesGoAfter30Days() {
        var marks = StageMarks()
        _ = marks.set(StageMark(stage: .yourReview, at: t(0)), of: Self.pr(4093), for: "robin", at: t(0))
        _ = marks.set(StageMark(stage: .yourReview, at: t(0)), of: Self.pr(4094), for: "robin", at: t(0))
        let day: TimeInterval = 86_400

        let halfADay = marks.listed([Self.pr(4093)], for: "robin", at: t(day / 2))
        let aDay = marks.listed([Self.pr(4093)], for: "robin", at: t(day))
        let anotherAccount = marks.listed([Self.pr(4093)], for: "sam", at: t(day * 2))
        #expect(!halfADay && aDay && !anotherAccount)
        #expect(marks.accounts["robin"]?[Self.pr(4093)]?.listedAt == t(day))

        // 30 days after a list last had it, and not before; and only of the kinds whose sources have listed since.
        let after30Days = marks.forgetUnlisted(now: t(day * 30), of: [.pullRequest])
        let ofOtherKinds = marks.forgetUnlisted(now: t(day * 30 + 1), of: [.gitHubPullRequest, .session])
        let afterMore = marks.forgetUnlisted(now: t(day * 30 + 1), of: [.pullRequest])
        #expect(!after30Days && !ofOtherKinds && afterMore)
        #expect(marks.mark(of: Self.pr(4094), for: "robin") == nil)
        #expect(marks.mark(of: Self.pr(4093), for: "robin") != nil)
    }

    @Test func turningASourceOffForgetsItsOwnWithEveryAccount() {
        var marks = StageMarks()
        _ = marks.set(StageMark(stage: .yourReview, at: t(0)), of: Self.pr(4093), for: "robin", at: t(0))
        _ = marks.set(StageMark(stage: .yourReview, at: t(0)), of: Self.pr(4093), for: "sam", at: t(0))
        let gitHub = marks.forget([.gitHubPullRequest])
        let azureDevOps = marks.forget([.pullRequest])
        #expect(!gitHub && azureDevOps)
        #expect(marks.isEmpty)
        #expect(marks.accounts.isEmpty)
    }

    @Test func itsKeptAsReferencesAndDatesAndWhatCantBeReadDropsAlone() throws {
        let defaults = MemorySettings()
        var marks = StageMarks()
        let mark = StageMark(stage: .teammateReview, at: t(10), votes: "0,10", commit: "a1b2c3d")
        _ = marks.set(mark, of: Self.pr(4093), for: "robin@contoso.com", at: t(20))
        marks.save(to: defaults)

        let data = try #require(defaults.data(forKey: StageMarks.defaultsKey))
        let saved = try #require(String(data: data, encoding: .utf8))
        #expect(saved.contains("\"pullRequest\":\"pullRequest/contoso/4093\""))
        #expect(saved.contains("\"stage\":\"teammateReview\""))
        #expect(!saved.localizedCaseInsensitiveContains("title"))
        #expect(StageMarks.load(from: defaults) == marks)

        // One a later version wrote, with a stage this one doesn't know, drops alone.
        var records = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        var later = records[0]
        later["stage"] = "waitingForDesign"
        later["pullRequest"] = "pullRequest/contoso/4094"
        records.append(later)
        defaults.set(try JSONSerialization.data(withJSONObject: records), forKey: StageMarks.defaultsKey)
        #expect(StageMarks.load(from: defaults) == marks)

        StageMarks().save(to: defaults)
        #expect(defaults.data(forKey: StageMarks.defaultsKey) == nil)
        marks.save(to: defaults)
        StageMarks.forgetAll(in: defaults)
        #expect(defaults.object(forKey: StageMarks.defaultsKey) == nil)
    }

    // MARK: How far each of yours got

    /// For each account, only Your review, Teammate's review, Approved and Can merge, of pull requests alone: In progress,
    /// or none, forgets it.
    @Test func howFarOneGotIsKeptForEachAccountOnlyFromYourReviewOn() {
        var reached = StagesReached()
        let approved = reached.set(.approved, of: Self.pr(4088), for: "Robin@Contoso.com", at: t(0))
        let same = reached.set(.approved, of: Self.pr(4088), for: "robin@contoso.com", at: t(10))
        #expect(approved && !same)
        #expect(reached.reach(of: Self.pr(4088), for: "ROBIN@contoso.com", at: t(10)) == StageReach(.approved, since: t(0), isFirst: true))
        // Moved since, it's no longer where BriefBar first kept it.
        _ = reached.set(.canMerge, of: Self.pr(4088), for: "robin@contoso.com", at: t(5))
        _ = reached.set(.approved, of: Self.pr(4088), for: "robin@contoso.com", at: t(6))
        #expect(reached.reach(of: Self.pr(4088), for: "robin@contoso.com", at: t(10)) == StageReach(.approved, since: t(6)))
        #expect(reached.reach(of: Self.pr(4088), for: "sam@contoso.com", at: t(10)) == nil)

        let inProgress = reached.set(.inProgress, of: Self.pr(4090), for: "robin", at: t(0))
        let workItem = reached.set(.yourReview, of: .workItem(organization: "contoso", id: 5101), for: "robin", at: t(0))
        #expect(!inProgress && !workItem)
        #expect(reached.count(for: "robin") == 0)

        let backToInProgress = reached.set(.inProgress, of: Self.pr(4088), for: "robin@contoso.com", at: t(20))
        #expect(backToInProgress && reached.isEmpty)
        #expect(StagesReached(accounts: ["robin": [Self.pr(1): .init(stage: .waits, since: t(0), listedAt: t(0))]]).isEmpty)
    }

    /// Where BriefBar first kept one is only where it first saw it before it knew of a session writing it, and only for ten
    /// minutes: kept with such a session known, or once one is, it's how far it got, as any.
    @Test func whereBriefBarFirstSawOneLastsUntilItKnowsItsSessionsForMinutesAtMost() {
        var reached = StagesReached()
        _ = reached.set(.teammateReview, of: Self.pr(4093), for: "robin", at: t(0))
        #expect(reached.reach(of: Self.pr(4093), for: "robin", at: t(599))?.isFirst == true)
        #expect(reached.reach(of: Self.pr(4093), for: "robin", at: t(600)) == StageReach(.teammateReview, since: t(0)))
        #expect(reached.accounts["robin"]?[Self.pr(4093)]?.isFirst == true)
        let known = reached.set(.teammateReview, of: Self.pr(4093), for: "robin", at: t(60), knowsSessions: true)
        let again = reached.set(.teammateReview, of: Self.pr(4093), for: "robin", at: t(70), knowsSessions: true)
        #expect(known && !again)
        #expect(reached.reach(of: Self.pr(4093), for: "robin", at: t(60)) == StageReach(.teammateReview, since: t(0)))

        _ = reached.set(.teammateReview, of: Self.pr(4094), for: "robin", at: t(0), knowsSessions: true)
        #expect(reached.reach(of: Self.pr(4094), for: "robin", at: t(0)) == StageReach(.teammateReview, since: t(0)))
    }

    /// At the most, a new one isn't kept, and none is dropped; it's noted once a day as lists have it, and goes 30 days
    /// after the last, or with its source.
    @Test func howFarOneGotGoesAsAStageYouSetDoes() {
        var reached = StagesReached()
        for number in 1...StagesReached.mostPerAccount {
            _ = reached.set(.teammateReview, of: Self.pr(number), for: "robin", at: t(0))
        }
        let oneMore = reached.set(.teammateReview, of: Self.pr(9_999), for: "robin", at: t(0))
        let changed = reached.set(.approved, of: Self.pr(1), for: "robin", at: t(0))
        #expect(!oneMore && changed)
        #expect(reached.count(for: "robin") == StagesReached.mostPerAccount)

        let day: TimeInterval = 86_400
        let halfADay = reached.listed([Self.pr(1)], for: "robin", at: t(day / 2))
        let aDay = reached.listed([Self.pr(1)], for: "robin", at: t(day))
        #expect(!halfADay && aDay)
        let unlisted = reached.forgetUnlisted(now: t(day * 30 + 1), of: [.pullRequest])
        #expect(unlisted)
        #expect(reached.reach(of: Self.pr(1), for: "robin", at: t(0))?.stage == .approved)
        #expect(reached.reach(of: Self.pr(2), for: "robin", at: t(0)) == nil)
        let gitHub = reached.forget([.gitHubPullRequest])
        let azureDevOps = reached.forget([.pullRequest])
        #expect(!gitHub && azureDevOps && reached.isEmpty)
    }

    /// Kept as references, stages and dates alone; one a later version wrote, with a stage this one doesn't know, drops
    /// alone; none removes the key.
    @Test func howFarOneGotIsKeptAsReferencesStagesAndDates() throws {
        let defaults = MemorySettings()
        var reached = StagesReached()
        _ = reached.set(.approved, of: Self.pr(4088), for: "robin@contoso.com", at: t(20))
        reached.save(to: defaults)

        let data = try #require(defaults.data(forKey: StagesReached.defaultsKey))
        let saved = try #require(String(data: data, encoding: .utf8))
        #expect(saved.contains("\"pullRequest\":\"pullRequest/contoso/4088\""))
        #expect(saved.contains("\"stage\":\"approved\""))
        #expect(StagesReached.load(from: defaults) == reached)

        var records = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        var later = records[0]
        later["stage"] = "waitingForDesign"
        later["pullRequest"] = "pullRequest/contoso/4094"
        records.append(later)
        defaults.set(try JSONSerialization.data(withJSONObject: records), forKey: StagesReached.defaultsKey)
        #expect(StagesReached.load(from: defaults) == reached)

        StagesReached().save(to: defaults)
        #expect(defaults.data(forKey: StagesReached.defaultsKey) == nil)
        reached.save(to: defaults)
        StagesReached.forgetAll(in: defaults)
        #expect(defaults.object(forKey: StagesReached.defaultsKey) == nil)
    }
}
