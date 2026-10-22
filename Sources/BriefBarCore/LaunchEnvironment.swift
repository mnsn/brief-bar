import Darwin
import Foundation

/// Started with its own permissions (`Attribution.itself`), BriefBar has the environment that whoever started it chose,
/// and some variables move where macOS keeps and finds your files:
///
/// - `HOME` chooses the keychain the Security framework uses, where the key to Teams' saved chats is. A keychain that
///   program made would get a new key, and the chats BriefBar read with its Full Disk Access sealed with it.
/// - `CFFIXED_USER_HOME` moves FileManager's home folder, and with it Library and the caches.
/// - `DIRHELPER_USER_DIR_SUFFIX` moves the temporary and cache folders that macOS gives each account (`confstr`), which
///   Foundation and SQLite write to, into a folder of that name inside them. macOS ignores it for an app with the
///   hardened runtime, as BriefBar's builds are, so it's dropped in case that changes.
/// - SQLite's own: `SQLITE_TMPDIR` is where it writes what a query sorts that doesn't fit in memory, and macOS's SQLite
///   is built with others, such as `SQLITE_SQLLOG_DIR`, with which SQLite copies each database it opens into that
///   folder (macOS 27's does nothing with it). BriefBar uses none of them.
///
/// So BriefBar puts back the first and drops the others before anything reads them. `TMPDIR` moves neither temporary
/// folder: Foundation and SQLite take the one macOS names, and fall back to `TMPDIR` only if that folder can't be
/// written to, which a program running as you can't arrange, since macOS protects it.
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
        for name in environment.keys where isDropped(name) {
            changes[name] = .remove
        }
        return changes
    }

    /// The same, for BriefBar run with these permissions: nothing with those of the app that started it, such as
    /// Terminal, whose environment it uses as it is, the demo's variables included.
    public static func changes(_ environment: [String: String], home: String, attribution: Attribution) -> [String: Change] {
        attribution == .itself ? changes(environment, home: home) : [:]
    }

    static func isDropped(_ name: String) -> Bool {
        name == "CFFIXED_USER_HOME" || name == "DIRHELPER_USER_DIR_SUFFIX" || name.hasPrefix("SQLITE_")
    }

    /// Makes those changes to this process's environment, if BriefBar has its own permissions: first thing, before any
    /// framework reads it.
    public static func secure(_ attribution: Attribution = .current) {
        for (name, change) in changes(ProcessInfo.processInfo.environment, home: UserHome.url.path, attribution: attribution) {
            switch change {
            case .set(let value): setenv(name, value, 1)
            case .remove: unsetenv(name)
            }
        }
    }
}
