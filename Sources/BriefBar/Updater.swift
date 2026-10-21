import AppKit
import BriefBarUI
import Combine
import Sparkle

/// In-app updates with Sparkle, from the appcast attached to the latest GitHub release, reported to
/// `UpdateStatus` for the menus and Settings. Its checks are BriefBar's own only network requests: the Azure
/// DevOps source makes its own, and nothing else does. They carry nothing about your chats, pull requests or
/// sessions.
///
/// Only the app checks for updates: the command-line modes, `--render` and `--demo` never start an updater, and
/// a binary without a feed URL and a public key in its bundle (such as a `.build` binary, or a build before
/// `scripts/make-release-keys.sh` set `SUPublicEDKey`) can't.
@MainActor
final class Updater: NSObject {
    private let status: UpdateStatus
    private var controller: SPUStandardUpdaterController?
    private var cancellables: Set<AnyCancellable> = []

    init(status: UpdateStatus) {
        self.status = status
        super.init()
    }

    /// Creates Sparkle's updater, which asks on the second launch whether to check automatically.
    func start() {
        guard controller == nil, Self.bundleHasUpdateSettings else { return }
        // GitHub's redirects set cookies, one of them a long-lived ID. Sending them back would let GitHub link
        // one day's check to the next. (The Azure DevOps source's own session never keeps cookies.)
        HTTPCookieStorage.shared.cookieAcceptPolicy = .never
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)

        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self
        )
        self.controller = controller

        let updater = controller.updater
        // The same for everyone, instead of your preferred languages. The notes are in English.
        updater.httpHeaders = ["Accept-Language": "en"]
        updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] value in MainActor.assumeIsolated { self?.status.canCheck = value } }
            .store(in: &cancellables)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .sink { [weak self] value in MainActor.assumeIsolated { self?.status.automaticallyChecks = value } }
            .store(in: &cancellables)
        status.check = { [weak self] in self?.checkForUpdates() }
        status.setAutomaticallyChecks = { [weak self] enabled in
            self?.controller?.updater.automaticallyChecksForUpdates = enabled
        }
        status.isAvailable = true
        controller.startUpdater()
    }

    /// Checks now, or brings an update that's already waiting to the front.
    func checkForUpdates() {
        guard let controller else { return }
        // BriefBar runs in the background; without this, Sparkle's window can open behind other apps.
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    private static var bundleHasUpdateSettings: Bool {
        ["SUFeedURL", "SUPublicEDKey"].allSatisfy { key in
            (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.isEmpty == false
        }
    }
}

/// Gentle reminders: right after launch Sparkle shows a new version itself. Later, a scheduled check mustn't
/// pull focus from the app you're using, so BriefBar's lists and window show that an update is waiting.
extension Updater: @preconcurrency SPUStandardUserDriverDelegate {
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
        Log.app.info("Version \(version, privacy: .public) is available\(handleShowingUpdate ? "" : "; reminding in the lists", privacy: .public)")
        if !handleShowingUpdate {
            status.pendingVersion = version
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        status.pendingVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        status.pendingVersion = nil
    }
}
