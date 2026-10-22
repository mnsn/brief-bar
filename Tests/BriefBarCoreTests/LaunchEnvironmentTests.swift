import Darwin
import Foundation
import Testing
@testable import BriefBarCore

/// Started with its own permissions, BriefBar puts back the variables that would move where macOS keeps and finds your
/// files, whatever whoever started it set.
@Suite struct LaunchEnvironmentTests {
    /// The temporary folder macOS gives Avery's account.
    private static let temporary = "/var/folders/xy/T/"

    @Test func putsBackYourHomeAndDropsWhatMovesYourFiles() {
        let chosen = [
            "HOME": "/tmp/elsewhere", "CFFIXED_USER_HOME": "/tmp/elsewhere", "SQLITE_TMPDIR": "/tmp/elsewhere",
            "TMPDIR": "/tmp/elsewhere", "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
        ]
        #expect(LaunchEnvironment.changes(chosen, home: "/Users/avery", temporaryFolder: Self.temporary) == [
            "HOME": .set("/Users/avery"), "TMPDIR": .set(Self.temporary), "CFFIXED_USER_HOME": .remove, "SQLITE_TMPDIR": .remove,
        ])
        // Without HOME and TMPDIR, too.
        #expect(LaunchEnvironment.changes([:], home: "/Users/avery", temporaryFolder: Self.temporary) == [
            "HOME": .set("/Users/avery"), "TMPDIR": .set(Self.temporary),
        ])
    }

    @Test func changesNothingAsMacOSStartsIt() {
        // As launchd gives an app its environment.
        let usual = ["HOME": "/Users/avery", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": Self.temporary, "USER": "avery"]
        #expect(LaunchEnvironment.changes(usual, home: "/Users/avery", temporaryFolder: Self.temporary).isEmpty)
    }

    /// SQLite falls back to `TMPDIR` when it can't write to the temporary folder macOS gives you, and a program running
    /// as you can make that folder unwritable: so `TMPDIR` is that folder, or, when macOS doesn't name one, none.
    @Test func putsBackTheTemporaryFolderMacOSGivesYou() {
        let chosen = ["HOME": "/Users/avery", "TMPDIR": "/tmp/elsewhere"]
        #expect(LaunchEnvironment.changes(chosen, home: "/Users/avery", temporaryFolder: Self.temporary) == [
            "TMPDIR": .set(Self.temporary),
        ])
        #expect(LaunchEnvironment.changes(chosen, home: "/Users/avery", temporaryFolder: nil) == ["TMPDIR": .remove])
        #expect(LaunchEnvironment.changes(["HOME": "/Users/avery"], home: "/Users/avery", temporaryFolder: nil).isEmpty)
    }

    /// The temporary folder macOS gives this account: Foundation's, whatever `TMPDIR` says, and yours.
    @Test func asksMacOSForYourTemporaryFolder() throws {
        let folder = try #require(LaunchEnvironment.temporaryFolder())
        #expect(URL(fileURLWithPath: folder).standardizedFileURL.path == URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path)
        var info = stat()
        #expect(stat(folder, &info) == 0)
        #expect(info.st_uid == getuid())
    }

    /// The per-user temporary and cache folders follow `DIRHELPER_USER_DIR_SUFFIX`, and SQLite has variables of its own,
    /// none of which BriefBar uses.
    @Test func dropsWhatMovesTheTemporaryFoldersAndSQLitesVariables() {
        let chosen = [
            "HOME": "/Users/avery", "DIRHELPER_USER_DIR_SUFFIX": "elsewhere", "SQLITE_SQLLOG_DIR": "/tmp/elsewhere",
            "SQLITE_AUTO_TRACE": "1", "TMPDIR": Self.temporary, "BRIEFBAR_TEAMS_DB": "/tmp/demo/db2/db",
        ]
        #expect(LaunchEnvironment.changes(chosen, home: "/Users/avery", temporaryFolder: Self.temporary) == [
            "DIRHELPER_USER_DIR_SUFFIX": .remove, "SQLITE_SQLLOG_DIR": .remove, "SQLITE_AUTO_TRACE": .remove,
        ])
    }

    /// Only with its own permissions: run from a shell, with that app's, BriefBar keeps the environment it was given.
    @Test func changesTheEnvironmentOnlyWithItsOwnPermissions() {
        let chosen = [
            "HOME": "/tmp/elsewhere", "CFFIXED_USER_HOME": "/tmp/elsewhere", "SQLITE_TMPDIR": "/tmp/elsewhere",
            "TMPDIR": "/tmp/elsewhere",
        ]
        #expect(LaunchEnvironment.changes(chosen, home: "/Users/avery", temporaryFolder: Self.temporary, attribution: .itself) == [
            "HOME": .set("/Users/avery"), "TMPDIR": .set(Self.temporary), "CFFIXED_USER_HOME": .remove, "SQLITE_TMPDIR": .remove,
        ])
        #expect(LaunchEnvironment.changes(chosen, home: "/Users/avery", temporaryFolder: Self.temporary, attribution: .caller).isEmpty)
    }

    /// The home folder the user database names, which no variable moves.
    @Test func findsYourHomeInTheUserDatabase() throws {
        let home = UserHome.url.path
        #expect(home != "/var/empty")
        #expect(home == NSHomeDirectoryForUser(NSUserName()))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: home, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    /// What BriefBar reads and writes in your home folder, it finds in `UserHome`: FileManager's home folder and its
    /// search paths follow `CFFIXED_USER_HOME`, and `~` in a path follows it too.
    @Test func findsYourFilesOnlyInTheUserDatabasesHomeFolder() throws {
        let homeFolder = /homeDirectoryForCurrentUser|NSHomeDirectory\(|userDomainMask|"~\//
        // The check itself: each of these would be caught.
        for sample in [
            "FileManager.default.homeDirectoryForCurrentUser", "NSHomeDirectory()", ".urls(for: .cachesDirectory, in: .userDomainMask)",
            #"NSString(string: "~/.local/bin/az").expandingTildeInPath"#,
        ] {
            #expect(sample.contains(homeFolder), "\(sample)")
        }
        let found = try sourcesMatching(homeFolder)
        #expect(found.isEmpty, "Use UserHome.url in: \(found.sorted())")
    }
}
