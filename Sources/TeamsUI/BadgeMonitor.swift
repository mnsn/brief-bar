import AppKit
import Combine
import TeamsCore

/// Watches Teams' dock badge while **Mark All Read When Teams' Badge Clears** is on (the default).
/// `lsappinfo` reads it from Launch Services without any permission; it's checked every 5 seconds while
/// Teams runs, and whenever Teams comes to the front or leaves it. Only a badge seen to disappear, and
/// stay gone, within one Teams process counts (see `ConversationStore.dockBadgeChanged`).
@MainActor
final class BadgeMonitor {
    private let store: ConversationStore
    private let settings: AppSettings
    private let queue = DispatchQueue(label: "BriefBar.Teams.BadgeMonitor", qos: .utility)
    private var timer: Timer?
    private var isReading = false
    private var cancellables: Set<AnyCancellable> = []

    /// Teams sets its badge a while after it starts; until then, no badge means nothing.
    static let launchGrace: TimeInterval = 60

    init(store: ConversationStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    func start() {
        settings.$clearWithDockBadge
            .removeDuplicates()
            .sink { [weak self] enabled in MainActor.assumeIsolated { self?.setEnabled(enabled) } }
            .store(in: &cancellables)
        let center = NSWorkspace.shared.notificationCenter
        func teams(_ name: Notification.Name) -> AnyPublisher<Notification, Never> {
            center.publisher(for: name)
                .filter { notification in
                    let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    return TeamsApp.bundleIdentifiers.contains(app?.bundleIdentifier ?? "")
                }
                .eraseToAnyPublisher()
        }
        // A new or departed Teams process starts over.
        teams(NSWorkspace.didLaunchApplicationNotification)
            .merge(with: teams(NSWorkspace.didTerminateApplicationNotification))
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.store.resetDockBadge() } }
            .store(in: &cancellables)
        teams(NSWorkspace.didActivateApplicationNotification)
            .merge(with: teams(NSWorkspace.didDeactivateApplicationNotification))
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.read() } }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        timer?.invalidate()
        timer = nil
    }

    private func setEnabled(_ enabled: Bool) {
        timer?.invalidate()
        timer = nil
        store.resetDockBadge()
        guard enabled else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        read()
    }

    private func read() {
        guard settings.clearWithDockBadge, !isReading else { return }
        guard let teams = TeamsApp.runningApplication, let bundleIdentifier = teams.bundleIdentifier else {
            store.resetDockBadge()
            return
        }
        if let launched = teams.launchDate, Date().timeIntervalSince(launched) < Self.launchGrace { return }
        let process = teams.processIdentifier
        isReading = true
        queue.async { [weak self] in
            let reading = DockBadge.read(bundleIdentifier: bundleIdentifier)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isReading = false
                    // Teams may have quit meanwhile: a reading about a process that's gone means nothing.
                    guard TeamsApp.runningApplication?.processIdentifier == process else {
                        self.store.resetDockBadge()
                        return
                    }
                    self.store.dockBadgeChanged(reading, teamsProcess: process)
                }
            }
        }
    }
}
