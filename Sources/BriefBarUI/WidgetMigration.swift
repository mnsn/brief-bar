import BriefBarCore
import Foundation

/// Brings over the widget settings each source kept for itself, before a widget could show sections from
/// several sources: whether its widget showed, where and how big, and where its window was. Once.
package enum WidgetMigration {
    private static let former: [(section: SectionID, prefix: String, autosaveName: String)] = [
        (.azureDevOpsPullRequests, "ado", "BriefBar.azureDevOps.widget"),
        (.copilotSessions, "copilot", "BriefBar.copilot.widget"),
    ]

    /// Saves a widget layout and widget options from the former settings, and removes them. Does nothing once a
    /// widget layout is saved, or when there's nothing to bring over.
    package static func run(_ defaults: some SettingsStorage) {
        guard defaults.data(forKey: Surface.widgets.defaultsKey) == nil else { return }
        var layout = SectionLayout(.widgets)
        var options = WidgetOptions.load(from: defaults)
        var found = false
        for entry in former {
            let keys = ["showWidget", "widgetPlacement", "widgetSize"].map { "\(entry.prefix).\($0)" }
            let show = defaults.object(forKey: keys[0]) as? Bool
            let placement = defaults.string(forKey: keys[1]).flatMap(WidgetPlacement.init)
            let size = defaults.string(forKey: keys[2]).flatMap(WidgetSize.init)
            guard show != nil || placement != nil || size != nil else { continue }
            found = true
            layout.place([entry.section])
            if show == false {
                layout.hide(entry.section)
            }
            if placement != nil || size != nil {
                options[entry.section.rawValue] = WidgetOptions(placement: placement ?? .desktop, size: size ?? .medium)
            }
            keys.forEach(defaults.removeObject)
        }
        guard found else { return }
        layout.save(to: defaults)
        WidgetOptions.save(options, to: defaults)
    }

    /// Where the widget with this ID kept its position before, if it took the place of a source's own widget.
    package static func formerAutosaveName(for id: String) -> String? {
        former.first { $0.section.rawValue == id }?.autosaveName
    }
}
