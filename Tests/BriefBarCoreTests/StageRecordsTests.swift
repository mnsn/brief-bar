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
}
