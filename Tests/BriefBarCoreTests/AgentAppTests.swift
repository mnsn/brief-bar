import Foundation
import Testing
@testable import BriefBarCore

/// The links that ask VS Code and Cursor to add BriefBar, as their own link generators make them, read back the way
/// each app reads them.
@Suite struct AgentAppTests {
    private static let briefBar = "/Applications/BriefBar.app/Contents/MacOS/BriefBar"

    private static func link(_ app: AgentApp, _ command: String = briefBar) -> URL? {
        app.installLink(server: "briefbar", command: command, arguments: ["--mcp"])
    }

    /// The link's query, as it is.
    private static func query(_ link: URL) -> String {
        String(link.absoluteString.split(separator: "?", maxSplits: 1)[1])
    }

    /// What VS Code installs: the query, decoded as it parses the link, then again (`decodeURIComponent`), as JSON.
    private static func vsCodeServer(_ link: URL) throws -> [String: Any] {
        let json = try #require(query(link).removingPercentEncoding?.removingPercentEncoding)
        return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    /// What Cursor installs: the query, decoded as VS Code, which Cursor is built on, parses the link, then read as a
    /// form's (`URLSearchParams`), where `+` is a space, and its config from Base64, as JSON.
    private static func cursorServer(_ link: URL) throws -> (name: String?, config: [String: Any]) {
        let decoded = try #require(query(link).removingPercentEncoding)
        var parameters: [String: String] = [:]
        for pair in decoded.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            parameters[parts[0]] = parts.count > 1 ? parts[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding : ""
        }
        let base64 = try #require(parameters["config"])
        let config = try #require(Data(base64Encoded: base64))
        return (parameters["name"], try #require(try JSONSerialization.jsonObject(with: config) as? [String: Any]))
    }

    @Test func vsCodesLink() throws {
        let link = try #require(Self.link(.visualStudioCode))
        #expect(link.absoluteString == "vscode:mcp/install?%7B%22args%22%3A%5B%22--mcp%22%5D%2C%22command%22%3A%22%2FApplications"
            + "%2FBriefBar.app%2FContents%2FMacOS%2FBriefBar%22%2C%22name%22%3A%22briefbar%22%2C%22type%22%3A%22stdio%22%7D")
        let server = try Self.vsCodeServer(link)
        #expect(server["name"] as? String == "briefbar")
        #expect(server["type"] as? String == "stdio")
        #expect(server["command"] as? String == Self.briefBar)
        #expect(server["args"] as? [String] == ["--mcp"])
    }

    @Test func cursorsLink() throws {
        let link = try #require(Self.link(.cursor))
        #expect(link.absoluteString == "cursor://anysphere.cursor-deeplink/mcp/install?name=briefbar&config="
            + "eyJhcmdzIjpbIi0tbWNwIl0sImNvbW1hbmQiOiIvQXBwbGljYXRpb25zL0JyaWVmQmFyLmFwcC9Db250ZW50cy9NYWNPUy9CcmllZkJhciJ9")
        let server = try Self.cursorServer(link)
        #expect(server.name == "briefbar")
        #expect(server.config["command"] as? String == Self.briefBar)
        #expect(server.config["args"] as? [String] == ["--mcp"])
    }

    /// Paths with spaces, an apostrophe, a `%` and letters beyond ASCII, whose Base64, for Cursor, has a `+` and padding,
    /// or a `/`.
    @Test(arguments: [
        "/Users/me/Apps ~/Brief Bar.app/Contents/MacOS/BriefBar",
        "/Users/zoë/Apps ~/Brief Bar's.app/Contents/MacOS/BriefBar",
        "/Users/me/100% (new)/BriefBar.app/Contents/MacOS/BriefBar",
    ])
    func anyPathArrivesAsItIs(_ path: String) throws {
        let vsCode = try Self.vsCodeServer(try #require(Self.link(.visualStudioCode, path)))
        #expect(vsCode["command"] as? String == path)
        #expect(vsCode["args"] as? [String] == ["--mcp"])
        let cursor = try Self.cursorServer(try #require(Self.link(.cursor, path)))
        #expect(cursor.config["command"] as? String == path)
        #expect(cursor.config["args"] as? [String] == ["--mcp"])
    }

    @Test func plusInCursorsConfigIsEncodedTwice() throws {
        let link = try #require(Self.link(.cursor, "/Users/me/Apps ~/Brief Bar.app/Contents/MacOS/BriefBar"))
        #expect(link.absoluteString.contains("%252B"))
        #expect(link.absoluteString.hasSuffix("%3D%3D"))
    }

    @Test func gitHubCopilotTakesNoLink() {
        #expect(Self.link(.gitHubCopilot) == nil)
    }

    @Test func encodesAsJavaScriptDoes() {
        #expect(AgentApp.encodeURIComponent("Az09-_.!~*'()") == "Az09-_.!~*'()")
        #expect(AgentApp.encodeURIComponent("a b/c+d=e&f?ë%") == "a%20b%2Fc%2Bd%3De%26f%3F%C3%AB%25")
    }
}
