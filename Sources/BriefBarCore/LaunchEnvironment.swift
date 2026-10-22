import Darwin
import Foundation

/// Started with its own permissions (`Attribution.itself`), BriefBar has the environment that whoever started it chose,
/// and some variables move where macOS keeps and finds your files:
///
/// - `HOME` chooses the keychain the Security framework uses, where the key to Teams' saved chats is. A keychain that
///   program made would get a new key, and the chats BriefBar read with its Full Disk Access sealed with it.
/// - `CFFIXED_USER_HOME` moves FileManager's home folder, and with it Library and the caches.
/// - `SQLITE_TMPDIR` is where SQLite writes what a query sorts that doesn't fit in memory.
///
/// So BriefBar puts back the first and drops the others before anything reads them.
public enum LaunchEnvironment {
    public enum Change: Equatable, Sendable {
        case set(String)
        case remove
    }

    /// What to change in `environment` for BriefBar to find your files where they are.
    public static func changes(_ environment: [String: String], home: String) -> [String: Change] {
        var changes: [String: Change] = [:]
        if environment["HOME"] != home {
            changes["HOME"] = .set(home)
        }
        for name in ["CFFIXED_USER_HOME", "SQLITE_TMPDIR"] where environment[name] != nil {
            changes[name] = .remove
        }
        return changes
    }

    /// Makes those changes to this process's environment: first thing, before any framework reads it.
    public static func secure() {
        for (name, change) in changes(ProcessInfo.processInfo.environment, home: UserHome.url.path) {
            switch change {
            case .set(let value): setenv(name, value, 1)
            case .remove: unsetenv(name)
            }
        }
    }
}
