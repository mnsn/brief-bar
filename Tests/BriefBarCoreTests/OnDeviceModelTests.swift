import Foundation
import Testing

/// `SystemLanguageModel.default` is a new model each time it's read, and what SwiftUI keeps to follow each one's
/// availability stays: the Pull Requests page, which read it each time it updated, kept a little more each time. So only
/// `OnDeviceModel` reads it, once, and keeps the model.
struct OnDeviceModelTests {
    @Test(.onTestThreads) func readsTheSystemModelOnceAndKeepsIt() throws {
        #expect(try sourcesMatching(/SystemLanguageModel\.default/) == ["BriefBarUI/OnDeviceModel.swift"])
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/BriefBarUI/OnDeviceModel.swift")
        let code = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        #expect(code.filter { $0.contains("SystemLanguageModel.default") }.map { $0.trimmingCharacters(in: .whitespaces) }
            == ["private static let model = SystemLanguageModel.default"])
    }
}
