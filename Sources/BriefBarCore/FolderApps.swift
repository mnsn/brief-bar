import Foundation

/// An app that opens a folder you give it, such as the worktree a pull request's Copilot session works in: a code editor,
/// which opens it as a project, or a terminal, which opens a shell there. BriefBar knows it by its bundle identifier, and
/// offers it only while it's on this Mac (`FolderApps`).
public struct FolderApp: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable {
        case editor
        case terminal
    }

    /// Its bundle identifier.
    public let id: String
    /// What its button calls it: "Open in VS Code".
    public let name: String
    public let kind: Kind

    public init(id: String, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    /// Its symbol, on its button: never the app's own icon, so that pictures look the same on every Mac.
    public var symbol: String {
        switch kind {
        case .editor: return "chevron.left.forwardslash.chevron.right"
        case .terminal: return "terminal"
        }
    }
}

/// The apps BriefBar opens a folder in, in the order it offers them: the editors, then the terminals. Of those on this
/// Mac, a folder opens in the one you opened one in last, or else in the first editor, or else in the first terminal
/// (`preferred`).
public enum FolderApps {
    public static let known: [FolderApp] = [
        FolderApp(id: "com.microsoft.VSCode", name: "VS Code", kind: .editor),
        FolderApp(id: "com.microsoft.VSCodeInsiders", name: "VS Code Insiders", kind: .editor),
        FolderApp(id: "com.todesktop.230313mzl4w4u92", name: "Cursor", kind: .editor),
        FolderApp(id: "com.exafunction.windsurf", name: "Windsurf", kind: .editor),
        FolderApp(id: "dev.zed.Zed", name: "Zed", kind: .editor),
        FolderApp(id: "com.jetbrains.rider", name: "Rider", kind: .editor),
        FolderApp(id: "com.jetbrains.WebStorm", name: "WebStorm", kind: .editor),
        FolderApp(id: "com.jetbrains.intellij", name: "IntelliJ IDEA", kind: .editor),
        FolderApp(id: "com.jetbrains.intellij.ce", name: "IntelliJ IDEA CE", kind: .editor),
        FolderApp(id: "com.jetbrains.pycharm", name: "PyCharm", kind: .editor),
        FolderApp(id: "com.jetbrains.pycharm.ce", name: "PyCharm CE", kind: .editor),
        FolderApp(id: "com.jetbrains.goland", name: "GoLand", kind: .editor),
        FolderApp(id: "com.jetbrains.CLion", name: "CLion", kind: .editor),
        FolderApp(id: "com.jetbrains.rustrover", name: "RustRover", kind: .editor),
        FolderApp(id: "com.jetbrains.PhpStorm", name: "PhpStorm", kind: .editor),
        FolderApp(id: "com.jetbrains.rubymine", name: "RubyMine", kind: .editor),
        FolderApp(id: "com.google.android.studio", name: "Android Studio", kind: .editor),
        FolderApp(id: "com.apple.dt.Xcode", name: "Xcode", kind: .editor),
        FolderApp(id: "com.sublimetext.4", name: "Sublime Text", kind: .editor),
        FolderApp(id: "com.panic.Nova", name: "Nova", kind: .editor),
        FolderApp(id: "com.barebones.bbedit", name: "BBEdit", kind: .editor),
        FolderApp(id: "com.apple.Terminal", name: "Terminal", kind: .terminal),
        FolderApp(id: "com.googlecode.iterm2", name: "iTerm", kind: .terminal),
        FolderApp(id: "com.mitchellh.ghostty", name: "Ghostty", kind: .terminal),
        FolderApp(id: "dev.warp.Warp-Stable", name: "Warp", kind: .terminal),
    ]

    /// The known app with this bundle identifier; nil for any other, such as one another program wrote in the preferences,
    /// which any program running as you can write.
    public static func app(withID id: String?) -> FolderApp? {
        guard let id else { return nil }
        return known.first { $0.id == id }
    }

    /// The known apps that are on this Mac, as `isInstalled` says of each bundle identifier, in the order they're offered.
    public static func installed(where isInstalled: (String) -> Bool) -> [FolderApp] {
        known.filter { isInstalled($0.id) }
    }

    /// The app a folder opens in, of those on this Mac: the one you opened one in last (`chosen`), while it's there; else
    /// the first editor; else the first terminal. Nil when none is there.
    public static func preferred(chosen: String?, among installed: [FolderApp]) -> FolderApp? {
        if let chosen, let app = installed.first(where: { $0.id == chosen }) { return app }
        return installed.first { $0.kind == .editor } ?? installed.first
    }
}
