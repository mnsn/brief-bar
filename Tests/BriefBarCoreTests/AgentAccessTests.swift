import Foundation
import Testing
@testable import BriefBarCore

/// Agents may use BriefBar only once you let them, having seen what they get, and wait again when they get more.
@Suite struct AgentAccessTests {
    @Test func offUntilYouTurnThemOn() {
        let settings = MemorySettings()
        #expect(AgentAccess.state(in: settings) == .off)
        #expect(AgentAccess.refusal(.off)?.contains("Turn them on in BriefBar's Settings, under Agents") == true)

        AgentAccess.turnOn(in: settings)
        #expect(AgentAccess.state(in: settings) == .on)
        #expect(AgentAccess.refusal(.on) == nil)

        AgentAccess.turnOff(in: settings)
        #expect(AgentAccess.state(in: settings) == .off)
        #expect(settings.data(forKey: AgentAccess.defaultsKey) == nil)
    }

    @Test func waitWhenTheyGetMore() {
        let settings = MemorySettings()
        AgentAccess.turnOn(in: settings, version: 1)
        #expect(AgentAccess.state(in: settings, version: 1) == .on)
        #expect(AgentAccess.state(in: settings, version: 2) == .needsReview)
        #expect(AgentAccess.refusal(.needsReview)?.contains("an update gave them more") == true)
        AgentAccess.turnOn(in: settings, version: 2)
        #expect(AgentAccess.state(in: settings, version: 2) == .on)
    }

    @Test func somethingElseSavedThereIsOff() {
        let settings = MemorySettings()
        settings.set(Data("true".utf8), forKey: AgentAccess.defaultsKey)
        #expect(AgentAccess.state(in: settings) == .off)
        settings.set(true, forKey: AgentAccess.defaultsKey)
        #expect(AgentAccess.state(in: settings) == .off)
    }
}
