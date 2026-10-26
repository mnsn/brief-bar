import Foundation

/// The agents' apps that Settings › Agents can install BriefBar in, when they're on this Mac. VS Code and Cursor each
/// take a link that asks them to add a local MCP server: the app shows what it would add, asks you first, and keeps it
/// in its own settings, which BriefBar never reads or writes. The GitHub Copilot app takes no link: its sessions use the
/// Copilot CLI's MCP servers, which BriefBar adds itself to with the CLI's own commands (`CopilotMCPRegistration`).
public enum AgentApp: String, CaseIterable, Identifiable, Sendable {
    case visualStudioCode
    case cursor
    case gitHubCopilot

    public var id: Self { self }

    public var name: String {
        switch self {
        case .visualStudioCode: return "Visual Studio Code"
        case .cursor: return "Cursor"
        case .gitHubCopilot: return "GitHub Copilot"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .visualStudioCode: return "com.microsoft.VSCode"
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .gitHubCopilot: return "com.github.githubapp"
        }
    }

    /// The link that asks the app to add a local MCP server, by this name, that runs the command with these arguments,
    /// as the app's own link generator makes it; none for GitHub Copilot.
    public func installLink(server name: String, command: String, arguments: [String]) -> URL? {
        switch self {
        case .visualStudioCode:
            // The server as JSON: `vscode:mcp/install?{json}`. VS Code decodes the query twice, so `%` is encoded twice.
            guard let json = Self.json(Server(name: name, type: "stdio", command: command, args: arguments)) else { return nil }
            return URL(string: "vscode:mcp/install?" + Self.encodeURIComponent(json.replacingOccurrences(of: "%", with: "%25")))
        case .cursor:
            // The server as JSON, in Base64. Cursor decodes the query twice, and the second time reads a `+` as a space,
            // so `+` is encoded twice.
            guard let json = Self.json(Server(command: command, args: arguments)) else { return nil }
            let config = Data(json.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "%2B")
            return URL(string: "cursor://anysphere.cursor-deeplink/mcp/install?name=\(Self.encodeURIComponent(name))"
                + "&config=\(Self.encodeURIComponent(config))")
        case .gitHubCopilot:
            return nil
        }
    }

    private struct Server: Encodable {
        var name: String?
        var type: String?
        var command: String
        var args: [String]
    }

    private static func json(_ server: Server) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(server)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// What JavaScript's `encodeURIComponent` leaves as it is, which both apps' link generators use.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
    )

    static func encodeURIComponent(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }
}
