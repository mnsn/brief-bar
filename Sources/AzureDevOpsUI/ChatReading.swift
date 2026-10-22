import AzureDevOpsCore
import Foundation

/// How Azure DevOps reads Notification Center for pull requests sent in chats. Inert unless the app passes
/// `notificationCenter()`, so `--render`, the demo and tests can't read Notification Center, or ask for Full Disk Access
/// for it.
package struct ChatReading {
    /// The database it reads: Notification Center's own needs Full Disk Access. Nil when it reads none.
    package var database: URL?
    /// Starts watching it, delivering on the main queue; nil when it reads nothing.
    package var monitor: @MainActor (@escaping ChatLinkMonitor.ChangeHandler) -> ChatLinkMonitor?

    package init(database: URL?, monitor: @escaping @MainActor (@escaping ChatLinkMonitor.ChangeHandler) -> ChatLinkMonitor?) {
        self.database = database
        self.monitor = monitor
    }

    /// Reads nothing.
    package static var inert: ChatReading {
        ChatReading(database: nil) { _ in nil }
    }

    /// Notification Center's database, or the copy `BRIEFBAR_CHAT_LINKS_DB` names while BriefBar has the permissions of
    /// the app that started it: for the app itself only.
    package static func notificationCenter() -> ChatReading {
        let database = ChatLinkDatabase.url()
        return ChatReading(database: database) { onChange in
            ChatLinkMonitor(database: database, deliverOn: .main, onChange: onChange)
        }
    }
}
