import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation
import Testing
@testable import AzureDevOpsUI

/// Fix with Copilot…, on notifications about your pull requests that say what Copilot can fix: comments, a failed build or
/// merge conflicts. It opens the composer, as the Actions menu does, while Copilot can still do that. With the made-up pull
/// requests and Copilot tasks: nothing here opens the composer's window, Azure DevOps or Notification Center.
@MainActor
@Suite struct FixWithCopilotTests {
    private let organization = DemoData.organization

    /// The demo, with what a notification opens shown in the window, once Priya commented on your !4091, as the demo has it
    /// a few seconds in: that's posted, while the rest was listed as the demo started.
    private func demo() throws -> (source: AzureDevOpsSource, services: AppServices) {
        let services = AppServices(defaults: MemoryDefaults(), isDemo: true)
        services.hasPage = { $0 == .azureDevOpsPullRequests }
        services.openWindow = { _ in }
        let source = AzureDevOpsSource(services: services, summarizer: .withoutModel)
        source.start()
        source.settings.opensPullRequestsInBriefBar = true
        try #require(source.store).receive(DemoData.update(DemoData.snapshot(now: Date()), at: Date()))
        return (source, services)
    }

    private func entry(_ number: Int, titled title: String, in services: AppServices) throws -> NotificationHistory.Entry {
        try #require(services.recentNotifications.history.entries.first {
            $0.userInfo["pullRequest"] == "\(organization)/\(number)" && $0.title.contains(title)
        })
    }

    /// As the Actions menu would offer it then: on your pull request, for what Copilot can fix, unless it's on it already.
    @Test func offeredWhereCopilotCanFixWhatItSays() throws {
        let (source, services) = try demo()
        defer { source.stop() }
        #expect(services.notifier.buttons.contains(PRStore.copilotButton))
        let comment = try entry(4091, titled: "Priya", in: services)
        #expect(comment.button == PRStore.copilotButton)
        #expect(comment.userInfo[PRStore.copilotActionKey] == PullRequestAction.fixComments.rawValue)
        // Your build failed, but the demo's Copilot is fixing it already.
        let build = try entry(4088, titled: "Build failed", in: services)
        #expect(build.button == nil && build.userInfo[PRStore.copilotActionKey] == nil)
        // Nothing else: Alex mentioned you on theirs, and yours that's ready has nothing to fix.
        #expect(services.recentNotifications.history.entries.filter { $0.button != nil }.count == 1)
        #expect(PRStore.copilotButton.title == "Fix with Copilot…")
    }

    @Test func opensTheComposerWhileCopilotCanStillFixIt() throws {
        let (source, services) = try demo()
        defer { source.stop() }
        var composed: [(action: PullRequestAction, number: Int)] = []
        source.composingFix = { composed.append(($0, $1.key.number)) }
        let details = try #require(source.pullRequestDetails)
        let comment = try entry(4091, titled: "Priya", in: services)
        let key = PRKey(organization, 4091)
        let commented = try #require(source.store?.record(for: key)?.details?.threads.first { $0.id == 63 }?.comments.last?.publishedAt)
        #expect(source.settings.seenCutoff(for: key) < commented)

        source.notificationButton(PRStore.copilotButton.id, userInfo: comment.userInfo)
        #expect(composed.map(\.action) == [.fixComments] && composed.map(\.number) == [4091])
        #expect(details.selected == nil)
        // Seen, as opening it would see it.
        #expect(source.settings.seenCutoff(for: key) >= commented)

        // Once Copilot can't, the notification opens, as a click on it does: here, in the window, at Priya's comment.
        source.settings.copilotEnabled = false
        source.notificationButton(PRStore.copilotButton.id, userInfo: comment.userInfo)
        #expect(composed.count == 1)
        #expect(details.selected?.key.number == 4091 && details.place == .thread(63))
    }

    /// By its pull request's key, in which an organization's name is the same in any letter case, as Azure DevOps has it:
    /// the list's pull request, though the notification spelled its organization otherwise.
    @Test func findsItsPullRequestInAnyLetterCase() throws {
        let (source, services) = try demo()
        defer { source.stop() }
        var composed: [(action: PullRequestAction, number: Int)] = []
        source.composingFix = { composed.append(($0, $1.key.number)) }
        var comment = try entry(4091, titled: "Priya", in: services).userInfo
        let spelled = "\(organization.uppercased())/4091"
        try #require(comment["pullRequest"] != spelled)
        comment["pullRequest"] = spelled

        source.notificationButton(PRStore.copilotButton.id, userInfo: comment)
        #expect(composed.map(\.action) == [.fixComments] && composed.map(\.number) == [4091])
    }

    /// Anything else opens the notification: Fix with Copilot… on what Copilot is fixing already, or another button.
    @Test func otherwiseOpensTheNotification() throws {
        let (source, services) = try demo()
        defer { source.stop() }
        var composed: [PullRequestAction] = []
        source.composingFix = { action, _ in composed.append(action) }
        let details = try #require(source.pullRequestDetails)

        var build = try entry(4088, titled: "Build failed", in: services).userInfo
        build[PRStore.copilotActionKey] = PullRequestAction.fixBuild.rawValue
        source.notificationButton(PRStore.copilotButton.id, userInfo: build)
        #expect(composed.isEmpty)
        #expect(details.selected?.key.number == 4088)

        source.notificationButton("somethingElse", userInfo: try entry(4091, titled: "Priya", in: services).userInfo)
        #expect(composed.isEmpty)
        #expect(details.selected?.key.number == 4091)
    }

    /// Clicked as the click started BriefBar: once the list has what it read the first time, or after a while without.
    @Test func waitsForTheListToBeRead() async throws {
        let store = PRStore(settings: AppSettings(defaults: MemoryDefaults()), summarizer: .withoutModel, mode: .demo)
        var listed: [Int] = []
        let waiting = store.onceLoaded(within: 60) { listed.append(store.items.count) }
        #expect(waiting != nil && listed.isEmpty)
        store.receive(DemoData.snapshot(now: Date()))
        try await until { !listed.isEmpty }
        #expect(listed.count == 1 && (listed.first ?? 0) > 0)
        store.receive(DemoData.snapshot(now: Date()))
        try await Task.sleep(for: .milliseconds(100))
        #expect(listed.count == 1)
        withExtendedLifetime(waiting) {}
        // Read already: at once.
        #expect(store.onceLoaded(within: 60) { listed.append(-1) } == nil)
        #expect(listed.last == -1)

        let unread = PRStore(settings: AppSettings(defaults: MemoryDefaults()), summarizer: .withoutModel, mode: .demo)
        var gaveUp = false
        let giving = unread.onceLoaded(within: 0) { gaveUp = true }
        try await until { gaveUp }
        withExtendedLifetime(giving) { #expect(gaveUp) }
    }

    /// Waits, a little at a time, until something is so: as long as a busy Mac may take, since it stops as soon as it is.
    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + waitLimit
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
