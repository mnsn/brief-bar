import AppKit
import BriefBarCore
import SwiftUI

/// The end of every gear menu and widget menu: BriefBar's own items.
package struct AppMenuItems: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var loginItem: LoginItem
    /// The source whose menu this is, for BriefBar Settings… to open at.
    private let source: SourceID?

    package init(source: SourceID?) {
        self.source = source
    }

    package var body: some View {
        if loginItem.isAvailable {
            Toggle("Launch BriefBar at Login", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }
            ))
            if loginItem.needsApproval {
                Button("Allow in Login Items Settings…") { loginItem.openSystemSettings() }
            } else if let error = loginItem.lastError {
                Text("Launch at Login failed: \(error)")
            }
        }
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
