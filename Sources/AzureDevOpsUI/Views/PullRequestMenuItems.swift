import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

/// What a pull request's menus have after opening it, in its row's and in its details: summarizing it, the message it was
/// sent in, taking it off Needs You, what Copilot can do with it while Send Work to Copilot is on, its links, and no
/// longer watching it.
struct PullRequestMenuItems: View {
    let item: PRSnapshot
    /// Opens the message it was sent in; nil when it wasn't.
    var openSource: (() -> Void)?
    /// Takes it off Needs You; nil when it isn't there.
    var dismiss: (() -> Void)?
    /// Stops watching it; nil when you don't watch it.
    var stopWatching: (() -> Void)?

    var body: some View {
        // Right after opening it, a group of its own.
        SummarizeMenuItems(item.key.linkRef)
        if let source = item.chatSource, let openSource {
            Button(source.messageURL == nil ? "Show \(source.appName)" : "Open Message in \(source.appName)", action: openSource)
        }
        if let dismiss {
            Button("Remove from Needs You", action: dismiss)
        }
        PullRequestCopilotMenuItems(item: item)
        LinkMenuItems(item.key.linkRef)
        if item.isWatched, let stopWatching {
            Divider()
            Button("Stop Watching", action: stopWatching)
        }
    }
}
