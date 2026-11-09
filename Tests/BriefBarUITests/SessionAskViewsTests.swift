import AppKit
import BriefBarCore
import SwiftUI
import Testing
@testable import BriefBarUI

/// A way to ask that never answers until it's stopped.
@MainActor
private func waiting(_ asks: SessionAsks) {
    asks.setAsker { _ in
        do {
            try await Task.sleep(for: .seconds(600))
        } catch {
            return .failure(SessionAsks.Problem("Stopped"))
        }
        return .success("Too late")
    }
}

/// Ask… in menus, as AppKit builds them from SwiftUI's menu content: a session's row's ⋯ and right-click menus, VoiceOver's
/// actions on the row, and ⌄ on a pull request's Copilot line.
@MainActor
@Suite(.serialized) struct SessionAskMenusTests {
    private let session = ItemRef.session("2f8a4c6e-1b3d-4e5f-8a7b-9c0d1e2f3a14")!

    /// A menu's items: each one's title, and "---" for a line between them.
    private func items(of menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "---" : $0.title }
    }

    private func menu(_ content: some View, _ services: AppServices) -> NSMenu {
        _ = NSApplication.shared
        let menu = NSHostingMenu(rootView: content.environmentObject(services))
        menu.update()
        return menu
    }

    /// ⌄ on a pull request's Copilot line, beside Show Details, as `PullRequestSessionLine` has it.
    private func line(_ services: AppServices) -> NSMenu {
        menu(Group {
            Button("Show Details") {}
            SessionAskPageItem(session) {}
        }, services)
    }

    /// While a session is asked, ⌄ has Stop Asking, as its row's menus do, rather than Ask…, whose field would stop that
    /// question for another; Ask… before, and Ask More… once it answered.
    @Test func copilotLineStopsAskingWhileTheSessionIsAsked() async throws {
        let services = AppServices(defaults: MemoryDefaults(), isDemo: false)
        let asks = services.sessionAsks
        waiting(asks)
        defer { asks.setAsker(nil) }
        #expect(items(of: line(services)) == ["Show Details", "Ask…"])

        asks.ask(session, question: "Why 30 s?")
        #expect(items(of: menu(SessionAskMenuItems(session), services)) == ["---", "Stop Asking", "---"])
        let asking = line(services)
        #expect(items(of: asking) == ["Show Details", "Stop Asking"])
        asking.performActionForItem(at: 1)
        try await until("the question to stop") { asks.question(for: session) == nil }

        asks.useForRendering(session, question: SessionAsks.Question(
            asked: "Why 30 s?", askedAt: Date().addingTimeInterval(-30), state: .answered("It's the cap."), endedAt: Date()
        ))
        #expect(items(of: line(services)) == ["Show Details", "Ask More…"])
    }

    /// A session whose Ask… and summary both couldn't be written, as when you're out of premium requests: its menus, and
    /// VoiceOver's actions, which have no lines between them, tell trying each again apart.
    @Test func rowMenusTellTryingAskingAgainFromASummarysTryAgain() {
        let defaults = MemoryDefaults()
        defaults.set(true, forKey: StorySummaries.enabledKey)
        let services = AppServices(defaults: defaults, isDemo: false)
        services.links.setOn(true)
        services.links.publish(.copilot, links: [], items: [
            LinkedItem(ref: session, label: "Retry backoff", title: "Retry backoff", symbol: "waveform.path.ecg", color: .secondary),
        ])
        let outOfRequests = "You're out of premium requests this month."
        services.summaries.useForRendering(session, state: .failed(StorySummaries.Problem(outOfRequests), at: Date()))
        waiting(services.sessionAsks)
        defer { services.sessionAsks.setAsker(nil) }
        services.sessionAsks.useForRendering(session, question: SessionAsks.Question(
            asked: nil, askedAt: Date().addingTimeInterval(-30), state: .failed(SessionAsks.Problem(outOfRequests)), endedAt: Date()
        ))

        // VoiceOver's actions on the row, as `SessionRowView` has them.
        let spoken = menu(Group {
            SessionAskMenuItems(session, divided: false)
            SummarizeMenuItems(session, divided: false)
        }, services)
        #expect(items(of: spoken) == ["Try Asking Again", "Ask…", "Try Again", "Close Summary"])
        let row = menu(Group {
            SessionAskMenuItems(session)
            SummarizeMenuItems(session)
        }, services)
        #expect(items(of: row).filter { $0.hasPrefix("Try") } == ["Try Asking Again", "Try Again"])
    }
}

/// What a Copilot session's page offers of Ask…, as `ItemPageView` draws it: Ask… while a source says what the session is,
/// and ↗ on its answer opening the session itself, where its source says, as its tooltip says. SwiftUI makes no
/// accessibility elements to find while no assistive app runs, so these are what the page draws them from.
@MainActor
@Suite struct SessionAskPageTests {
    private let session = ItemRef.session("5e2a9c41-7d3b-4f86-b0e1-9c4d2a7f3e21")!

    private final class Opened {
        var what: [String] = []
    }

    /// Of a session whose question the session coordinating it asks you, opening it opens that one; ↗ on its answer opens
    /// it itself, where its source says, as its tooltip says.
    @Test func answersOpenerOpensTheSessionItself() throws {
        let opened = Opened()
        let item = LinkedItem(
            ref: session, label: "Pick colors", title: "Pick colors", symbol: "waveform.path.ecg", color: .secondary,
            open: { opened.what.append("the session that asks its question") },
            openItself: ({ opened.what.append("itself") }, "Opens the session in Terminal")
        )
        let opener = try #require(ItemPageView.answerOpener(of: item))
        #expect(opener.help == "Opens the session in Terminal")
        opener.perform()
        #expect(opened.what == ["itself"])

        // Where opening it always opens it itself.
        var plain = item
        plain.openItself = nil
        let fallback = try #require(ItemPageView.answerOpener(of: plain))
        #expect(fallback.help == "Opens the session")
        fallback.perform()
        #expect(opened.what == ["itself", "the session that asks its question"])

        // A task BriefBar sent has none: its page opens what it's for.
        var task = item
        task.sent = SentToCopilot(action: "Fix Comments", from: .pullRequest(organization: "contoso", number: 4071), label: "!4071")
        #expect(ItemPageView.answerOpener(of: task) == nil)
    }

    /// Once no source says what the session is, as with GitHub Copilot turned off while its page is open, the page offers
    /// no Ask…; nor does a page of something else.
    @Test func offersAskOnlyWhileASourceSaysWhatTheSessionIs() {
        let services = AppServices(defaults: MemoryDefaults(), isDemo: false)
        services.links.setOn(true)
        let workItem = ItemRef.workItem(organization: "contoso", id: 5112)
        services.links.publish(.copilot, links: [], items: [
            LinkedItem(ref: session, label: "Pick colors", title: "Pick colors", symbol: "waveform.path.ecg", color: .secondary),
        ])
        services.links.publish(.azureDevOps, links: [], items: [
            LinkedItem(ref: workItem, label: "5112", title: "Save items for later", symbol: "doc.text", color: .secondary),
        ])
        #expect(ItemPageView.offersAsk(on: session, links: services.links))
        #expect(!ItemPageView.offersAsk(on: workItem, links: services.links))
        services.links.withdraw(.copilot)
        #expect(!ItemPageView.offersAsk(on: session, links: services.links))
    }
}
