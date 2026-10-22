import AppKit
import BriefBarCore
import BriefBarUI
import MachO

/// In-app updates, through BriefBar's updater: Sparkle, in a helper app inside BriefBar.app
/// (Contents/Helpers/BriefBar Updater.app, from Sources/BriefBarUpdater), reported to `UpdateStatus` for the menus
/// and Settings. BriefBar itself loads no library but Apple's, so it keeps library validation on, and the updater,
/// which turns it off to load Sparkle, never has BriefBar's privacy permissions: it's started as a
/// `RunningProgram`, responsible for itself. They talk through its standard input and output (`UpdaterMessage`),
/// and it quits when BriefBar does. Its checks are BriefBar's only network requests apart from the Azure DevOps
/// source's, and carry nothing about your chats, pull requests or sessions.
///
/// Only the app checks for updates: the command-line modes, `--render` and `--demo` never start the updater, and a
/// copy without a feed URL and a public key in its Info.plist (such as one built before
/// `scripts/make-release-keys.sh` set `SUPublicEDKey`) can't.
@MainActor
final class Updater {
    private let status: UpdateStatus
    private var helper: RunningProgram?

    init(status: UpdateStatus) {
        self.status = status
    }

    /// Starts the updater. Sparkle asks on the second launch whether to check automatically.
    func start() {
        guard helper == nil, Self.bundleHasUpdateSettings,
              FileManager.default.isExecutableFile(atPath: UpdaterHelper.executable.path)
        else { return }
        status.check = { [weak self] in self?.checkForUpdates() }
        status.setAutomaticallyChecks = { [weak self] enabled in
            self?.helper?.send(UpdaterMessage(.setAutomaticallyChecks, flag: enabled).line)
        }
        status.isAvailable = launch()
    }

    /// Checks now, or brings an update that's already waiting to the front, in the updater's window.
    func checkForUpdates() {
        guard helper != nil || launch() else { return }
        // BriefBar runs in the background; this lets the updater's window come to the front.
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: UpdaterHelper.bundleIdentifier)
        helper?.send(UpdaterMessage(.check).line)
    }

    private func launch() -> Bool {
        do {
            helper = try UpdaterHelper.start(
                onMessage: { [weak self] message in MainActor.assumeIsolated { self?.handle(message) } },
                onExit: { [weak self] exitStatus in MainActor.assumeIsolated { self?.updaterQuit(exitStatus) } }
            )
            return true
        } catch {
            Log.app.error("Couldn't start the updater: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// What the updater says is only shown, and a version only if it looks like one.
    private func handle(_ message: UpdaterMessage) {
        switch message.kind {
        case .state:
            if let canCheck = message.canCheck {
                status.canCheck = canCheck
            }
            if let automaticallyChecks = message.automaticallyChecks {
                status.automaticallyChecks = automaticallyChecks
            }
        case .pending:
            if let version = message.displayVersion {
                status.pendingVersion = version
            }
        case .attended:
            status.pendingVersion = nil
        case .check, .setAutomaticallyChecks, .hello:
            break
        }
    }

    private func updaterQuit(_ exitStatus: Int32) {
        helper = nil
        status.pendingVersion = nil
        // Check for Updates… starts it again.
        status.canCheck = true
        Log.app.info("The updater quit (\(exitStatus))")
    }

    private static var bundleHasUpdateSettings: Bool {
        ["SUFeedURL", "SUPublicEDKey"].allSatisfy { key in
            (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.isEmpty == false
        }
    }
}

/// Where BriefBar's updater is, and how it's started.
enum UpdaterHelper {
    /// Inside this app, where scripts/build-app.sh puts it.
    static var bundleURL: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Helpers/BriefBar Updater.app", directoryHint: .isDirectory)
    }

    static var executable: URL {
        bundleURL.appending(path: "Contents/MacOS/BriefBarUpdater")
    }

    static var bundleIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "com.asaf.BriefBar") + ".Updater"
    }

    /// Starts it as a `RunningProgram`: responsible for itself, or not at all.
    static func start(
        arguments: [String] = [], callbackQueue: DispatchQueue = .main,
        onMessage: @escaping @Sendable (UpdaterMessage) -> Void, onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> RunningProgram {
        try RunningProgram.start(
            executable, arguments: arguments, maxLineLength: 4_096, callbackQueue: callbackQueue,
            onLine: { line in
                if let message = UpdaterMessage(line: line) {
                    onMessage(message)
                }
            },
            onExit: onExit
        )
    }
}

/// `--check-updater`: starts the updater the way the app does, and reports what macOS attributes it to, which copy
/// of Sparkle it loaded, and which libraries BriefBar itself loaded. scripts/test-updater-isolation.sh runs it in a
/// copy of the app that macOS opened, as you would, where a program started without `RunningProgram` would be
/// attributed to BriefBar and could use its privacy permissions.
enum UpdaterCheck {
    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var hello: UpdaterMessage?
        private var exitStatus: Int32?
        let changed = DispatchSemaphore(value: 0)

        func set(hello: UpdaterMessage? = nil, exitStatus: Int32? = nil) {
            lock.withLock {
                if let hello { self.hello = hello }
                if let exitStatus { self.exitStatus = exitStatus }
            }
            changed.signal()
        }

        var current: (hello: UpdaterMessage?, exitStatus: Int32?) {
            lock.withLock { (hello, exitStatus) }
        }
    }

    static func run() -> Int32 {
        var failed = false
        func fail(_ problem: String) {
            print("FAILED: \(problem)")
            failed = true
        }

        let me = getpid()
        print("BriefBar: process \(me), attributed to \(describe(Responsibility.responsibleProcess(for: me), me))")
        let others = loadedLibraries().filter { !$0.hasPrefix("/usr/lib/") && !$0.hasPrefix("/System/") }
        if others.isEmpty {
            print("BriefBar loaded only Apple's libraries, from /usr/lib and /System.")
        } else {
            fail("BriefBar loaded other libraries: \(others.joined(separator: ", "))")
        }

        guard FileManager.default.isExecutableFile(atPath: UpdaterHelper.executable.path) else {
            fail("there's no updater at \(UpdaterHelper.executable.path)")
            return 1
        }
        let results = Results()
        let helper: RunningProgram
        do {
            helper = try UpdaterHelper.start(
                arguments: ["--hello"], callbackQueue: DispatchQueue(label: "BriefBar.UpdaterCheck"),
                onMessage: { message in
                    if message.kind == .hello {
                        results.set(hello: message)
                    }
                },
                onExit: { status in results.set(exitStatus: status) }
            )
        } catch {
            fail("BriefBar didn't start the updater: \(error)")
            return 1
        }
        let responsible = Responsibility.responsibleProcess(for: helper.pid)
        print("Updater: process \(helper.pid), \(UpdaterHelper.bundleIdentifier), attributed to \(describe(responsible, helper.pid))")
        if responsible == helper.pid && helper.pid != me {
            print("macOS holds the updater responsible for itself, so it can't use BriefBar's privacy permissions.")
        } else {
            fail("the updater is attributed to process \(responsible.map(String.init) ?? "unknown")")
        }

        let deadline = DispatchTime.now() + 30
        while results.current.hello == nil && results.current.exitStatus == nil {
            if results.changed.wait(timeout: deadline) == .timedOut { break }
        }
        if let hello = results.current.hello {
            let path = hello.path ?? "?"
            print("The updater loaded Sparkle \(hello.version ?? "?") from \(path).")
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if !resolved.hasPrefix(UpdaterHelper.bundleURL.resolvingSymlinksInPath().path + "/") {
                fail("that copy of Sparkle isn't the updater's own")
            }
        } else {
            fail("the updater didn't start (exit status \(results.current.exitStatus.map(String.init) ?? "none")): could it load Sparkle?")
        }
        helper.closeInput()
        while results.current.exitStatus == nil {
            if results.changed.wait(timeout: .now() + 10) == .timedOut {
                helper.terminate()
                break
            }
        }
        return failed ? 1 : 0
    }

    private static func describe(_ responsible: pid_t?, _ pid: pid_t) -> String {
        guard let responsible else { return "an unknown process" }
        return responsible == pid ? "itself" : "process \(responsible)"
    }

    /// Every library loaded in this process, apart from its executable.
    private static func loadedLibraries() -> [String] {
        let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path
        return (0..<_dyld_image_count()).compactMap { index in
            guard let name = _dyld_get_image_name(index) else { return nil }
            let path = String(cString: name)
            return index == 0 || URL(fileURLWithPath: path).resolvingSymlinksInPath().path == executable ? nil : path
        }
    }
}
