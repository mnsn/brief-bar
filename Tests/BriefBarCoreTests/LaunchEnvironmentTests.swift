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

    /// The home folder the user database names, which no variable moves.
    @Test func findsYourHomeInTheUserDatabase() throws {
        let home = UserHome.url.path
        #expect(home != "/var/empty")
        #expect(home == NSHomeDirectoryForUser(NSUserName()))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: home, isDirectory: &isDirectory) && isDirectory.boolValue)
    }
}
