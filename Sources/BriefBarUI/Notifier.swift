import AppKit
import BriefBarCore
import Combine
import UserNotifications

/// One notification, from any source.
package struct BriefBarNotification: Sendable {
    package var id: String
    package var source: SourceID
    package var title: String
    package var subtitle: String?
    package var body: String
    /// Notification Center groups notifications with the same thread.
    package var thread: String
    /// What the source needs to open what the notification is about, when it's clicked.
    package var userInfo: [String: String]

    package init(
        id: String, source: SourceID, title: String, subtitle: String? = nil, body: String, thread: String,
        userInfo: [String: String] = [:]
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.thread = thread
        self.userInfo = userInfo
    }
}

/// Posts macOS notifications for every source. macOS asks once whether BriefBar may show notifications,
/// and then every source that you turn on and that posts them uses that answer.
@MainActor
package final class Notifier: NSObject, ObservableObject {
    /// Notifications are turned off for BriefBar in System Settings.
    @Published package private(set) var isBlocked = false
    /// Called when a notification is clicked, with its source and user info.
    package var onOpen: ((SourceID?, [String: String]) -> Void)?

    nonisolated private static let sourceKey = "briefBarSource"
    private let center: UNUserNotificationCenter?
    private var requestedAuthorization = false

    override package init() {
        // Only an app bundle can post notifications; a bare `swift run` binary can't.
        center = Bundle.main.bundleIdentifier != nil ? UNUserNotificationCenter.current() : nil
        super.init()
        center?.delegate = self
    }

    package var isAvailable: Bool { center != nil }

    /// Asks once: when a source that posts notifications is turned on, or its notifications are.
    package func requestAuthorization() {
        guard let center, !requestedAuthorization else {
            refreshStatus()
            return
        }
        requestedAuthorization = true
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Log.app.info("Notifications \(granted ? "allowed" : "not allowed", privacy: .public)\(error.map { ": \($0.localizedDescription)" } ?? "", privacy: .public)")
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    /// Checks whether notifications are turned off for BriefBar in System Settings.
    package func refreshStatus() {
        guard let center else { return }
        center.getNotificationSettings { [weak self] settings in
            let blocked = settings.authorizationStatus == .denied
            Task { @MainActor in
                guard let self, self.isBlocked != blocked else { return }
                self.isBlocked = blocked
                if blocked { Log.app.info("Notifications are turned off for BriefBar in System Settings") }
            }
        }
    }

    /// System Settings › Notifications, at BriefBar.
    package static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(AppIdentity.bundleIdentifier)") {
            NSWorkspace.shared.open(url)
        }
    }

    package func post(_ notes: [BriefBarNotification]) {
        guard let center, !notes.isEmpty else { return }
        requestAuthorization()
        for note in notes {
            let content = UNMutableNotificationContent()
            content.title = note.title
            if let subtitle = note.subtitle { content.subtitle = subtitle }
            content.body = note.body
            content.sound = .default
            content.threadIdentifier = note.thread
            var info = note.userInfo
            info[Self.sourceKey] = note.source.rawValue
            content.userInfo = info
            let request = UNNotificationRequest(identifier: note.id, content: content, trigger: nil)
            center.add(request) { error in
                if let error {
                    Log.app.error("Couldn't post a notification: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Removes a source's notifications from Notification Center, when it's turned off.
    package func removeDelivered(from source: SourceID) {
        guard let center else { return }
        center.getDeliveredNotifications { notifications in
            let identifiers = notifications
                .filter { $0.request.content.userInfo[Self.sourceKey] as? String == source.rawValue }
                .map(\.request.identifier)
            guard !identifiers.isEmpty else { return }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    nonisolated package func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated package func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        var info: [String: String] = [:]
        for case let (key as String, value as String) in response.notification.request.content.userInfo {
            info[key] = value
        }
        let source = info.removeValue(forKey: Self.sourceKey).flatMap(SourceID.init(rawValue:))
        await MainActor.run {
            onOpen?(source, info)
        }
    }
}
