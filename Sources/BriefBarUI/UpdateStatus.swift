import Combine
import SwiftUI

/// In-app updates, as the app's updater (Sparkle, in the app target) reports them, for menus, Settings and the
/// reminder that an update is waiting.
@MainActor
package final class UpdateStatus: ObservableObject {
    /// Whether this copy of the app updates itself: the installed app, once its release keys are set.
    @Published package var isAvailable = false
    @Published package var canCheck = false
    @Published package var automaticallyChecks = false
    /// The version a scheduled check found, while it waits for your attention.
    @Published package var pendingVersion: String?

    package var check: () -> Void = {}
    package var setAutomaticallyChecks: (Bool) -> Void = { _ in }

    package init() {}
}

/// Check for Updates…, in every gear menu and widget menu, when the app updates itself.
struct UpdateMenuItems: View {
    @ObservedObject var updates: UpdateStatus

    var body: some View {
        if updates.isAvailable {
            Button(updates.pendingVersion.map { "Update to BriefBar \($0)…" } ?? "Check for Updates…") { updates.check() }
                .disabled(!updates.canCheck && updates.pendingVersion == nil)
        }
    }
}
