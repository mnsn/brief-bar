import Foundation
import Testing
@testable import BriefBarCore

/// The apps a folder opens in, such as a pull request's Copilot session's worktree: those on this Mac, editors first, and
/// the one you opened a folder in last.
@Suite struct FolderAppsTests {
    private static func installed(_ ids: Set<String>) -> [FolderApp] {
        FolderApps.installed { ids.contains($0) }
    }

    @Test func offersTheKnownAppsOnThisMacEditorsFirst() {
        let apps = Self.installed(["com.apple.Terminal", "com.jetbrains.rider", "com.microsoft.VSCode", "org.example.Unknown"])
        #expect(apps.map(\.name) == ["VS Code", "Rider", "Terminal"])
        #expect(apps.map(\.kind) == [.editor, .editor, .terminal])
        #expect(Self.installed([]).isEmpty)
        // Each once, editors before terminals, as their buttons and menus say them.
        #expect(Set(FolderApps.known.map(\.id)).count == FolderApps.known.count)
        #expect(Set(FolderApps.known.map(\.name)).count == FolderApps.known.count)
        let firstTerminal = FolderApps.known.firstIndex { $0.kind == .terminal } ?? FolderApps.known.endIndex
        #expect(FolderApps.known[firstTerminal...].allSatisfy { $0.kind == .terminal })
    }

    @Test func opensInTheAppYouOpenedOneInLastWhileItsHere() {
        let apps = Self.installed(["com.microsoft.VSCode", "com.jetbrains.WebStorm", "com.apple.Terminal"])
        #expect(FolderApps.preferred(chosen: nil, among: apps)?.name == "VS Code")
        #expect(FolderApps.preferred(chosen: "com.jetbrains.WebStorm", among: apps)?.name == "WebStorm")
        #expect(FolderApps.preferred(chosen: "com.apple.Terminal", among: apps)?.name == "Terminal")
        // One that's gone, or that BriefBar doesn't know, as another program may write in the preferences: the first editor.
        #expect(FolderApps.preferred(chosen: "com.jetbrains.rider", among: apps)?.name == "VS Code")
        #expect(FolderApps.preferred(chosen: "/Applications/Calculator.app", among: apps)?.name == "VS Code")
        // Without an editor, a terminal; without either, none.
        let terminals = Self.installed(["com.googlecode.iterm2", "com.apple.Terminal"])
        #expect(FolderApps.preferred(chosen: nil, among: terminals)?.name == "Terminal")
        #expect(FolderApps.preferred(chosen: "com.googlecode.iterm2", among: terminals)?.name == "iTerm")
        #expect(FolderApps.preferred(chosen: nil, among: []) == nil)
    }

    @Test func knowsOnlyItsOwnApps() {
        #expect(FolderApps.app(withID: "com.jetbrains.rider")?.name == "Rider")
        #expect(FolderApps.app(withID: "com.apple.Calculator") == nil)
        #expect(FolderApps.app(withID: nil) == nil)
        #expect(FolderApps.app(withID: "com.apple.Terminal")?.symbol == "terminal")
        #expect(FolderApps.app(withID: "com.microsoft.VSCode")?.symbol == "chevron.left.forwardslash.chevron.right")
    }
}
