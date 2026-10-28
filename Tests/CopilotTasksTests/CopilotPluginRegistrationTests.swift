import BriefBarCore
import Foundation
import Synchronization
import Testing
@testable import CopilotTasks

/// BriefBar's plugin among the Copilot CLI's, through `copilot plugin marketplace` and `copilot plugin`, against a
/// made-up CLI that behaves as Copilot CLI 1.0.105 does with a marketplace in a folder.
@Suite struct CopilotPluginRegistrationTests {
    private static let here = URL(fileURLWithPath: "/Applications/BriefBar.app/Contents/Resources/CopilotPlugin")

    /// Folders that a marketplace named briefbar could be in, made up in a temporary folder: another copy of BriefBar,
    /// and others that only look like one.
    struct Folders {
        let root: URL

        init() throws {
            root = try makeTemporaryDirectory()
            try Self.app(at: otherCopyApp, identifier: CopilotPluginRegistration.bundleIdentifier)
            try Self.app(at: otherApp, identifier: "com.example.Notes")
            try Self.marketplace(at: URL(fileURLWithPath: lookalike))
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        /// Another copy of BriefBar.app, such as one you built.
        var otherCopyApp: URL { root.appendingPathComponent("build/BriefBar.app", isDirectory: true) }
        var otherCopy: String { otherCopyApp.appendingPathComponent("Contents/Resources/CopilotPlugin").path }
        /// Another app, with a marketplace in the same place as BriefBar's.
        var otherApp: URL { root.appendingPathComponent("Notes.app", isDirectory: true) }
        var inOtherApp: String { otherApp.appendingPathComponent("Contents/Resources/CopilotPlugin").path }
        /// A folder of someone's own, which is named like BriefBar's.
        var lookalike: String { root.appendingPathComponent("plugins/CopilotPlugin").path }
        /// Where a copy of BriefBar was, before it was deleted or moved.
        var gone: String { root.appendingPathComponent("Old/BriefBar.app/Contents/Resources/CopilotPlugin").path }

        private static func app(at app: URL, identifier: String) throws {
            try marketplace(at: app.appendingPathComponent("Contents/Resources/CopilotPlugin", isDirectory: true))
            let info = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL"], format: .xml, options: 0
            )
            try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        }

        private static func marketplace(at folder: URL) throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(#"{"name":"briefbar","owner":{"name":"Someone"},"plugins":[]}"#.utf8)
                .write(to: folder.appendingPathComponent("marketplace.json"))
        }
    }

    /// What the made-up CLI keeps: its marketplaces' sources by name, whether each plugin is turned on, by
    /// plugin@marketplace, as its settings keep them, and the commands that fail once, by their first arguments.
    struct State: Sendable, Equatable {
        var marketplaces: [String: String] = [:]
        var plugins: [String: Bool] = [:]
        var failures: [[String]: String] = [:]
    }

    /// A CLI with these marketplaces and plugins, which changes them as asked, and fails where the real one does.
    final class CLI: Sendable {
        let runner: FakeRunner
        private let state: Box

        final class Box: Sendable {
            let mutex: Mutex<State>

            init(_ state: State) {
                mutex = Mutex(state)
            }
        }

        init(_ initial: State = State()) {
            let box = Box(initial)
            state = box
            runner = FakeRunner { arguments in
                box.mutex.withLock { CLI.answer(arguments, &$0) }
            }
        }

        var current: State { state.mutex.withLock { $0 } }

        func registration(marketplace: URL? = CopilotPluginRegistrationTests.here) -> CopilotPluginRegistration {
            CopilotPluginRegistration(
                cli: URL(fileURLWithPath: "/opt/homebrew/bin/copilot"), environment: [:], marketplace: marketplace, runner: runner
            )
        }

        private static func json(_ object: Any) -> ProcessResult {
            .ok(String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]), as: UTF8.self))
        }

        private static func failed(_ request: String, _ message: String) -> ProcessResult {
            .failure("Failed to \(request): Error: Request plugins.\(request) failed with message: \(message)\n", status: 1)
        }

        static func answer(_ arguments: [String], _ state: inout State) -> ProcessResult {
            if let key = state.failures.keys.first(where: { arguments.starts(with: $0) }),
               let message = state.failures.removeValue(forKey: key) {
                return failed(key.dropFirst().joined(separator: "."), message)
            }
            switch arguments {
            case ["plugin", "marketplace", "list", "--json"]:
                return json(state.marketplaces.sorted { $0.key < $1.key }.map { ["name": $0.key, "source": $0.value, "isDefault": false] }
                    + [["name": "awesome-copilot", "source": "GitHub: github/awesome-copilot", "isDefault": true]])
            case ["plugin", "list", "--json"]:
                // A plugin is listed while its marketplace is there; it remembers whether it's on either way.
                let rows: [[String: Any]] = state.plugins.keys.sorted().compactMap { id in
                    let parts = id.split(separator: "@").map(String.init)
                    guard let source = state.marketplaces[parts[1]] else { return nil }
                    var row: [String: Any] = ["name": parts[0], "marketplace": parts[1], "enabled": state.plugins[id]!, "source": "live"]
                    if source.hasPrefix("Local: ") { row["installedFrom"] = String(source.dropFirst("Local: ".count)) }
                    return row
                }
                return json(rows + [["name": "browser-use", "marketplace": "", "version": "0.0.4", "enabled": false, "source": "builtin"]])
            case _ where arguments.prefix(3) == ["plugin", "marketplace", "add"] && arguments.count == 4:
                // Its marketplace.json names it briefbar.
                guard state.marketplaces["briefbar"] == nil else {
                    return failed("marketplaces.add", "Marketplace \"briefbar\" already registered")
                }
                state.marketplaces["briefbar"] = "Local: \(arguments[3])"
                return .ok("Marketplace \"briefbar\" added successfully.\n")
            case _ where arguments.prefix(3) == ["plugin", "marketplace", "remove"]:
                let name = arguments[3]
                guard state.marketplaces.removeValue(forKey: name) != nil else {
                    return failed("marketplaces.remove", "Marketplace \"\(name)\" is not registered")
                }
                // With --force, it uninstalls whatever plugins came from it, whoever's they are.
                if arguments.contains("--force") {
                    state.plugins = state.plugins.filter { !$0.key.hasSuffix("@\(name)") }
                }
                return .ok("Marketplace \"\(name)\" removed successfully.\n")
            case ["plugin", "install", "briefbar@briefbar"]:
                guard state.marketplaces["briefbar"] != nil else { return failed("install", "Marketplace \"briefbar\" not found") }
                state.plugins["briefbar@briefbar"] = true
                return .ok("Plugin \"briefbar\" installed successfully. Installed 1 skill.\n")
            case ["plugin", "uninstall", "briefbar@briefbar"]:
                // A plugin loaded in place is only turned off.
                state.plugins["briefbar@briefbar"] = false
                return .ok("Plugin \"briefbar@briefbar\" disabled. It is still on disk — nothing was removed.\n")
            default:
                return .failure("unexpected: \(arguments.joined(separator: " "))", status: 2)
            }
        }
    }

    static func installed(at folder: String = here.path, enabled: Bool = true) -> State {
        State(marketplaces: ["briefbar": "Local: \(folder)"], plugins: ["briefbar@briefbar": enabled])
    }

    static func changes(_ cli: CLI) -> [[String]] {
        cli.runner.arguments.filter { !$0.contains("--json") }
    }

    @Test func tellsWhoseAMarketplaceIs() throws {
        let folders = try Folders()
        defer { folders.remove() }
        typealias Registration = CopilotPluginRegistration
        func whose(_ folder: String?, this: URL? = Self.here) -> Registration.Found.Marketplace {
            Registration.marketplace(folder, this: this, bundleIdentifier: Registration.bundleIdentifier)
        }
        #expect(whose(Self.here.path) == .this)
        #expect(whose(Self.here.path + "/") == .this)
        // Another copy of BriefBar.app, by its bundle identifier, also for a build without a plugin of its own.
        #expect(whose(folders.otherCopy) == .elsewhere(folders.otherCopy))
        #expect(whose(folders.otherCopy, this: nil) == .elsewhere(folders.otherCopy))
        // Neither its name nor its folder's makes one BriefBar's.
        #expect(whose(folders.lookalike) == .other)
        #expect(whose(folders.inOtherApp) == .other)
        #expect(whose(folders.gone) == .other)
        #expect(whose(nil) == .other)
        #expect(Registration.marketplace(folders.otherCopy, this: Self.here, bundleIdentifier: "com.example.Notes") == .other)

        #expect(Registration.app(holding: URL(fileURLWithPath: folders.otherCopy))?.standardizedFileURL == folders.otherCopyApp.standardizedFileURL)
        #expect(Registration.app(holding: URL(fileURLWithPath: folders.lookalike)) == nil)
        #expect(Registration.identifier(of: folders.otherApp) == "com.example.Notes")
        #expect(Registration.identifier(of: folders.root) == nil)

        #expect(Registration.localFolder("Local: /tmp/CopilotPlugin") == "/tmp/CopilotPlugin")
        #expect(Registration.localFolder("/tmp/CopilotPlugin") == "/tmp/CopilotPlugin")
        #expect(Registration.localFolder("GitHub: someone/briefbar") == nil)
        #expect(Registration.localFolder("Git: https://example.com/briefbar.git") == nil)

        // Whatever it printed before its answer.
        #expect(Registration.rows(in: Data("A newer version is out.\n[{\"name\":\"briefbar\"}]".utf8))?.count == 1)
        #expect(Registration.rows(in: Data("nope".utf8)) == nil)

        #expect(Registration.firstLine(Data("Failed to add marketplace: Error: Request plugins.marketplaces.add failed with message: Marketplace \"briefbar\" already registered\n".utf8))
            == "Marketplace \"briefbar\" already registered")
        #expect(Registration.firstLine(Data("\nError: Not signed in.\n".utf8)) == "Not signed in.")
    }

    @Test func readsWhatTheCLISays() async throws {
        let folders = try Folders()
        defer { folders.remove() }
        #expect(await CLI().registration().status() == .absent)
        #expect(await CLI(Self.installed()).registration().status() == .installed(enabled: true))
        #expect(await CLI(Self.installed(enabled: false)).registration().status() == .installed(enabled: false))
        #expect(await CLI(Self.installed(at: folders.otherCopy)).registration().status() == .installedElsewhere(folders.otherCopy))
        // Its marketplace, without the plugin.
        #expect(await CLI(State(marketplaces: ["briefbar": "Local: \(Self.here.path)"])).registration().status() == .absent)
        #expect(await CLI(State(marketplaces: ["briefbar": "GitHub: someone/briefbar"])).registration().status() == .taken)
        #expect(await CLI(Self.installed(at: folders.lookalike)).registration().status() == .taken)
    }

    @Test func installsItWhenItsAbsent() async {
        let cli = CLI()
        #expect(await cli.registration().install() == .installed(enabled: true))
        #expect(Self.changes(cli) == [["plugin", "marketplace", "add", Self.here.path], ["plugin", "install", "briefbar@briefbar"]])
        // Again: nothing to add.
        let before = Self.changes(cli).count
        #expect(await cli.registration().install() == .installed(enabled: true))
        #expect(Self.changes(cli).dropFirst(before) == [["plugin", "install", "briefbar@briefbar"]])
    }

    @Test func turnsItBackOn() async {
        let cli = CLI(Self.installed(enabled: false))
        #expect(await cli.registration().install() == .installed(enabled: true))
        #expect(Self.changes(cli) == [["plugin", "install", "briefbar@briefbar"]])
    }

    @Test func replacesAnotherCopysPlugin() async throws {
        let folders = try Folders()
        defer { folders.remove() }
        let cli = CLI(Self.installed(at: folders.otherCopy))
        #expect(await cli.registration().install() == .installed(enabled: true))
        #expect(Self.changes(cli) == [
            ["plugin", "uninstall", "briefbar@briefbar"], ["plugin", "marketplace", "remove", "briefbar"],
            ["plugin", "marketplace", "add", Self.here.path], ["plugin", "install", "briefbar@briefbar"],
        ])
        #expect(cli.current.marketplaces == ["briefbar": "Local: \(Self.here.path)"])
    }

    /// A marketplace named briefbar that BriefBar can't tell is its own: on GitHub, in a folder of someone's own named
    /// like BriefBar's, in another app, or where a copy of BriefBar was. Neither Install nor turning agents off touches
    /// it, or the plugins it has.
    @Test func leavesAMarketplaceThatIsntBriefBars() async throws {
        let folders = try Folders()
        defer { folders.remove() }
        for source in ["GitHub: someone/briefbar", "Local: \(folders.lookalike)", "Local: \(folders.inOtherApp)", "Local: \(folders.gone)"] {
            let theirs = State(marketplaces: ["briefbar": source], plugins: ["briefbar@briefbar": true, "helper@briefbar": true])
            let cli = CLI(theirs)
            #expect(await cli.registration().status() == .taken, "\(source)")
            #expect(await cli.registration().install() == .taken, "\(source)")
            #expect(await cli.registration().remove() == .taken, "\(source)")
            #expect(await cli.registration(marketplace: nil).remove() == .taken, "\(source)")
            #expect(Self.changes(cli).isEmpty, "\(source): \(Self.changes(cli))")
            #expect(cli.current == theirs, "\(source)")
        }
    }

    @Test func removesWhicheverCopyItIs() async throws {
        let folders = try Folders()
        defer { folders.remove() }
        let cli = CLI(Self.installed(at: folders.otherCopy))
        #expect(await cli.registration().remove() == .absent)
        #expect(Self.changes(cli) == [["plugin", "uninstall", "briefbar@briefbar"], ["plugin", "marketplace", "remove", "briefbar"]])
        // Turned off, so that it doesn't come back on by itself with its marketplace.
        #expect(cli.current == State(plugins: ["briefbar@briefbar": false]))
        #expect(await cli.registration().remove() == .absent)
        #expect(Self.changes(cli).count == 2)
    }

    @Test func removesItsMarketplaceWithoutThePlugin() async {
        let cli = CLI(State(marketplaces: ["briefbar": "Local: \(Self.here.path)"]))
        #expect(await cli.registration().remove() == .absent)
        #expect(Self.changes(cli) == [["plugin", "marketplace", "remove", "briefbar"]])
    }

    /// `--force` would uninstall whatever else a marketplace had: BriefBar's has only its plugin, and BriefBar never
    /// passes it, so that the CLI refuses instead if it's wrong about that.
    @Test func neverForcesARemoval() async throws {
        let folders = try Folders()
        defer { folders.remove() }
        var state = Self.installed(at: folders.otherCopy)
        state.plugins["helper@briefbar"] = true
        let cli = CLI(state)
        #expect(await cli.registration().install() == .installed(enabled: true))
        #expect(await cli.registration().remove() == .absent)
        #expect(!cli.runner.arguments.contains { $0.contains("--force") })
        #expect(cli.current.plugins["helper@briefbar"] == true)
    }

    @Test func installsOnlyAPluginItHas() async throws {
        let folders = try Folders()
        defer { folders.remove() }
        let cli = CLI(Self.installed(at: folders.otherCopy))
        #expect(await cli.registration(marketplace: nil).status() == .installedElsewhere(folders.otherCopy))
        #expect(await cli.registration(marketplace: nil).install() == .failed("This copy of BriefBar has no plugin to install."))
        #expect(Self.changes(cli).isEmpty)
        // It can still take another copy's away.
        #expect(await cli.registration(marketplace: nil).remove() == .absent)
    }

    @Test func installsOnlyFromWhereBriefBarStays() async {
        let cli = CLI()
        let temporary = URL(fileURLWithPath: "/private/var/folders/xy/T/AppTranslocation/1A2B/d/BriefBar.app/Contents/Resources/CopilotPlugin")
        if case .failed = await cli.registration(marketplace: temporary).install() {} else {
            Issue.record("Installed the plugin of a copy that macOS runs from a temporary place")
        }
        #expect(Self.changes(cli).isEmpty)
        #expect(!CopilotPluginRegistration.isTemporary(Self.here))
    }

    @Test func saysWhyTheCLICouldnt() async {
        let runner = FakeRunner { _ in
            .failure("Failed to list marketplaces: Error: Request plugins.marketplaces.list failed with message: Couldn't read the settings\n", status: 1)
        }
        let registration = CopilotPluginRegistration(
            cli: URL(fileURLWithPath: "/opt/homebrew/bin/copilot"), environment: [:], marketplace: Self.here, runner: runner
        )
        #expect(await registration.status() == .failed("Couldn't read the settings"))
        #expect(await registration.install() == .failed("Couldn't read the settings"))
        #expect(await registration.remove() == .failed("Couldn't read the settings"))
    }

    @Test func findsTheMarketplaceInBriefBarApp() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appendingPathComponent("BriefBar.app", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>test.briefbar</string></dict></plist>".utf8)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let bundle = try #require(Bundle(url: app))
        #expect(CopilotPluginRegistration.marketplace(in: bundle) == nil)

        let marketplace = resources.appendingPathComponent("CopilotPlugin", isDirectory: true)
        try FileManager.default.createDirectory(at: marketplace, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: marketplace.appendingPathComponent("marketplace.json"))
        #expect(CopilotPluginRegistration.marketplace(in: bundle)?.standardizedFileURL.path == marketplace.standardizedFileURL.path)
    }
}
