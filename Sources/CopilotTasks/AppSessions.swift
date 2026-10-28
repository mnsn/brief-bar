import BriefBarCore
import CopilotCore
import Foundation

/// One of the GitHub Copilot app's sessions, as its database lists it, that a task can go to instead of a new session:
/// one that opened a pull request, say, and knows its code.
public struct AppSession: Sendable, Equatable, Identifiable {
    /// Its ID, a lowercase UUID, which names its folder in `session-state`.
    public var id: String
    /// Its name, as the app's sidebar shows it.
    public var name: String
    public var projectName: String?
    public var branch: String?
    /// Its project's folder's name, and its GitHub repository, `owner/name`: what its branch is in.
    public var folder: String?
    public var gitHubRepository: String?
    /// The pull requests the app records it started from or opened.
    public var pullRequests: [ItemRef]
    public var isChat: Bool
    /// The app says a turn is in progress, or that it waits on you.
    public var isRunning: Bool
    public var createdAt: Date?
    /// When it last changed, or the app last said what it did.
    public var lastActive: Date?

    public init(
        id: String, name: String, projectName: String? = nil, branch: String? = nil, folder: String? = nil,
        gitHubRepository: String? = nil, pullRequests: [ItemRef] = [], isChat: Bool = false, isRunning: Bool = false,
        createdAt: Date? = nil, lastActive: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.projectName = projectName
        self.branch = branch
        self.folder = folder
        self.gitHubRepository = gitHubRepository
        self.pullRequests = pullRequests
        self.isChat = isChat
        self.isRunning = isRunning
        self.createdAt = createdAt
        self.lastActive = lastActive
    }

    init(_ meta: SessionMeta) {
        let activity = [meta.updatedAt, meta.lastActivity?.at].compactMap { $0 }.max()
        self.init(
            id: meta.id, name: meta.name.isEmpty ? "Untitled session" : PlainText.singleLine(meta.name), projectName: meta.projectName,
            branch: meta.branch.flatMap { $0.isEmpty ? nil : $0 }, folder: meta.links?.folder,
            gitHubRepository: meta.links?.gitHubRepository, pullRequests: meta.links?.pullRequests.compactMap(\.ref) ?? [],
            isChat: meta.isChat, isRunning: meta.isRunning == true, createdAt: meta.createdAt, lastActive: activity
        )
    }

    /// What links it to a pull request by branch: its branch, in its project's repository.
    public var branchHint: BranchHint? {
        guard !isChat, let branch else { return nil }
        return BranchHint(branch: branch, repositories: BranchHint.repositories([projectName, folder], gitHub: gitHubRepository))
    }
}

/// The Copilot app's sessions, read-only: which there are, which one the app has open, and where each works.
public enum AppSessions {
    /// Where the Copilot app keeps its files: `~/.copilot`, or the folder `BRIEFBAR_COPILOT_DIR` names, from the command
    /// line (`CopilotPaths.default()`).
    public static func home() -> URL {
        CopilotPaths.default().root
    }

    /// The sessions the app lists, the most recently active first: its chats, and its projects' sessions with a
    /// workspace, neither archived. Throws when its database can't be read.
    public static func load(home: URL) throws -> [AppSession] {
        let snapshot = try AppDatabase.load(at: CopilotPaths(root: home).database, links: true)
        return snapshot.sessions.filter { isSessionID($0.id) }.map(AppSession.init)
            .sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
    }

    /// The sessions that run a turn now, by the app's own flag, as its database says now: their IDs. Throws when it can't
    /// be read.
    public static func running(home: URL) throws -> [String] {
        try AppDatabase.load(at: CopilotPaths(root: home).database).sessions
            .filter { $0.isRunning == true && isSessionID($0.id) }.map(\.id)
    }

    /// Whether the Copilot app, or another program, has the session open now (`SessionLock`): a turn the CLI runs in it
    /// then is one the app never sees.
    public static func isOpen(_ id: String, home: URL) -> Bool {
        guard let folder = sessionFolder(id, home: home) else { return false }
        return SessionLock.isHeld(sessionFolder: folder)
    }

    /// The folder a session works in, as its `workspace.yaml` says, read without following a symbolic link below the app's
    /// folder (`LocalFile.openFile(below:_:)`); nil when it doesn't say, or that folder isn't there.
    public static func folder(of id: String, home: URL) -> URL? {
        guard isSessionID(id),
              let data = LocalFile.tail(below: home, stateFile(id, "workspace.yaml", home: home), maxBytes: 64 << 10),
              let path = SessionStateScanner.value("cwd", inWorkspace: String(decoding: data, as: UTF8.self)),
              path.hasPrefix("/")
        else { return nil }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// A session's log, `session-state/<id>/events.jsonl`.
    public static func events(of id: String, home: URL) -> URL? {
        sessionFolder(id, home: home)?.appendingPathComponent("events.jsonl")
    }

    /// `session-state/<id>/<name>`, by its components below the app's folder, to open it without following a link.
    static func stateFile(_ id: String, _ name: String, home: URL) -> [String] {
        [CopilotPaths(root: home).sessionState.lastPathComponent, id, name]
    }

    /// A folder's path, to compare it with another's however each is written.
    public static func folderKey(_ folder: URL) -> String {
        folder.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The checkout a folder is in, by its `folderKey`, to tell whether two sessions' work would mix: the nearest folder,
    /// itself or one it's within, with a `.git` of its own, as a repository's checkout, one of its worktrees and a submodule
    /// have; else the folder itself, as for one that holds checkouts, whose sessions mostly work elsewhere. Read from the
    /// disk, without running git.
    public static func checkoutKey(_ folder: URL) -> String {
        let key = folderKey(folder)
        var path = key
        while !FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) {
            let parent = (path as NSString).deletingLastPathComponent
            guard parent != path, !parent.isEmpty else { return key }
            path = parent
        }
        return path
    }

    /// Whether another of the app's sessions runs a turn now, by its own flag, in the same checkout as the folder
    /// (`checkoutKey`), as the app's database and the sessions' state say now. Not `id`, when given: the session Copilot
    /// would go on with, which the app runs a turn in only while it has it open (`isOpen`). None when the database can't
    /// be read.
    public static func anotherRunsATurn(inCheckoutOf folder: URL, besides id: String?, home: URL) -> Bool {
        let others = ((try? running(home: home)) ?? []).filter { $0 != id }
        guard !others.isEmpty else { return false }
        let checkout = checkoutKey(folder)
        return others.contains { self.folder(of: $0, home: home).map(checkoutKey) == checkout }
    }

    /// `session-state/<id>`, for an ID that's a session's: a lowercase UUID, which can't step out of the folder.
    static func sessionFolder(_ id: String, home: URL) -> URL? {
        guard isSessionID(id) else { return nil }
        return CopilotPaths(root: home).sessionDirectory(id)
    }

    static func isSessionID(_ id: String) -> Bool {
        UUID(uuidString: id)?.uuidString.lowercased() == id
    }
}
