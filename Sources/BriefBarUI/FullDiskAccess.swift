import AppKit
import BriefBarCore
import Combine
import SwiftUI

/// Full Disk Access, which macOS grants once, to the whole app: every source that reads Notification
/// Center's database uses it. macOS has no prompt for it, so this window walks you through System
/// Settings. It's only for sources you turned on: a source registers when it starts and unregisters when
/// it stops, and nothing here checks or asks for anything while none is registered.
@MainActor
package final class FullDiskAccess: NSObject, ObservableObject, NSWindowDelegate {
    /// A source that needs the access.
    private struct Requester {
        var name: String
        /// Why, in a sentence, such as "BriefBar finds your unread Teams chats in…".
        var reason: String
        /// Whether it can read what it needs right now.
        var probe: () -> Bool
    }

    /// Whether the sources that need it can read what they need. Nil until one checks.
    @Published package private(set) var isGranted: Bool?
    /// BriefBar had the access before, and lost it: a build signed with another certificate does.
    @Published package private(set) var lostAccess = false

    private var requesters: [SourceID: Requester] = [:]
    private var order: [SourceID] = []
    private var window: NSWindow?
    private var timer: Timer?
    private let defaults: any SettingsStorage
    private static let hadAccessKey = "fullDiskAccess.hadAccess"

    package init(defaults: any SettingsStorage = UserDefaults.standard) {
        self.defaults = defaults
        super.init()
    }

    /// Whether this is the app bundle, rather than a binary run from Terminal (whose Full Disk Access
    /// is then Terminal's).
    package var isBundled: Bool { AppIdentity.isBundled }

    /// The folder the app is in, as you'd type it in an Open panel: `~/Applications` after `make install`.
    package var appFolder: String {
        (Bundle.main.bundleURL.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }

    /// Whether any source that's on needs it.
    package var isNeeded: Bool { !requesters.isEmpty }

    /// Whether this source needs it now: Teams while it's on, Azure DevOps while it looks for pull requests sent in
    /// chats.
    package func isRequested(by source: SourceID) -> Bool { requesters[source] != nil }

    /// Whether BriefBar could read Notification Center at some point.
    package var hadAccess: Bool { defaults.bool(forKey: Self.hadAccessKey) }

    package var requesterNames: [String] { order.compactMap { requesters[$0]?.name } }
    package var reasons: [String] { order.compactMap { requesters[$0]?.reason } }

    /// A source that's on and needs the access.
    package func register(_ source: SourceID, name: String, reason: String, probe: @escaping () -> Bool) {
        if requesters[source] == nil { order.append(source) }
        requesters[source] = Requester(name: name, reason: reason, probe: probe)
    }

    /// The source is off: it doesn't need the access anymore.
    package func unregister(_ source: SourceID) {
        requesters[source] = nil
        order.removeAll { $0 == source }
        if requesters.isEmpty {
            close()
            isGranted = nil
        }
    }

    /// Checks with every source that needs it.
    @discardableResult
    package func check() -> Bool? {
        guard !requesters.isEmpty else { return nil }
        update(granted: requesters.values.allSatisfy { $0.probe() })
        return isGranted
    }

    /// A source found out by reading.
    package func report(granted: Bool) {
        guard !requesters.isEmpty else { return }
        update(granted: granted)
    }

    private func update(granted: Bool) {
        if granted, !defaults.bool(forKey: Self.hadAccessKey) {
            defaults.set(true, forKey: Self.hadAccessKey)
        }
        lostAccess = !granted && defaults.bool(forKey: Self.hadAccessKey)
        if isGranted != granted { isGranted = granted }
    }

    /// Opens the window that walks you through granting the access, and checks every 2 seconds while
    /// it's open.
    package func show() {
        guard isNeeded else { return }
        check()
        requestListing()
        if window == nil {
            let host = NSHostingController(rootView: FullDiskAccessView().environmentObject(self))
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = AppIdentity.name
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        if timer == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.check() }
            }
            timer.tolerance = 0.25
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    package func close() {
        window?.close()
    }

    nonisolated package func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            timer?.invalidate()
            timer = nil
        }
    }

    /// System Settings › Privacy & Security › Full Disk Access.
    package func openPrivacySettings() {
        requestListing()
        Self.openPrivacySettingsPane()
    }

    package static func openPrivacySettingsPane() {
        let panes = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        ]
        for pane in panes {
            if let url = URL(string: pane), NSWorkspace.shared.open(url) { return }
        }
    }

    package func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    /// What Settings says when you turn off the last thing that needed the access.
    package static let removalTitle = "BriefBar doesn't need Full Disk Access now"
    package static let removalMessage = "Nothing that's on reads Notification Center. You can remove BriefBar from the Full Disk Access list: select it, then click −."

    /// Nothing that's on needs the access anymore, as you just turned it off: offers to open the list, so you can
    /// remove BriefBar from it.
    package func offerRemoval() {
        guard isBundled, !isNeeded, hadAccess else { return }
        let alert = NSAlert()
        alert.messageText = Self.removalTitle
        alert.informativeText = Self.removalMessage
        alert.addButton(withTitle: "Open Privacy Settings")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            Self.openPrivacySettingsPane()
        }
    }

    /// Gets BriefBar listed under Full Disk Access, switched off, so you only turn it on. macOS lists an
    /// app there once it has been denied a folder that Full Disk Access protects, but Notification
    /// Center's database is protected without that. So, while the access is missing and a source that's
    /// on needs it, this tries to list the folders Apple's Stocks and Safari keep, as the FullDiskAccess
    /// package does (github.com/inket/FullDiskAccess). Without access, both attempts are denied and read
    /// nothing.
    package func requestListing() {
        guard isBundled, isNeeded, isGranted != true else { return }
        let home = UserHome.url
        for folder in ["Library/Containers/com.apple.stocks", "Library/Safari"] {
            _ = try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(folder).path)
        }
        Log.app.info("Asked macOS to list BriefBar under Full Disk Access")
    }

    /// Quits and opens the app again, once this process has exited, for when macOS only applies the
    /// access after a restart.
    package func relaunch() {
        guard isBundled else { return }
        do {
            try ProcessRunner.launch(URL(fileURLWithPath: "/bin/sh"), arguments: [
                "-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
                Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier),
            ])
            NSApp.terminate(nil)
        } catch {
            Log.app.error("Couldn't relaunch: \(String(describing: error), privacy: .public)")
        }
    }
}

/// The window that walks you through granting Full Disk Access.
package struct FullDiskAccessView: View {
    @EnvironmentObject private var access: FullDiskAccess

    package init() {}

    private var names: String {
        ListFormatter.localizedString(byJoining: access.requesterNames)
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                AppIconView(isBundled: access.isBundled)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Allow Full Disk Access")
                        .font(style: .title2, weight: .semibold)
                    Text("So BriefBar can read Notification Center for \(names)")
                        .foregroundStyle(.secondary)
                }
            }

            Text((access.reasons + [
                "macOS protects Notification Center's database, so BriefBar needs Full Disk Access to read it. It only reads it, and nothing it reads there leaves your Mac.",
                "macOS gives the access to all of BriefBar, once. Only the sources you turn on that need it use it.",
            ]).joined(separator: " "))
                .fixedSize(horizontal: false, vertical: true)

            if access.lostAccess {
                // Selectable, to copy the command.
                Label("BriefBar had access before. That happens when it's rebuilt with another signature, and turning it off and on keeps the old one: remove BriefBar from the list with −, then add it again with +. If it still has no access, run `tccutil reset SystemPolicyAllFiles \(AppIdentity.bundleIdentifier)` in Terminal, then add it again.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if access.isBundled {
                VStack(alignment: .leading, spacing: 6) {
                    step(1, "Click **Open Privacy Settings**.")
                    step(2, "Turn on **BriefBar**. If it isn't in the list, click **+** under the list and choose it in **\(access.appFolder)** (press ⌘⇧G to type the folder), or click **Show in Finder** and drag it into the list. If it's on already, remove it with **−** and add it again.")
                    step(3, "If macOS offers to, choose **Quit & Reopen**.")
                }
            } else {
                Text("You're running BriefBar from Terminal, so macOS checks Terminal's access instead: give **Terminal** Full Disk Access, then run BriefBar again.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Open Privacy Settings") { access.openPrivacySettings() }
                    .keyboardShortcut(.defaultAction)
                if access.isBundled {
                    Button("Show in Finder") { access.showInFinder() }
                }
                Spacer()
            }

            Divider()

            HStack(spacing: 8) {
                if access.isGranted == true {
                    Label("Done. BriefBar can read Notification Center now.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Close") { access.close() }
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for access…")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if access.isBundled {
                        Button("Quit & Reopen") { access.relaunch() }
                            .help("Use this if you turned access on and BriefBar still waits")
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The app's icon, which you can drag into the Full Disk Access list.
package struct AppIconView: View {
    let isBundled: Bool
    var size: CGFloat = 64

    package init(isBundled: Bool, size: CGFloat = 64) {
        self.isBundled = isBundled
        self.size = size
    }

    package var body: some View {
        let icon = Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
            .resizable()
            .frame(width: size, height: size)
        if isBundled {
            icon
                .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                .help("Drag this into the Full Disk Access list")
        } else {
            icon
        }
    }
}
