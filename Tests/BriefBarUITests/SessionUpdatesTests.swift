import BriefBarCore
import Combine
import Foundation
import SwiftUI
import Testing
@testable import BriefBarUI

/// The app's side of Updates from Copilot Sessions: what it reads of what sessions told, and passes on to read again.
@MainActor
@Suite struct SessionUpdatesTests {
    private static let now = Date(timeIntervalSince1970: 1_791_979_200)
    private static let session = ItemRef.session("6f9619ff-8b86-d011-b42d-00c04fc964ff")!
    private static let task = ItemRef.workItem(organization: "contoso", id: 5124)
    private static let pullRequest = ItemRef.pullRequest(organization: "contoso", number: 4102)
    private static let gitHub = ItemRef.gitHubPullRequest(repository: "octo/app", number: 12)

    private static func tell(_ defaults: MemoryDefaults, at date: Date = now) {
        SessionReports.change(session, in: defaults, now: date) {
            $0.setWorkingOn([task, gitHub], at: date)
            $0.addOpened([pullRequest], at: date)
        }
    }

    @Test func offItReadsNothingAndTurningItOnOrOffForgetsWhatWasTold() {
        let defaults = MemoryDefaults()
        Self.tell(defaults)
        let updates = SessionUpdates(defaults: defaults, isDemo: false, now: { Self.now })
        #expect(!updates.isOn)
        #expect(updates.reports.isEmpty)

        updates.setOn(true)
        #expect(SessionUpdatesSetting.isOn(in: defaults))
        #expect(updates.reports.isEmpty)
        #expect(SessionReports.load(from: defaults, now: Self.now).isEmpty)

        Self.tell(defaults)
        updates.agentChanged()
        #expect(updates.reports[Self.session]?.workingOn == [Self.task, Self.gitHub])

        updates.setOn(false)
        #expect(updates.reports.isEmpty)
        #expect(SessionReports.load(from: defaults, now: Self.now).isEmpty)
    }

    @Test func itReadsWhatSessionsToldAsItStarts() {
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: SessionUpdatesSetting.defaultsKey)
        Self.tell(defaults)
        let updates = SessionUpdates(defaults: defaults, isDemo: false, now: { Self.now })
        #expect(updates.reports[Self.session]?.opened == [Self.pullRequest: Self.now])
    }

    @Test func itPassesOnWhatToReadAgainOnceAndNothingFromBeforeItStarted() {
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: SessionUpdatesSetting.defaultsKey)
        var clock = Self.now
        RereadRequests.add([Self.task], id: "before", to: defaults, now: clock - 30)
        let updates = SessionUpdates(defaults: defaults, isDemo: false, now: { clock })
        var passed: [[ItemRef]] = []
        let subscription = updates.rereads.sink { passed.append($0) }
        defer { subscription.cancel() }

        clock += 5
        RereadRequests.add([Self.pullRequest, Self.task, Self.pullRequest], id: "this", to: defaults, now: clock)
        updates.agentChanged()
        updates.agentChanged()
        #expect(passed == [[Self.task, Self.pullRequest]])

        clock += 5
        RereadRequests.add([Self.gitHub], id: "other", to: defaults, now: clock)
        updates.agentChanged()
        #expect(passed.last == [Self.gitHub])
    }

    @Test func turningASourceOffForgetsItsThings() {
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: SessionUpdatesSetting.defaultsKey)
        let updates = SessionUpdates(defaults: defaults, isDemo: false, now: { Self.now })
        Self.tell(defaults)
        updates.agentChanged()

        updates.forget(.github)
        #expect(updates.reports[Self.session]?.workingOn == [Self.task])
        updates.forget(.copilot)
        #expect(updates.reports.isEmpty)
        #expect(SessionReports.load(from: defaults, now: Self.now).isEmpty)
    }

    @Test func pullRequestOrderKeepsWhatSessionsWorkOnWithoutChangingMissions() {
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: PullRequestOrderSetting.defaultsKey)
        let order = PullRequestOrder(defaults: defaults, isDemo: false)
        let other = ItemRef.session("a3d9c5e1-7b2f-4e84-9c16-5f8e2d0b7a11")!
        order.publish(.copilot, working: [Self.session: [Self.task, Self.pullRequest], other: [Self.pullRequest]])
        #expect(order.missions.isEmpty)
        #expect(order.workingOn(Self.session) == [Self.task, Self.pullRequest])
        #expect(order.sessionsWorking(on: Self.pullRequest) == [Self.session, other].sorted())
        order.withdraw(.copilot)
        #expect(order.workingOn(Self.session).isEmpty)
    }

    /// At a session's lane on the Map: what it works on, in its capsule's word.
    @Test func theMapSaysWhatALanesSessionWorksOn() {
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: PullRequestOrderSetting.defaultsKey)
        let order = PullRequestOrder(defaults: defaults, isDemo: false)
        func describe(_ state: ItemState?) -> LinkedItem {
            LinkedItem(ref: Self.session, label: "Retry backoff", title: "Retry backoff", symbol: "circle", color: .blue, state: state)
        }
        #expect(OrderMapGrid.working(of: Self.session, order: order) == nil)

        order.publish(.copilot, items: [describe(.running)], working: [Self.session: [Self.task, Self.pullRequest]])
        #expect(OrderMapGrid.working(of: Self.session, order: order)?.text == "Working on 5124 and !4102")
        order.publish(.copilot, items: [describe(.needsYou)], working: [Self.session: [Self.task, Self.pullRequest, Self.gitHub]])
        #expect(OrderMapGrid.working(of: Self.session, order: order)?.text == "Needs you · on 5124 and 2 more")
        order.publish(.copilot, items: [describe(nil)], working: [Self.session: [Self.gitHub]])
        #expect(OrderMapGrid.working(of: Self.session, order: order)?.text == "On #12")
    }
}
