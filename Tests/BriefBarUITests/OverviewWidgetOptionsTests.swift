import BriefBarCore
import Foundation
import Testing
@testable import BriefBarUI

@Suite struct OverviewWidgetOptionsTests {
    @Test func startsHiddenAndKeepsWhatYouChose() {
        let defaults = MemorySettings()
        #expect(OverviewWidgetOptions.load(from: defaults) == OverviewWidgetOptions())
        #expect(!OverviewWidgetOptions.load(from: defaults).isShown)

        let chosen = OverviewWidgetOptions(isShown: true, placement: .floating, size: .large)
        chosen.save(to: defaults)
        #expect(OverviewWidgetOptions.load(from: defaults) == chosen)
    }

    @Test func keepsDefaultsForWhatsMissingOrUnknown() throws {
        let decoded = try JSONDecoder().decode(OverviewWidgetOptions.self, from: Data(#"{"isShown":true,"size":"huge"}"#.utf8))
        #expect(decoded == OverviewWidgetOptions(isShown: true, placement: .desktop, size: .medium))
        let defaults = MemorySettings()
        defaults.set(Data("nonsense".utf8), forKey: OverviewWidgetOptions.defaultsKey)
        #expect(OverviewWidgetOptions.load(from: defaults) == OverviewWidgetOptions())
    }
}
