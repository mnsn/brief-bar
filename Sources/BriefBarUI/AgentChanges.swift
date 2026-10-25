import Foundation

/// Tells the app that an agent changed its settings through `--mcp`, such as the pull requests you watch, so that it
/// reads them again. The notification says nothing else: any program can see it go by.
package enum AgentChanges {
    package static let name = Notification.Name("\(AppIdentity.bundleIdentifier).agentChangedSettings")

    /// Delivered at once, though a menu-bar app is rarely the active one.
    package static func post() {
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// Calls `changed` on the main thread each time, for as long as the result is kept.
    @MainActor
    package static func observe(_ changed: @escaping @MainActor () -> Void) -> AnyObject {
        Observation(changed)
    }

    /// Holds only `changed`, which runs on the main thread.
    private final class Observation: NSObject, @unchecked Sendable {
        private let changed: @MainActor () -> Void

        @MainActor
        init(_ changed: @escaping @MainActor () -> Void) {
            self.changed = changed
            super.init()
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(receive(_:)), name: AgentChanges.name, object: nil, suspensionBehavior: .deliverImmediately
            )
        }

        @objc private func receive(_ notification: Notification) {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.changed() }
            }
        }

        deinit {
            DistributedNotificationCenter.default().removeObserver(self)
        }
    }
}
