import BriefBarCore
import Foundation

/// BriefBar's plugin among the Copilot CLI's plugins, which the GitHub Copilot app's sessions load too. It gives them
/// BriefBar's skill, `/briefbar`, which uses BriefBar's MCP server (`CopilotMCPRegistration`). The plugin comes with
/// BriefBar.app, in a marketplace of its own on this Mac (`Contents/Resources/CopilotPlugin`), which the CLI loads in
/// place: nothing is copied, and it updates with BriefBar. BriefBar asks the CLI itself (`copilot plugin marketplace
/// list`, `add` and `remove`, and `copilot plugin list`, `install` and `uninstall`), and never reads or writes its
/// files, where other plugins' and marketplaces' settings are.
public struct CopilotPluginRegistration: Sendable {
    /// The name of BriefBar's marketplace, and of its plugin.
    public static let name = "briefbar"
    /// The plugin, as the CLI names it: plugin@marketplace.
    static let plugin = "\(name)@\(name)"
    /// The folder in BriefBar.app's resources that holds the marketplace.
    public static let folderName = "CopilotPlugin"

    public enum Status: Sendable, Equatable {
        /// There's no Copilot CLI.
        case noCLI
        /// The CLI doesn't have BriefBar's plugin.
        case absent
        /// It loads this BriefBar's plugin, unless it's turned off there (`copilot plugin disable`, or the app's
        /// Customize).
        case installed(enabled: Bool)
        /// It loads the plugin of another copy of BriefBar, from this folder.
        case installedElsewhere(String)
        /// It has a marketplace by BriefBar's name that isn't BriefBar's.
        case taken
        /// The CLI couldn't say, or couldn't change it.
        case failed(String)
    }

    /// `copilot`.
    let cli: URL
    /// Your login shell's, so the CLI uses the same settings as in Terminal, COPILOT_HOME included.
    let environment: [String: String]
    /// The marketplace in this copy of BriefBar, or nil for a build without one, which can only remove another copy's.
    let marketplace: URL?
    let runner: any ProcessRunning

    public init(
        cli: URL, environment: [String: String], marketplace: URL?, runner: any ProcessRunning = ProcessRunner()
    ) {
        self.cli = cli
        self.environment = environment
        self.marketplace = marketplace
        self.runner = runner
    }

    /// With the Copilot CLI, and your login shell's environment, that `registration` found.
    public init(cli registration: CopilotMCPRegistration, marketplace: URL?) {
        self.init(
            cli: registration.cli, environment: registration.environment, marketplace: marketplace,
            runner: registration.runner
        )
    }

    /// The marketplace in BriefBar.app, when this copy of BriefBar has one.
    public static func marketplace(in bundle: Bundle = .main) -> URL? {
        guard let folder = bundle.resourceURL?.appendingPathComponent(folderName, isDirectory: true),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("marketplace.json").path)
        else { return nil }
        return folder
    }

    /// The CLI takes a few seconds to start.
    static let timeout: TimeInterval = 30

    /// What the CLI has by BriefBar's name.
    struct Found: Equatable {
        enum Marketplace: Equatable {
            case none
            /// This copy of BriefBar's.
            case this
            /// Another copy of BriefBar's, in this folder.
            case elsewhere(String)
            /// One that isn't BriefBar's.
            case other
        }

        var marketplace: Marketplace
        /// Whether the plugin is turned on there, or nil when the CLI doesn't list it.
        var plugin: Bool?

        var status: Status {
            switch marketplace {
            case .none: return .absent
            case .other: return .taken
            case .this: return plugin.map { .installed(enabled: $0) } ?? .absent
            case .elsewhere(let folder): return plugin == nil ? .absent : .installedElsewhere(folder)
            }
        }
    }

    public func status() async -> Status {
        switch await find() {
        case .success(let found): return found.status
        case .failure(let failure): return failure.status
        }
    }

    /// Installs this BriefBar's plugin, or turns it back on, in place of another copy's. A marketplace by its name that
    /// isn't BriefBar's stays.
    public func install() async -> Status {
        guard let marketplace else { return .failed("This copy of BriefBar has no plugin to install.") }
        // The CLI loads the plugin from where it is, so it has to stay there.
        if Self.isTemporary(marketplace) {
            return .failed("""
                BriefBar runs from a temporary copy, as it was opened where it was downloaded: move it to \
                Applications, open it there, and try again.
                """)
        }
        let found: Found
        switch await find() {
        case .success(let value): found = value
        case .failure(let failure): return failure.status
        }
        switch found.marketplace {
        case .other:
            return .taken
        case .elsewhere:
            if let failure = await removeFound(found) { return failure }
            fallthrough
        case .none:
            if let failure = await change(["plugin", "marketplace", "add", marketplace.path]) { return failure }
        case .this:
            break
        }
        if let failure = await change(["plugin", "install", Self.plugin]) { return failure }
        return await status()
    }

    /// Removes BriefBar's plugin and its marketplace, whichever copy's they are. One by its name that isn't BriefBar's
    /// stays.
    public func remove() async -> Status {
        switch await find() {
        case .success(let found):
            if case .other = found.marketplace { return .taken }
            if case .none = found.marketplace { return .absent }
            if let failure = await removeFound(found) { return failure }
            return await status()
        case .failure(let failure):
            return failure.status
        }
    }

    /// Turns the plugin off, so that it stays off if its marketplace comes back, then removes the marketplace.
    private func removeFound(_ found: Found) async -> Status? {
        if found.plugin != nil, let failure = await change(["plugin", "uninstall", Self.plugin]) { return failure }
        return await change(["plugin", "marketplace", "remove", Self.name, "--force"])
    }

    // MARK: The CLI

    /// Why the CLI couldn't say.
    struct Failure: Error {
        var status: Status
    }

    /// What the CLI's marketplaces and plugins say about BriefBar's.
    func find() async -> Result<Found, Failure> {
        let marketplaces: [[String: Any]]
        switch await list(["plugin", "marketplace", "list", "--json"]) {
        case .success(let rows): marketplaces = rows
        case .failure(let failure): return .failure(failure)
        }
        guard let row = marketplaces.first(where: { $0["name"] as? String == Self.name }) else {
            return .success(Found(marketplace: .none))
        }
        let plugins: [[String: Any]]
        switch await list(["plugin", "list", "--json"]) {
        case .success(let rows): plugins = rows
        case .failure(let failure): return .failure(failure)
        }
        let plugin = plugins.first { $0["name"] as? String == Self.name && $0["marketplace"] as? String == Self.name }
        // Where the CLI loads the plugin from, or else where the marketplace is.
        let folder = (plugin?["installedFrom"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (row["source"] as? String).flatMap(Self.localFolder)
        let enabled = plugin.map { $0["enabled"] as? Bool ?? true }
        return .success(Found(marketplace: Self.marketplace(folder, this: marketplace), plugin: enabled))
    }

    private func list(_ arguments: [String]) async -> Result<[[String: Any]], Failure> {
        let result: ProcessResult
        do {
            result = try await runner.run(cli, arguments: arguments, environment: environment, timeout: Self.timeout)
        } catch {
            return .failure(Failure(status: .failed(String(describing: error))))
        }
        guard result.status == 0 else { return .failure(Failure(status: Self.failure(result))) }
        guard let rows = Self.rows(in: result.stdout) else {
            return .failure(Failure(status: .failed("The Copilot CLI's answer couldn't be read.")))
        }
        return .success(rows)
    }

    /// Nil once done, or why not.
    private func change(_ arguments: [String]) async -> Status? {
        do {
            let result = try await runner.run(cli, arguments: arguments, environment: environment, timeout: Self.timeout)
            guard result.status == 0 else { return Self.failure(result) }
            return nil
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// Whose a marketplace by BriefBar's name is, by its folder: BriefBar's is a folder named `CopilotPlugin`.
    static func marketplace(_ folder: String?, this: URL?) -> Found.Marketplace {
        guard let folder, URL(fileURLWithPath: folder).lastPathComponent == folderName else { return .other }
        if let this, CopilotMCPRegistration.isSameFile(folder, this.path) { return .this }
        return .elsewhere(folder)
    }

    /// Whether BriefBar runs from where macOS moved it for now, as it does with an app opened where it was downloaded
    /// (App Translocation), rather than from where it's installed.
    static func isTemporary(_ folder: URL) -> Bool {
        folder.pathComponents.contains("AppTranslocation")
    }

    /// The folder of a marketplace on this Mac, as `copilot plugin marketplace list` describes it (`Local: /path`), or
    /// nil for one elsewhere, such as on GitHub.
    static func localFolder(_ source: String) -> String? {
        let path = source.hasPrefix("Local: ") ? String(source.dropFirst("Local: ".count)) : source
        return path.hasPrefix("/") ? path : nil
    }

    /// The JSON array in the output, after anything the CLI printed before it.
    static func rows(in output: Data) -> [[String: Any]]? {
        if let rows = try? JSONSerialization.jsonObject(with: output) as? [[String: Any]] { return rows }
        guard let start = output.firstIndex(of: UInt8(ascii: "[")) else { return nil }
        return try? JSONSerialization.jsonObject(with: output[start...]) as? [[String: Any]]
    }

    /// Why the CLI failed, from the first line it printed.
    private static func failure(_ result: ProcessResult) -> Status {
        .failed(firstLine(result.stderr) ?? "It ended with status \(result.status).")
    }

    /// What went wrong, from what the CLI printed, such as `Failed to add marketplace: Error: Request
    /// plugins.marketplaces.add failed with message: …`: the message alone, when there's one.
    static func firstLine(_ data: Data) -> String? {
        guard let line = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }
        if let message = line.range(of: "failed with message: "), !line[message.upperBound...].isEmpty {
            return String(line[message.upperBound...])
        }
        return line.hasPrefix("Error: ") ? String(line.dropFirst("Error: ".count)) : line
    }
}
