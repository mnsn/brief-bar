import AppKit
import Combine

/// Opens BriefBar's menus where you are, over an app in full screen.
///
/// While a window or Settings is open, BriefBar is in the Dock (`AppModel.showInDock`), and its windows stay on their
/// Space. A menu opened then from a list over another app in full screen, such as a list's ⚙︎ menu, opened on the
/// Space of BriefBar's windows instead, out of sight: macOS 26 draws a menu in a window of its own, and puts that one
/// on the app's Space, not on every Space as for a menu-bar app's menus. The menu was open, and took your clicks and
/// keys, but you couldn't see it. So while a menu is open and BriefBar is in the Dock, each menu window that isn't on
/// every Space is put there as it appears, before it's drawn.
@MainActor
final class MenusOverFullScreen {
    private var openMenus: Set<ObjectIdentifier> = []
    private var observer: CFRunLoopObserver?
    private var cancellables: Set<AnyCancellable> = []

    func start() {
        let center = NotificationCenter.default
        center.publisher(for: NSMenu.didBeginTrackingNotification)
            .sink { [weak self] notification in
                MainActor.assumeIsolated { self?.menu(notification.object as? NSMenu, isOpen: true) }
            }
            .store(in: &cancellables)
        center.publisher(for: NSMenu.didEndTrackingNotification)
            .sink { [weak self] notification in
                MainActor.assumeIsolated { self?.menu(notification.object as? NSMenu, isOpen: false) }
            }
            .store(in: &cancellables)
    }

    private func menu(_ menu: NSMenu?, isOpen: Bool) {
        guard let menu else { return }
        if isOpen {
            openMenus.insert(ObjectIdentifier(menu))
        } else {
            openMenus.remove(ObjectIdentifier(menu))
        }
        if openMenus.isEmpty {
            stopWatching()
        } else {
            startWatching()
        }
    }

    /// Checks the windows each time the app is about to wait for events: a menu's windows only appear after the menu
    /// says it's open, and macOS draws them once that's done.
    private func startWatching() {
        guard observer == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) {
            _, _ in MainActor.assumeIsolated { Self.putMenusOnEverySpace() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    private func stopWatching() {
        guard let observer else { return }
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = nil
    }

    private static func putMenusOnEverySpace() {
        guard NSApp.activationPolicy() == .regular else { return }
        for window in NSApp.windows
        where window.level >= .popUpMenu && window.isVisible && !window.collectionBehavior.contains(.canJoinAllSpaces) {
            // These Space policies are mutually exclusive; leave windows that deliberately move alone.
            guard !window.collectionBehavior.contains(.moveToActiveSpace) else { continue }
            window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
            // A window already on a Space only moves once it's ordered in again.
            window.orderFront(nil)
        }
    }
}
