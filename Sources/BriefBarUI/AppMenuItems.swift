import AppKit
import BriefBarCore
import SwiftUI

/// The end of every gear menu and widget menu: BriefBar's own items. What you set once, such as Launch at Login, is in
/// Settings.
package struct AppMenuItems: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.panelStyle) private var panelStyle
    @Environment(\.shownSection) private var shownSection
    /// The source whose menu this is, for BriefBar Settings… to open at.
    private let source: SourceID?

    package init(source: SourceID?) {
        self.source = source
    }

    package var body: some View {
        // Not on a window's own page.
        if panelStyle != .page {
            Button("Open in Window") { services.openWindow(shownSection) }
        }
        UpdateMenuItems(updates: services.updates)
        Button("BriefBar Settings…") { services.openSettings(source.map { .source($0) } ?? .general) }
        Button("Quit BriefBar") { NSApp.terminate(nil) }
    }
}

/// A divider in a source's settings when they're a menu; nothing in the Settings window's form, whose
/// rows are already apart.
package struct SettingsDivider: View {
    @Environment(\.inSettingsForm) private var inSettingsForm

    package init() {}

    package var body: some View {
        if !inSettingsForm {
            Divider()
        }
    }
}

private struct InSettingsFormKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether a source's settings show in the Settings window's form, rather than in a menu.
    package var inSettingsForm: Bool {
        get { self[InSettingsFormKey.self] }
        set { self[InSettingsFormKey.self] = newValue }
    }
}
