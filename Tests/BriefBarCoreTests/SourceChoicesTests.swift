import Foundation
import Testing
@testable import BriefBarCore

@Suite struct SourceChoicesTests {
    private func freshDefaults() -> UserDefaults {
        let name = "BriefBarTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func nothingIsOnAtFirst() {
        let choices = SourceChoices.load(from: freshDefaults())
        for source in SourceID.allCases {
            #expect(choices.state(of: source, version: 1) == .off)
        }
    }

    @Test func aSourceIsOnOnlyAfterItsTurnedOn() {
        var choices = SourceChoices()
        choices.turnOn(.copilot, version: 1, at: t(0))
        #expect(choices.state(of: .copilot, version: 1) == .on)
        #expect(choices.state(of: .teams, version: 1) == .off)
        #expect(choices.state(of: .azureDevOps, version: 1) == .off)
        choices.turnOff(.copilot)
        #expect(choices.state(of: .copilot, version: 1) == .off)
    }

    @Test func aSourceThatReadsMoreWaitsUntilYouveSeenIt() {
        var choices = SourceChoices()
        choices.turnOn(.teams, version: 1, at: t(0))
        #expect(choices.state(of: .teams, version: 2) == .needsReview)
        choices.turnOn(.teams, version: 2, at: t(60))
        #expect(choices.state(of: .teams, version: 2) == .on)
        // An older version of the description, after a downgrade, is covered by the newer consent.
        #expect(choices.state(of: .teams, version: 1) == .on)
    }

    @Test func roundTripsThroughThePreferences() {
        let defaults = freshDefaults()
        var choices = SourceChoices()
        choices.turnOn(.azureDevOps, version: 3, at: t(0))
        choices.save(to: defaults)
        #expect(SourceChoices.load(from: defaults) == choices)
    }

    @Test func somethingUnreadableTurnsNothingOn() {
        let defaults = freshDefaults()
        defaults.set(Data("{\"teams\":{\"version\":\"one\"}}".utf8), forKey: SourceChoices.defaultsKey)
        #expect(SourceChoices.load(from: defaults) == SourceChoices())
        defaults.set("teams", forKey: SourceChoices.defaultsKey)
        #expect(SourceChoices.load(from: defaults) == SourceChoices())
        defaults.set(true, forKey: SourceChoices.defaultsKey)
        #expect(SourceChoices.load(from: defaults) == SourceChoices())
    }

    @Test func keepsButIgnoresSourcesThisVersionDoesntKnow() throws {
        let defaults = freshDefaults()
        let date = iso(t(0))
        let saved = """
            {"consents":{"outlook":{"version":1,"date":"\(date)"},"copilot":{"version":1,"date":"\(date)"}}}
            """
        // Dates are encoded the way JSONEncoder does by default: seconds since 2001.
        let encoded = try JSONEncoder().encode(SourceConsent(version: 1, date: t(0)))
        let consent = try #require(String(data: encoded, encoding: .utf8))
        let json = saved.replacingOccurrences(of: "{\"version\":1,\"date\":\"\(date)\"}", with: consent)
        defaults.set(Data(json.utf8), forKey: SourceChoices.defaultsKey)

        var choices = SourceChoices.load(from: defaults)
        #expect(choices.state(of: .copilot, version: 1) == .on)
        #expect(SourceID.allCases.filter { choices.state(of: $0, version: 1) == .on } == [.copilot])
        choices.turnOff(.copilot)
        choices.save(to: defaults)
        #expect(SourceChoices.load(from: defaults).consents.keys.sorted() == ["outlook"])
    }

    @Test func sectionsKnowTheirSource() {
        #expect(SectionID.teamsChats.source == .teams)
        #expect(SectionID.teamsGroupChats.source == .teams)
        #expect(SectionID.azureDevOpsPullRequests.source == .azureDevOps)
        #expect(SectionID.copilotSessions.source == .copilot)
        #expect(SectionID(rawValue: "outlook.mail").source == nil)
    }
}
