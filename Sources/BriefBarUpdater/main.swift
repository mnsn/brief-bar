import AppKit
import BriefBarCore

// BriefBar's updater (see UpdaterController). Writing to BriefBar after it quit fails, instead of ending this.
signal(SIGPIPE, SIG_IGN)

// `--hello`: for `BriefBar --check-updater`, which shows how macOS treats the updater.
if CommandLine.arguments.contains("--hello") {
    exit(UpdaterChannel.hello())
}

MainActor.assumeIsolated {
    guard let host = UpdaterController.hostBundle() else {
        exit(1)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = UpdaterController(host: host)
    app.delegate = controller
    withExtendedLifetime(controller) {
        app.run()
    }
}
