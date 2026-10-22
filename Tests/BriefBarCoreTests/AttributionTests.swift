import Darwin
import Foundation
import Testing
@testable import BriefBarCore

/// Whose permissions BriefBar runs with decides whether its command-line modes run, and whether its environment
/// may point it at other data: these give it what macOS would say in each case.
@Suite struct AttributionTests {
    private let pid: pid_t = 500
    private let briefBar = "/Applications/BriefBar.app/Contents/MacOS/BriefBar"

    private func attribution(_ responsible: Attribution.Responsible?) -> Attribution {
        Attribution(pid: pid, executable: briefBar, responsible: responsible)
    }

    @Test func runFromAShellHasThatAppsPermissions() {
        let terminal = "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"
        #expect(attribution(.init(pid: 400, path: terminal)) == .caller)
        // macOS names the process itself, and the app it's attributed to, as for the GitHub Copilot app's agents.
        #expect(attribution(.init(pid: pid, path: "/Applications/GitHub Copilot.app/Contents/MacOS/github")) == .caller)
    }

    @Test func startedAsAnAppOrDisclaimedHasItsOwn() {
        // LaunchServices (Finder, a login item, `open`), and a program that disclaimed it, look the same.
        #expect(attribution(.init(pid: pid, path: briefBar)) == .itself)
        // As do its own programs that didn't disclaim it, which don't run BriefBar, but would have its permissions.
        #expect(attribution(.init(pid: 600, path: briefBar)) == .itself)
    }

    @Test func notKnowingCountsAsItsOwn() {
        #expect(attribution(nil) == .itself)
        #expect(Attribution(pid: pid, executable: nil, responsible: .init(pid: pid, path: briefBar)) == .itself)
        // An older macOS that names only the process.
        #expect(attribution(.init(pid: pid, path: nil)) == .itself)
        #expect(attribution(.init(pid: 400, path: nil)) == .caller)
    }

    @Test func knowsItsExecutableByAnyPath() throws {
        try withTemporaryDirectory { directory in
            let executable = directory.appendingPathComponent("BriefBar")
            try Data().write(to: executable)
            let link = directory.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
            let attributed = Attribution(pid: pid, executable: executable.path, responsible: .init(pid: pid, path: link.path))
            #expect(attributed == .itself)
        }
    }

    @Test func takesOtherDataFromItsEnvironmentOnlyWithTheCallersPermissions() {
        let variables = ["BRIEFBAR_TEAMS_DB": "/tmp/db2/db", "BRIEFBAR_COPILOT_DIR": "/tmp/copilot"]
        #expect(Attribution.caller.environment(variables) == variables)
        #expect(Attribution.itself.environment(variables).isEmpty)
    }

    @Test func asksMacOSAboutThisProcess() throws {
        let responsible = try #require(Attribution.responsibleProcess(for: getpid()))
        #expect(responsible.pid > 0)
        #expect(Attribution.executablePath(of: getpid()) != nil)
    }

    /// Whoever starts BriefBar as an app chooses its environment, so the variables that point it at other data are
    /// read only through `Attribution.environment`. Any other read of the environment has to be one of these, each
    /// with its reason, or be added here with one.
    @Test func readsTheEnvironmentOnlyThroughAttribution() throws {
        let allowed: [String: String] = [
            "BriefBarCore/Attribution.swift": "where the variables are read",
            "BriefBarCore/LaunchEnvironment.swift": "puts back HOME, and drops what moves where macOS keeps your files, before anything reads them",
            "BriefBarCore/ProcessRunner.swift": "hands the environment to programs, which run with their own permissions",
            "AzureDevOpsCore/Auth.swift": "finds az (BRIEFBAR_AZ, SHELL, PATH), which runs with its own permissions",
            "TeamsUI/TeamsSource.swift": "BRIEFBAR_RENDER_SUMMARIES, for --render, which runs only with the caller's",
        ]
        // Resolved, as the enumerator's paths can be: a checkout under /tmp is under /private/tmp.
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources").standardizedFileURL.resolvingSymlinksInPath()
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var readers: Set<String> = []
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("processInfo.environment") || text.contains("getenv(") else { continue }
            let path = file.resolvingSymlinksInPath().pathComponents
            try #require(path.starts(with: sources.pathComponents), "\(file.path) isn't in \(sources.path)")
            readers.insert(path.dropFirst(sources.pathComponents.count).joined(separator: "/"))
        }
        #expect(!readers.isEmpty)
        #expect(readers.subtracting(allowed.keys).isEmpty, "Read these through Attribution.environment: \(readers.subtracting(allowed.keys).sorted())")
    }
}
