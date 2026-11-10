import AppKit
import BriefBarCore
import BriefBarUI
import Foundation
import Testing

/// Opening a folder, such as a pull request's Copilot session's worktree, in an editor or a terminal on this Mac, or the
/// Finder: only when you click, in the app you opened one in last, and never in the demo.
@MainActor
@Suite struct FolderOpenerTests {
    private static let apps: [String: URL] = [
        "com.microsoft.VSCode": URL(fileURLWithPath: "/Applications/Visual Studio Code.app", isDirectory: true),
        "com.jetbrains.rider": URL(fileURLWithPath: "/Applications/Rider.app", isDirectory: true),
        "com.apple.Terminal": URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app", isDirectory: true),
    ]

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BriefBarFolderOpener-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func looksForTheAppsOnlyOnceTheyreWanted() {
        var asked: [String] = []
        let opener = FolderOpener(defaults: MemoryDefaults(), isDemo: false) { id in
            asked.append(id)
            return Self.apps[id]
        }
        #expect(asked.isEmpty && opener.installed.isEmpty && opener.preferred == nil)
        opener.lookForApps()
        #expect(asked.count == FolderApps.known.count)
        #expect(opener.installed.map(\.name) == ["VS Code", "Rider", "Terminal"])
        #expect(opener.preferred?.name == "VS Code")
        // Wanted again, they're as found: BriefBar coming to the front looks again.
        opener.lookForApps()
        #expect(asked.count == FolderApps.known.count)
    }

    @Test func opensTheFolderInTheAppYouChoseWhichItOpensInFromThenOn() throws {
        let defaults = MemoryDefaults()
        let opener = FolderOpener(defaults: defaults, isDemo: false) { Self.apps[$0] }
        opener.lookForApps()
        let worktree = try folder()
        defer { try? FileManager.default.removeItem(at: worktree) }
        let rider = try #require(opener.installed.first { $0.name == "Rider" })
        let notes = ThisMac.Notes()
        ThisMac.$noting.withValue(notes) {
            opener.open(worktree, in: rider)
            opener.openInFinder(worktree)
            opener.copyPath(worktree)
        }
        #expect(notes.refused == [
            "open \(worktree.absoluteString) with Rider.app", "open \(worktree.path) in the Finder", "copy \(worktree.path)",
        ])
        #expect(opener.preferred?.name == "Rider")
        #expect(defaults.string(forKey: FolderOpener.chosenKey) == "com.jetbrains.rider")
        // Kept: the next time BriefBar opens, folders open there too.
        let again = FolderOpener(defaults: defaults, isDemo: false) { Self.apps[$0] }
        again.lookForApps()
        #expect(again.preferred?.name == "Rider")
    }

    @Test func opensNothingOnceTheFolderOrTheAppIsGone() throws {
        var installed = Self.apps
        let opener = FolderOpener(defaults: MemoryDefaults(), isDemo: false) { installed[$0] }
        opener.lookForApps()
        let worktree = try folder()
        try FileManager.default.removeItem(at: worktree)
        let code = try #require(opener.preferred)
        let notes = ThisMac.Notes()
        ThisMac.$noting.withValue(notes) {
            opener.open(worktree, in: code)
            opener.openInFinder(worktree)
        }
        #expect(notes.refused == ["beep", "beep"])
        // Rider's gone since it was looked for: it beeps, and isn't offered anymore.
        let kept = try folder()
        defer { try? FileManager.default.removeItem(at: kept) }
        let rider = try #require(opener.installed.first { $0.name == "Rider" })
        installed["com.jetbrains.rider"] = nil
        let later = ThisMac.Notes()
        ThisMac.$noting.withValue(later) { opener.open(kept, in: rider) }
        #expect(later.refused == ["beep"])
        #expect(opener.installed.map(\.name) == ["VS Code", "Terminal"])
    }

    @Test func keepsOnlyAnAppItKnows() {
        let defaults = MemoryDefaults()
        // Any program running as you can write the preferences.
        defaults.set("/Applications/Calculator.app", forKey: FolderOpener.chosenKey)
        let opener = FolderOpener(defaults: defaults, isDemo: false) { Self.apps[$0] }
        opener.lookForApps()
        #expect(opener.chosen == nil && opener.preferred?.name == "VS Code")
    }

    @Test func theDemoMakesUpItsAppsAndOpensNothing() throws {
        var asked = 0
        let opener = FolderOpener(defaults: MemoryDefaults(), isDemo: true) { _ in
            asked += 1
            return nil
        }
        opener.lookForApps()
        #expect(asked == 0)
        #expect(opener.installed.map(\.name) == ["VS Code", "Terminal"])
        let worktree = try folder()
        defer { try? FileManager.default.removeItem(at: worktree) }
        let notes = ThisMac.Notes()
        try ThisMac.$noting.withValue(notes) {
            opener.open(worktree, in: try #require(opener.installed.last))
            opener.openInFinder(worktree)
        }
        #expect(notes.refused.isEmpty)
        #expect(opener.preferred?.name == "Terminal")
    }
}
