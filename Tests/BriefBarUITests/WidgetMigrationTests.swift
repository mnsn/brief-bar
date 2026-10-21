import BriefBarCore
import Foundation
import Testing
@testable import BriefBarUI

@Suite struct WidgetMigrationTests {
    @Test func bringsOverEachSourcesWidgetOnce() {
        let defaults = MemorySettings()
        defaults.set(false, forKey: "ado.showWidget")
        defaults.set("floating", forKey: "ado.widgetPlacement")
        defaults.set("large", forKey: "ado.widgetSize")
        defaults.set("compact", forKey: "copilot.widgetSize")

        WidgetMigration.run(defaults)
        let layout = SectionLayout.load(.widgets, from: defaults)
        #expect(layout.items.map(\.sections) == [[.azureDevOpsPullRequests], [.copilotSessions]])
        #expect(layout.isHidden(.azureDevOpsPullRequests))
        #expect(!layout.isHidden(.copilotSessions))
        let options = WidgetOptions.load(from: defaults)
        #expect(options["azureDevOps.pullRequests"] == WidgetOptions(placement: .floating, size: .large))
        #expect(options["copilot.sessions"] == WidgetOptions(placement: .desktop, size: .compact))
        for key in ["ado.showWidget", "ado.widgetPlacement", "ado.widgetSize", "copilot.widgetSize"] {
            #expect(defaults.object(forKey: key) == nil)
        }

        // Once there's a layout, nothing changes it.
        var changed = layout
        changed.show(.azureDevOpsPullRequests)
        changed.save(to: defaults)
        defaults.set(false, forKey: "copilot.showWidget")
        WidgetMigration.run(defaults)
        #expect(SectionLayout.load(.widgets, from: defaults) == changed)
    }

    @Test func savesNothingWithoutFormerSettings() {
        let defaults = MemorySettings()
        WidgetMigration.run(defaults)
        #expect(defaults.data(forKey: Surface.widgets.defaultsKey) == nil)
        #expect(defaults.data(forKey: WidgetOptions.defaultsKey) == nil)
    }

    @Test func knowsWhereFormerWidgetsWere() {
        #expect(WidgetMigration.formerAutosaveName(for: "azureDevOps.pullRequests") == "BriefBar.azureDevOps.widget")
        #expect(WidgetMigration.formerAutosaveName(for: "copilot.sessions") == "BriefBar.copilot.widget")
        #expect(WidgetMigration.formerAutosaveName(for: "copilot.sessions-2") == nil)
    }

    @Test func widgetsShareRowsAmongTheirSections() {
        #expect(WidgetSize.medium.rows(sharedBy: 1) == 4)
        #expect(WidgetSize.medium.rows(sharedBy: 2) == 3)
        #expect(WidgetSize.large.rows(sharedBy: 3) == 5)
        #expect(WidgetSize.compact.rows(sharedBy: 2) == 2)
    }
}
