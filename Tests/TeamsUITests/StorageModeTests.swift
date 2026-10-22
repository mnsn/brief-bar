import Foundation
import NotificationCenterDB
import TeamsCore
import Testing
@testable import TeamsUI

/// Any program can run BriefBar's binary, and the keychain gives that binary the key to the unread chats the app
/// saved, without asking. So the command line and `--render` never use it: they show only what whoever runs
/// them can read.
@Suite struct StorageModeTests {
    private let now = Date(timeIntervalSince1970: 1_792_317_600)

    @Test func theInstalledAppsCommandLineNeverGetsTheKeychainKey() throws {
        try withTemporaryDirectory { directory in
            let app = StorageMode.current(paths: systemPaths(in: directory), isBundled: true)
            #expect(app.keyStore is KeychainKeyStore)
            #expect(app.writes)

            let commandLine = app.readOnly
            #expect(commandLine.keyStore == nil)
            #expect(!commandLine.writes)
        }
    }

    @Test func theCommandLineLeavesOutTheChatsTheAppSaved() throws {
        try withTemporaryDirectory { directory in
            let paths = systemPaths(in: directory)
            // The app's storage, with its key in memory instead of the keychain.
            let app = StorageMode(paths: paths, keyStore: MemoryKeyStore(), writes: true)
            try UnreadCache(url: paths.unreadFile, keyStore: try #require(app.keyStore)).save([savedChat()], at: now)
            #expect(app.loadState(settings: TrackerSettings(), now: now).0.count(.chats) == 1)

            // Notification Center no longer has the chat (there's no database here), so only the app shows it.
            let (state, snapshot) = app.readOnly.loadState(settings: TrackerSettings(), now: now)
            #expect(snapshot.access == .missing)
            #expect(state.count(.chats) == 0)
            #expect(FileManager.default.fileExists(atPath: paths.unreadFile.path))
        }
    }

    @Test func anotherDatabaseKeepsItsKeyFile() throws {
        try withTemporaryDirectory { directory in
            // Such as the demo data that BRIEFBAR_TEAMS_DB names: nothing private, with its key in a file.
            let paths = NotificationPaths(database: directory.appendingPathComponent("db2/db"),
                                          stateDirectory: directory.appendingPathComponent("state", isDirectory: true))
            let storage = StorageMode.current(paths: paths, isBundled: true)
            try UnreadCache(url: paths.unreadFile, keyStore: try #require(storage.keyStore)).save([savedChat()], at: now)

            let commandLine = storage.readOnly
            #expect(commandLine.keyStore is FileKeyStore)
            #expect(!commandLine.writes)
            #expect(commandLine.loadState(settings: TrackerSettings(), now: now).0.count(.chats) == 1)
        }
    }

    /// Stands in for Notification Center's own database, in a temporary folder.
    private func systemPaths(in directory: URL) -> NotificationPaths {
        NotificationPaths(database: directory.appendingPathComponent("db2/db"),
                          stateDirectory: directory.appendingPathComponent("state", isDirectory: true),
                          isSystemDatabase: true)
    }

    /// A made-up unread 1:1 chat, from ten minutes ago.
    private func savedChat() -> CachedConversation {
        let conversation = "19:11111111-aaaa-4aaa-8aaa-111111111111_99999999-ffff-4fff-8fff-999999999999@unq.gbl.spaces"
        let message = ChatMessage(conversationID: conversation, kind: .oneOnOne, messageID: "1792317000000",
                                  notificationKey: "n1", deliveredAt: now.addingTimeInterval(-600),
                                  chatName: "Avery Quinn", sender: "Avery Quinn", text: "Lunch at noon?")
        return CachedConversation(id: conversation, kind: .oneOnOne, name: "Avery Quinn", messages: [message])
    }
}

private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("BriefBarTeamsUITests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}
