import Darwin
import Foundation
import Testing
@testable import BriefBarCore

/// Started with its own permissions, BriefBar puts back the variables that would move where macOS keeps and finds your
/// files, whatever whoever started it set.
@Suite struct LaunchEnvironmentTests {
    @Test func putsBackYourHomeAndDropsWhatMovesYourFiles() {
        let chosen = [
            "HOME": "/tmp/elsewhere", "CFFIXED_USER_HOME": "/tmp/elsewhere", "SQLITE_TMPDIR": "/tmp/elsewhere",
            "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
        ]
        #expect(LaunchEnvironment.changes(chosen, home: "/Users/avery") == [
            "HOME": .set("/Users/avery"), "CFFIXED_USER_HOME": .remove, "SQLITE_TMPDIR": .remove,
        ])
        // Without HOME, too.
        #expect(LaunchEnvironment.changes([:], home: "/Users/avery") == ["HOME": .set("/Users/avery")])
    }

    @Test func changesNothingAsMacOSStartsIt() {
        // As launchd gives an app its environment.
        let usual = ["HOME": "/Users/avery", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": "/var/folders/xy/T/", "USER": "avery"]
        #expect(LaunchEnvironment.changes(usual, home: "/Users/avery").isEmpty)
    }

    /// The per-user temporary and cache folders follow `DIRHELPER_USER_DIR_SUFFIX`, and SQLite has variables of its own,
    /// none of which BriefBar uses.
    @Test func dropsWhatMovesTheTemporaryFoldersAndSQLitesVariables() {
        let chosen = [
            "HOME": "/Users/avery", "DIRHELPER_USER_DIR_SUFFIX": "elsewhere", "SQLITE_SQLLOG_DIR": "/tmp/elsewhere",
            "SQLITE_AUTO_TRACE": "1", "TMPDIR": "/var/folders/xy/T/", "BRIEFBAR_TEAMS_DB": "/tmp/demo/db2/db",
        ]
        #expect(LaunchEnvironment.changes(chosen, home: "/Users/avery") == [
            "DIRHELPER_USER_DIR_SUFFIX": .remove, "SQLITE_SQLLOG_DIR": .remove, "SQLITE_AUTO_TRACE": .remove,
        ])
    }

    /// Only with its own permissions: run from a shell, with that app's, BriefBar keeps the environment it was given.
    @Test func changesTheEnvironmentOnlyWithItsOwnPermissions() {
        let chosen = ["HOME": "/tmp/elsewhere", "CFFIXED_USER_HOME": "/tmp/elsewhere", "SQLITE_TMPDIR": "/tmp/elsewhere"]
        #expect(LaunchEnvironment.changes(chosen, home: "/Users/avery", attribution: .itself) == [
            "HOME": .set("/Users/avery"), "CFFIXED_USER_HOME": .remove, "SQLITE_TMPDIR": .remove,
        ])
        #expect(LaunchEnvironment.changes(chosen, home: "/Users/avery", attribution: .caller).isEmpty)
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
