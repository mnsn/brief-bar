import BriefBarCore
import Foundation
import Synchronization
@testable import CopilotTasks

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("BriefBarTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    // The canonical path, /private/var/…, as git reports it: resolvingSymlinksInPath() would leave out /private.
    guard let real = realpath(url.path, nil) else { return url }
    defer { free(real) }
    return URL(fileURLWithPath: String(cString: real), isDirectory: true)
}

struct TestError: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}

/// A work item made up for tests.
let sampleItem = TaskWorkItem(
    organization: "contoso", project: "Storefront", id: 4217, type: "Task", title: "Show the order total in the cart",
    url: URL(string: "https://dev.azure.com/contoso/Storefront/_workitems/edit/4217")!
)

/// Answers each run from a script, by its arguments, and records them.
final class FakeRunner: ProcessRunning, @unchecked Sendable {
    private let calls = Mutex<[[String]]>([])
    private let answer: @Sendable ([String]) -> ProcessResult

    init(_ answer: @escaping @Sendable ([String]) -> ProcessResult) {
        self.answer = answer
    }

    var arguments: [[String]] { calls.withLock { $0 } }

    func run(_ executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval) async throws -> ProcessResult {
        calls.withLock { $0.append(arguments) }
        return answer(arguments)
    }
}

extension ProcessResult {
    static func ok(_ stdout: String = "") -> ProcessResult { ProcessResult(status: 0, stdout: Data(stdout.utf8)) }
    static func failure(_ stderr: String, status: Int32 = 128) -> ProcessResult {
        ProcessResult(status: status, stderr: Data(stderr.utf8))
    }
}

/// Lines of a session log, shaped like the Copilot CLI's: top-level keys in its order (`type, data, [agentId], id,
/// timestamp, parentId`).
enum Line {
    static func event(_ type: String, data: [String: Any] = [:], at seconds: Int = 0) -> String {
        let timestamp = Date(timeIntervalSince1970: 1_792_000_000 + TimeInterval(seconds))
            .formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: data, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        return #"{"type":"\#(type)","data":\#(json),"id":"\#(UUID().uuidString.lowercased())","timestamp":"\#(timestamp)","parentId":null}"#
    }

    static func userMessage(_ content: String = "Fix the task", at seconds: Int = 0) -> String {
        event("user.message", data: ["content": content], at: seconds)
    }

    static func toolStart(_ name: String, id: String, description: String? = nil, at seconds: Int) -> String {
        var arguments: [String: Any] = [:]
        if let description { arguments["description"] = description }
        return event("tool.execution_start", data: ["toolCallId": id, "toolName": name, "arguments": arguments], at: seconds)
    }

    static func message(_ content: String, subagent: Bool = false, at seconds: Int) -> String {
        var data: [String: Any] = ["content": content, "toolRequests": []]
        if subagent { data["parentToolCallId"] = "call-9" }
        return event("assistant.message", data: data, at: seconds)
    }

    static func taskComplete(_ summary: String, at seconds: Int) -> String {
        event("session.task_complete", data: ["summary": summary, "success": true], at: seconds)
    }
}

/// A repository with an origin, both in a temporary folder: `origin.git`, and `checkout`, cloned from it, whose origin's
/// default branch is `main`.
struct RepositoryFixture {
    let folder: URL
    var origin: URL { folder.appendingPathComponent("origin.git") }
    var checkout: URL { folder.appendingPathComponent("checkout") }
    let environment: [String: String]

    init() async throws {
        folder = try makeTemporaryDirectory()
        // A home of its own, so no global git settings apply.
        environment = ["PATH": "/usr/bin:/bin", "HOME": folder.path, "GIT_CONFIG_NOSYSTEM": "1"]
        let seed = folder.appendingPathComponent("seed")
        try await git(["init", "--quiet", "--initial-branch=main", seed.path])
        try "Storefront\n".write(to: seed.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await git(["-C", seed.path, "add", "README.md"])
        try await git(["-C", seed.path, "-c", "user.name=Robin Diaz", "-c", "user.email=robin@example.com", "commit", "--quiet", "-m", "First"])
        try await git(["clone", "--quiet", "--bare", seed.path, origin.path])
        try await git(["clone", "--quiet", origin.path, checkout.path])
    }

    func git(_ arguments: [String]) async throws {
        let result = try await ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments, environment: environment, timeout: 60)
        guard result.status == 0 else { throw TestError("git \(arguments.joined(separator: " ")): \(String(decoding: result.stderr, as: UTF8.self))") }
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }
}
