import Darwin
import Foundation
import Testing
@testable import AzureDevOpsCore
@testable import BriefBarCore

/// The built `BriefBar`, started as LaunchServices starts an app, responsible for itself, has its own Full Disk Access:
/// then whoever started it chose its environment and reads its output, so it refuses `--chats`, and reads neither
/// Notification Center nor the copy the environment names, and `--render` draws nothing. The control: started plainly,
/// as from a shell, it has the permissions of what started it, and lists that copy's made-up link.
@Suite(.serialized) struct BuiltAppTests {
    /// The `BriefBar` built with these tests, beside their bundle.
    static func builtApp() throws -> URL {
        let binary = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("BriefBar")
        try #require(FileManager.default.isExecutableFile(atPath: binary.path), "Build BriefBar first (swift build): \(binary.path)")
        return binary
    }

    /// A folder for its home, and a copy of Notification Center's database in it with one made-up notification: Dana
    /// sends a link in Slack.
    private static func withMadeUpNotifications(_ body: (_ home: URL, _ environment: [String: String]) async throws -> Void) async throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let database = home.appendingPathComponent("db2/db")
        let notifications = try TestNotificationDatabase(at: database)
        try notifications.add(
            NotificationRecord.data(app: Chats.slack, title: "Dana Whitfield", body: "Could you look at \(Chats.link) today?",
                                    date: Date().addingTimeInterval(-600)),
            app: Chats.slack, delivered: Date().addingTimeInterval(-600)
        )
        notifications.close()
        try await body(home, [
            "PATH": "/usr/bin:/bin", "HOME": home.path, "CFFIXED_USER_HOME": home.path,
            ChatLinkDatabase.overrideVariable: database.path,
        ])
    }

    @Test(.timeLimit(.minutes(2)))
    func refusesWhenItsResponsibleForItself() async throws {
        let binary = try Self.builtApp()
        try await Self.withMadeUpNotifications { home, environment in
            let refused = try await ProcessRunner().run(binary, arguments: ["--chats"], environment: environment, timeout: 60)
            #expect(refused.status == 1)
            #expect(refused.stdout.isEmpty)
            #expect(String(decoding: refused.stderr, as: UTF8.self).contains("Started as an app"))

            let pictures = home.appendingPathComponent("pictures")
            let drawn = try await ProcessRunner().run(
                binary, arguments: ["--render", pictures.path, "--demo"], environment: environment, timeout: 60
            )
            #expect(drawn.status == 1)
            #expect(!FileManager.default.fileExists(atPath: pictures.path))
        }
    }

    /// Whether macOS says enough here to tell a program started plainly from one responsible for itself.
    static var canTellProgramsApart: Bool {
        guard let responsible = Responsibility.responsible(for: getpid()) else { return false }
        return responsible.path != nil || responsible.pid != getpid()
    }

    /// The control for the test above, so that it could fail.
    @Test(.timeLimit(.minutes(2)), .enabled(if: canTellProgramsApart, "macOS doesn't say enough here to tell"))
    func listsTheCopyStartedPlainly() async throws {
        let binary = try Self.builtApp()
        try await Self.withMadeUpNotifications { _, environment in
            let listed = try Self.runPlainly(binary, ["--chats"], environment: environment)
            #expect(listed.status == 0, "\(listed.stderr)")
            #expect(listed.stdout.contains("Dana Whitfield"))
            #expect(listed.stdout.contains("contoso/7"))

            // And Azure DevOps' made-up pull requests, which need no files.
            let demo = try Self.runPlainly(binary, ["--source", "ado", "--json", "--demo"], environment: environment)
            #expect(demo.status == 0, "\(demo.stderr)")
            #expect(demo.stdout.contains("\"needsYou\""))
        }
    }

    /// Started the usual way, attributed to what this process is attributed to.
    private static func runPlainly(
        _ binary: URL, _ arguments: [String], environment: [String: String]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self))
    }
}

private final class Marker {}
