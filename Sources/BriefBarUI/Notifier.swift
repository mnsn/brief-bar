import AppKit
import BriefBarCore
import Combine
import UserNotifications

/// One notification, from any source.
package struct BriefBarNotification: Sendable {
    package var id: String
    package var source: SourceID
    /// What it means for you, such as a build that failed, for its symbol on the Notifications page.
    package var state: ItemState?
    package var title: String
    package var subtitle: String?
    package var body: String
    /// Notification Center groups notifications with the same thread.
    package var thread: String
    /// What the source needs to open what the notification is about, when it's clicked.
    package var userInfo: [String: String]
    /// It counts others, which aren't posted, such as "3 more pull request updates": the Notifications page lists those
    /// instead of it (`Notifier.post`'s `more`), and clicking it opens that page, while the window has it.
    package var sumsUp: Bool

    package init(
        id: String, source: SourceID, state: ItemState? = nil, title: String, subtitle: String? = nil, body: String,
        thread: String, userInfo: [String: String] = [:], sumsUp: Bool = false
    ) {
        self.id = id
        self.source = source
        self.state = state
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.thread = thread
        self.userInfo = userInfo
        self.sumsUp = sumsUp
    }
}

/// A click on one of BriefBar's notifications in Notification Center.
package struct NotificationClick: Sendable, Equatable {
    package var id: String
    package var source: SourceID?
    /// What its source needs to open what it's about.
    package var userInfo: [String: String]
    /// It counted others, which the Notifications page lists.
    package var sumsUp: Bool

    package init(id: String, source: SourceID?, userInfo: [String: String] = [:], sumsUp: Bool = false) {
        self.id = id
        self.source = source
        self.userInfo = userInfo
        self.sumsUp = sumsUp
    }
}

/// Posts macOS notifications for every source, and lists them on the Notifications page (`RecentNotifications`). macOS
/// asks once whether BriefBar may show notifications, and then every source that you turn on and that posts them uses
/// that answer.
@MainActor
package final class Notifier: NSObject, ObservableObject {
    /// Notifications are turned off for BriefBar in System Settings.
    @Published package private(set) var isBlocked = false
    /// Called when a notification is clicked, once BriefBar is in front (`clicked`).
    package var onOpen: ((NotificationClick) -> Void)?
    /// What BriefBar notified you of lately: the Notifications page.
    package let recent: RecentNotifications
    /// How long a click waits for macOS to bring BriefBar to the front, at most.
    package var clickWait: TimeInterval = 0.5

    nonisolated private static let sourceKey = "briefBarSource"
    nonisolated private static let sumsUpKey = "briefBarSumsUp"
    /// For this long after a click, BriefBar coming to the front is the click's doing.
    private static let reopenWindow: TimeInterval = 2
    private let center: UNUserNotificationCenter?
    private var requestedAuthorization = false
    /// The click whose notification opens once BriefBar is in front.
    private var pendingClick: NotificationClick?
    private var clickedAt: Date?
    /// Opens the pending click if BriefBar doesn't come to the front in time: that click's own wait, which goes as soon as
    /// the click opens, so it can't open a later one.
    private(set) var clickTimeout: Task<Void, Never>?

    /// - Parameter posts: whether it posts to Notification Center, which only an app bundle can: a bare `swift run` binary
    ///   only lists them on the Notifications page, and so do tests.
    package init(recent: RecentNotifications, posts: Bool = Bundle.main.bundleIdentifier != nil) {
        self.recent = recent
        center = posts ? UNUserNotificationCenter.current() : nil
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

    /// Posts notifications, and lists them on the Notifications page, the newest first, as they come: all but one that
    /// counts others (`sumsUp`), whose updates come in `more`, listed after them without being posted. They're listed even
    /// when macOS doesn't show them, such as when notifications are off for BriefBar.
    package func post(_ notes: [BriefBarNotification], more: [BriefBarNotification] = []) {
        recent.record(notes.filter { !$0.sumsUp } + more)
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
            if note.sumsUp { info[Self.sumsUpKey] = "1" }
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

    /// Takes notifications away by their IDs, such as one that no longer says what's going on: off Notification Center,
    /// and off the Notifications page.
    package func remove(_ ids: [String]) {
        recent.remove(ids)
        guard let center, !ids.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Takes one off Notification Center once you've opened it from the Notifications page, which keeps it.
    package func removeDelivered(_ id: String) {
        center?.removeDeliveredNotifications(withIdentifiers: [id])
    }

    // MARK: Clicks

    /// A click on a notification. macOS then brings BriefBar to the front, as when you open it again, usually just after
    /// the click gets here: what the notification is about opens once that's happened (`handleReopen`), or after
    /// `clickWait` at most. Opened right away, it would open in your browser, say, and BriefBar would come in front of it.
    package func clicked(_ click: NotificationClick, at date: Date = Date()) {
        recent.markSeen(click.id)
        // One clicked just before still opens.
        openClicked(reason: "another was clicked")
        pendingClick = click
        clickedAt = date
        let wait = clickWait
        // Its own wait: one left over from an earlier click would open this one before BriefBar is in front for it.
        clickTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.openClicked(reason: "BriefBar didn't come to the front")
        }
    }

    /// macOS brought BriefBar to the front, as when you open it again: true when that's for a click on a notification,
    /// which then opens what it's about, rather than what opening BriefBar shows.
    package func handleReopen(at date: Date = Date()) -> Bool {
        guard let clickedAt, date.timeIntervalSince(clickedAt) < Self.reopenWindow else { return false }
        openClicked(reason: "BriefBar came to the front")
        return true
    }

    private func openClicked(reason: String) {
        guard let click = pendingClick else { return }
        pendingClick = nil
        // It opens now, so its wait is over.
        clickTimeout?.cancel()
        clickTimeout = nil
        Log.app.info("Opening a clicked notification: \(reason, privacy: .public)")
        onOpen?(click)
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
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier else { return }
        var info: [String: String] = [:]
        for case let (key as String, value as String) in response.notification.request.content.userInfo {
            info[key] = value
        }
        let source = info.removeValue(forKey: Self.sourceKey).flatMap(SourceID.init(rawValue:))
        let sumsUp = info.removeValue(forKey: Self.sumsUpKey) != nil
        let click = NotificationClick(id: response.notification.request.identifier, source: source, userInfo: info, sumsUp: sumsUp)
        await MainActor.run {
            clicked(click)
        }
    }
}
