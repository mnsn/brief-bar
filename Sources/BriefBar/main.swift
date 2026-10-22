import AppKit
import BriefBarCore
import BriefBarUI

MainActor.assumeIsolated {
    let arguments = CommandLine.arguments
    // Started as an app (Finder, a login item, `open`), BriefBar has its own permissions, Full Disk Access included,
    // and whoever started it chose its environment and arguments. Some variables would move where macOS keeps and
    // finds your files, the keychain included: they're put back before anything reads them. And `-key value`
    // arguments would override its preferences, such as which sources are on, so none of them reach it.
    let attribution = Attribution.current
    if attribution == .itself {
        LaunchEnvironment.secure()
        UserDefaults.standard.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
    }
    // `BriefBar --dump | --json | --watch | --help …` work from a terminal without the UI.
    if let code = CLI.run(Array(arguments.dropFirst()), attribution: attribution) {
        exit(code)
    }
    let demo = arguments.contains("--demo")
    if let index = arguments.firstIndex(of: "--render") {
        if let refusal = CommandLineAccess.refusal(attribution) {
            fputs("\(refusal)\n", stderr)
            exit(1)
        }
        let next = index + 1 < arguments.count ? arguments[index + 1] : nil
        exit(Renderer.run(directory: next.flatMap { $0.hasPrefix("--") ? nil : $0 } ?? "render", demo: demo))
    }

    // One instance per user; a second launch (e.g. running the binary again) just exits.
    if let bundleId = Bundle.main.bundleIdentifier {
        let me = ProcessInfo.processInfo.processIdentifier
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .contains(where: { $0.processIdentifier != me }) {
            exit(0)
        }
    }

    // And whoever started it may be reading its output (`open --stdout`), where frameworks may write too: nothing
    // goes there.
    if attribution == .itself {
        fflush(nil)
        let null = open("/dev/null", O_WRONLY)
        if null >= 0 {
            dup2(null, STDOUT_FILENO)
            dup2(null, STDERR_FILENO)
            close(null)
        }
    }

    let app = NSApplication.shared
    let delegate = AppDelegate(demo: demo, openWindow: arguments.contains("--window"))
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
