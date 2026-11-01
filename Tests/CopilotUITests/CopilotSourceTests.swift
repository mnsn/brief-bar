import BriefBarCore
import BriefBarUI
import CopilotCore
import Foundation
import Testing
@testable import CopilotUI

@MainActor
@Suite struct CopilotSourceTests {
    /// As Summarize with Copilot writes a summary, Copilot reads what was asked in each session it sums up and what Copilot
    /// answered, from the session's log, the app's sessions' and the tasks' that Azure DevOps sent alike: nothing before
    /// the source starts, for a session where nothing was said, or while Show Links is off.
    @Test func readsWhatWasSaidInASessionForASummary() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BriefBarCopilotSource-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let paths = CopilotPaths(root: folder.resolvingSymlinksInPath())
        let id = "c3e8f1a2-6b4d-4e97-a1c5-2f7d9b0e8a11"
        try FileManager.default.createDirectory(at: paths.sessionDirectory(id), withIntermediateDirectories: true)
        try """
            {"type":"session.start","data":{"producer":"copilot-agent"},"id":"1","timestamp":"2026-10-18T10:00:00.000Z","parentId":null}
            {"type":"user.message","data":{"content":"Save items for later."},"id":"2","timestamp":"2026-10-18T10:00:01.000Z","parentId":null}
            {"type":"assistant.message","data":{"content":"Reading the cart.","toolRequests":[{"toolCallId":"c1","name":"view"}]},"id":"3","timestamp":"2026-10-18T10:00:02.000Z","parentId":null}
            {"type":"assistant.message","data":{"content":"Added a **Save for later** button.","toolRequests":[]},"id":"4","timestamp":"2026-10-18T10:00:03.000Z","parentId":null}

            """.write(to: paths.eventsFile(id), atomically: true, encoding: .utf8)

        let services = AppServices(defaults: MemoryDefaults(), isDemo: true)
        let source = CopilotSource(services: services, paths: paths)
        let session = try #require(ItemRef.session(id))
        #expect(await services.stories.context(for: [session]).isEmpty)

        source.tellStories()
        #expect(await services.stories.context(for: [session]) == [
            session: [ItemStory.Fact("Conversation", "You: Save items for later.\nCopilot: Added a Save for later button.")],
        ])
        let quiet = try #require(ItemRef.session("1d6b2c7e-4f0a-4b8e-9c31-5a2e7d8f6b01"))
        #expect(await services.stories.context(for: [quiet]).isEmpty)

        services.links.setOn(false)
        #expect(await services.stories.context(for: [session]).isEmpty)
    }
}
