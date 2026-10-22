import AppKit
import BriefBarCore
import Combine
import os
import Sparkle

/// BriefBar's updater: Sparkle, in an app of its own inside BriefBar.app (Contents/Helpers/BriefBar Updater.app).
/// BriefBar itself loads no framework but Apple's, so it keeps library validation on. Sparkle needs it off, since a
/// self-signed certificate has no team, so this app turns it off (Resources/BriefBarUpdater.entitlements), and holds
/// no privacy permissions: BriefBar starts it as a `RunningProgram`, which makes sure macOS holds it responsible for
/// itself, so it never uses BriefBar's Full Disk Access. It updates BriefBar.app, whose Info.plist has the feed and
/// the update key, with Sparkle's own windows and BriefBar's name, and quits when BriefBar does.
@MainActor
final class UpdaterController: NSObject, NSApplicationDelegate {
    private let host: Bundle
    private var updater: SPUUpdater?
    private var input: InputLines?
    private var cancellables: Set<AnyCancellable> = []
    private static let log = Logger(subsystem: "com.asaf.BriefBar", category: "updater")

    init(host: Bundle) {
        self.host = host
        super.init()
    }

    /// BriefBar.app, three folders up (BriefBar.app/Contents/Helpers/BriefBar Updater.app), if its bundle identifier
    /// is this app's without ".Updater": the app this updater came in, and the only one it updates.
    static func hostBundle() -> Bundle? {
        let url = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let host = Bundle(url: url), let identifier = host.bundleIdentifier,
              Bundle.main.bundleIdentifier == identifier + ".Updater"
        else {
            log.error("The updater isn't inside the app it updates: \(url.path, privacy: .public)")
            return nil
        }
        return host
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // GitHub's redirects set cookies, one of them a long-lived ID. Sending them back would let GitHub link one
        // day's check to the next.
        HTTPCookieStorage.shared.cookieAcceptPolicy = .never
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)

        let updater = SPUUpdater(
            hostBundle: host, applicationBundle: host,
            userDriver: SPUStandardUserDriver(hostBundle: host, delegate: self), delegate: nil
        )
        self.updater = updater
        // The same for everyone, instead of your preferred languages. The notes are in English.
        updater.httpHeaders = ["Accept-Language": "en"]
        updater.publisher(for: \.canCheckForUpdates)
            .combineLatest(updater.publisher(for: \.automaticallyChecksForUpdates))
            .sink { canCheck, automaticallyChecks in
                UpdaterChannel.send(UpdaterMessage(.state, canCheck: canCheck, automaticallyChecks: automaticallyChecks))
            }
            .store(in: &cancellables)
        input = InputLines(
            handle: { [weak self] message in self?.handle(message) },
            // BriefBar quit, or let go of this updater.
            ended: { NSApp.terminate(nil) }
        )
        do {
            try updater.start()
        } catch {
            Self.log.error("Sparkle didn't start: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handle(_ message: UpdaterMessage) {
        guard let updater else { return }
        switch message.kind {
        case .check:
            // BriefBar let this app come to the front, for Sparkle's window.
            NSApp.activate()
            updater.checkForUpdates()
        case .setAutomaticallyChecks:
            if let flag = message.flag {
                updater.automaticallyChecksForUpdates = flag
            }
        case .hello, .state, .pending, .attended:
            break
        }
    }
}

/// Gentle reminders: right after launch Sparkle shows a new version itself. Later, a scheduled check mustn't pull
/// focus from the app you're using, so BriefBar's lists and window show that an update is waiting.
extension UpdaterController: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        Self.log.info("Version \(version, privacy: .public) is available\(handleShowingUpdate ? "" : "; reminding in BriefBar", privacy: .public)")
        if !handleShowingUpdate {
            UpdaterChannel.send(UpdaterMessage(.pending, version: version))
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        UpdaterChannel.send(UpdaterMessage(.attended))
    }

    func standardUserDriverWillFinishUpdateSession() {
        UpdaterChannel.send(UpdaterMessage(.attended))
    }
}
