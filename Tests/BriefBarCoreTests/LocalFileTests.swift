import BriefBarCore
import Foundation
import Testing

@Suite struct LocalFileTests {
    /// The start of a file below a folder, and when it last changed: a regular file's only, reached without a link.
    @Test func readsTheStartOfAFileBelowAFolderWithoutFollowingALink() throws {
        try withTemporaryDirectory { root in
            let folder = root.appendingPathComponent("session-state/s1/checkpoints", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("001-first.md")
            try "<overview>\nThe first\n</overview>\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: t(100)], ofItemAtPath: file.path)

            let path = ["session-state", "s1", "checkpoints", "001-first.md"]
            let start = try #require(LocalFile.head(below: root, path, maxBytes: 10))
            #expect(String(decoding: start.data, as: UTF8.self) == "<overview>")
            #expect(start.modified == t(100))
            #expect(LocalFile.head(below: root, path, maxBytes: 1_024)?.data.count == 33)
            #expect(LocalFile.head(below: root, path, maxBytes: 0)?.data.isEmpty == true)

            #expect(LocalFile.head(below: root, ["session-state", "s1", "checkpoints"], maxBytes: 1_024) == nil)
            #expect(LocalFile.head(below: root, ["session-state", "s1", "missing.md"], maxBytes: 1_024) == nil)
            #expect(LocalFile.head(below: root, ["session-state", "s1", "..", "s1", "checkpoints", "001-first.md"], maxBytes: 1_024) == nil)

            // A link as the file, or as a folder on the way to it.
            try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("002-link.md"), withDestinationURL: file)
            #expect(LocalFile.head(below: root, ["session-state", "s1", "checkpoints", "002-link.md"], maxBytes: 1_024) == nil)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("session-state/s2"), withDestinationURL: folder.deletingLastPathComponent())
            #expect(LocalFile.head(below: root, ["session-state", "s2", "checkpoints", "001-first.md"], maxBytes: 1_024) == nil)
        }
    }
}
