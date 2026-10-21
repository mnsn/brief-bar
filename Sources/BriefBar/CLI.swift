import BriefBarCore
import BriefBarUI
import Foundation

/// Command-line modes, mainly for checking what the menu bar would show.
@MainActor
enum CLI {
    static var usage: String {
        var lines = [
            "BriefBar: what needs you, from the apps you choose, in the macOS menu bar.",
            "",
            "Usage: BriefBar [--source <name>]… [option]",
            "  (no option)        Run the menu-bar app",
            "  --dump             Print what each source shows",
            "  --json             Print the same as JSON, by source, each with its counts",
            "  --watch            Print changes as they happen (Ctrl-C to stop)",
            "  --render <dir>     Draw the menu bar with each list open, the widgets and Settings into PNGs",
            "                     (light and dark)",
            "  --source <name>    Only this source: teams, ado or copilot (repeatable). Without it, the modes",
            "                     cover the sources that are on in the app.",
            "  --demo             Use made-up data for every source, with any of the above or the app",
            "  --help             Show this help",
        ]
        for commandLine in SourceCatalog.commandLines where !commandLine.usage.isEmpty {
            lines.append("")
            lines.append(commandLine.usage)
        }
        lines += [
            "",
            "Their output shows your own names, messages and titles, so keep it to yourself.",
        ]
        return lines.joined(separator: "\n")
    }

    /// Returns an exit code for command-line modes, or nil to launch the app.
    static func run(_ arguments: [String]) -> Int32? {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return 0
        }
        let commandLines = SourceCatalog.commandLines
        let ownFlags = commandLines.flatMap { $0.flags }
        let modes = ["--dump", "--json", "--watch"]
        guard arguments.contains(where: { modes.contains($0) || ownFlags.contains($0) }) else { return nil }
        let options = CommandLineOptions(arguments: arguments, demo: arguments.contains("--demo"))

        // A source's own modes imply that source.
        for commandLine in commandLines where commandLine.flags.contains(where: arguments.contains) {
            if let code = commandLine.run(options) { return code }
        }

        let named: [SourceID]
        do {
            named = try sources(named: arguments)
        } catch {
            fputs("\(error)\n", stderr)
            return 2
        }
        let selected = commandLines.filter { commandLine in
            if !named.isEmpty { return named.contains(commandLine.source) }
            if options.demo { return true }
            return isOnInTheApp(commandLine)
        }
        guard !selected.isEmpty else {
            fputs("Nothing is on in BriefBar. Choose a source with --source teams, ado or copilot.\n", stderr)
            return 1
        }

        if arguments.contains("--json") {
            var output: [String: Any] = [:]
            var status: Int32 = 0
            for commandLine in selected {
                if let object = commandLine.json(options) {
                    output[commandLine.source.rawValue] = object
                } else {
                    status = 1
                }
            }
            guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) else {
                return 1
            }
            FileHandle.standardOutput.write(data)
            print()
            return status
        }
        if arguments.contains("--dump") {
            var status: Int32 = 0
            for (index, commandLine) in selected.enumerated() {
                if selected.count > 1 {
                    if index > 0 { print() }
                    print("== \(name(of: commandLine.source)) ==")
                }
                status = max(status, commandLine.dump(options))
            }
            return status
        }
        // --watch
        var keepsWatching = false
        for commandLine in selected {
            keepsWatching = commandLine.watch(options) || keepsWatching
        }
        guard keepsWatching else { return 0 }
        dispatchMain()
    }

    struct UnknownSource: Error, CustomStringConvertible {
        var name: String
        var description: String { "Unknown source \"\(name)\": use teams, ado or copilot." }
    }

    /// The sources that `--source` names.
    static func sources(named arguments: [String]) throws -> [SourceID] {
        var names: [SourceID] = []
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--source" {
                guard index + 1 < arguments.count else { throw UnknownSource(name: "") }
                let name = arguments[index + 1]
                switch name.lowercased() {
                case "teams": names.append(.teams)
                case "ado", "azuredevops", "azure-devops", "devops": names.append(.azureDevOps)
                case "copilot": names.append(.copilot)
                default: throw UnknownSource(name: name)
                }
                index += 1
            }
            index += 1
        }
        return names
    }

    /// Whether the source is on in the installed app.
    private static func isOnInTheApp(_ commandLine: any SourceCommandLine.Type) -> Bool {
        guard let defaults = AppIdentity.installedAppDefaults else { return false }
        return SourceChoices.load(from: defaults).state(of: commandLine.source, version: commandLine.descriptionVersion) == .on
    }

    private static func name(of source: SourceID) -> String {
        switch source {
        case .teams: return "Microsoft Teams"
        case .azureDevOps: return "Azure DevOps"
        case .copilot: return "GitHub Copilot"
        }
    }
}
