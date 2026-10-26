import BriefBarCore
import Foundation
import Testing
@testable import BriefBarUI

@MainActor
@Suite struct InterfaceSettingsTests {
    @Test func sharedSettingsUpdateImmediatelyAndSurviveReloading() {
        let defaults = MemoryDefaults()
        let services = AppServices(defaults: defaults, isDemo: true)
        #expect(services.interfaceOptions == InterfaceOptions())
        services.setInterfaceOption(.quietAppearance, enabled: true)
        services.setInterfaceOption(.visibleActions, enabled: true)
        #expect(services.interfaceOptions == InterfaceOptions(enabled: [.quietAppearance, .visibleActions]))
        #expect(AppServices(defaults: defaults, isDemo: true).interfaceOptions == services.interfaceOptions)
        services.setInterfaceOption(.quietAppearance, enabled: false)
        #expect(services.interfaceOptions == InterfaceOptions(enabled: [.visibleActions]))
    }

    @Test func onlyReadableRowsChangeTheWidgetRowHeight() {
        #expect(InterfaceOptions().compactRowHeight == 42)
        for option in InterfaceOption.allCases {
            let options = InterfaceOptions(enabled: [option])
            #expect(options.compactRowHeight == (option == .readableRows ? 46 : 42))
            #expect(options.rowIconWidth == (option == .readableRows ? 30 : 20))
        }
    }

    @Test func sidebarAttentionDoesNotCountOrdinaryWorkloadOrCompletedWork() {
        let sprint = MenuBarSegment(glyph: nil, title: .init(), summary: "4 left", count: 4, needsAttention: false, states: StateCounts())
        #expect(sprint.attentionCount == 0)
        let work = MenuBarSegment(
            glyph: nil, title: .init(), summary: "Work", count: 2, needsAttention: true,
            states: StateCounts(needsYou: 2, failing: 3, running: 4, done: 5)
        )
        #expect(work.attentionCount == 5)
        #expect(work.count == 2)
    }
}
