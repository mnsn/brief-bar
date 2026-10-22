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
/// - `TMPDIR` moves neither temporary folder: Foundation and SQLite take the one macOS names. But SQLite falls back to
///   `TMPDIR` when it can't write there, and macOS only stops that folder being deleted or renamed: you own it, so a
///   program running as you can make it unwritable, and with `TMPDIR` choose where SQLite's files go.
///
/// So BriefBar puts back `HOME` and `TMPDIR`, and drops the others, before anything reads them.
public enum LaunchEnvironment {
    public enum Change: Equatable, Sendable {
        case set(String)
        case remove
    }

    /// What to change in `environment` for BriefBar to find your files where they are: `home`, from the user database,
    /// and `temporaryFolder`, the one macOS gives you. Without one, `TMPDIR` goes, so that it's no folder whoever
    /// started BriefBar chose.
    public static func changes(_ environment: [String: String], home: String, temporaryFolder: String?) -> [String: Change] {
        var changes: [String: Change] = [:]
        if environment["HOME"] != home {
            changes["HOME"] = .set(home)
        }
        if let temporaryFolder {
            if environment["TMPDIR"] != temporaryFolder { changes["TMPDIR"] = .set(temporaryFolder) }
        } else if environment["TMPDIR"] != nil {
            changes["TMPDIR"] = .remove
        }
        for name in environment.keys where isDropped(name) {
            changes[name] = .remove
        }
        return changes
    }

    /// The same, for BriefBar run with these permissions: nothing with those of the app that started it, such as
    /// Terminal, whose environment it uses as it is, the demo's variables included.
    public static func changes(
        _ environment: [String: String], home: String, temporaryFolder: String?, attribution: Attribution
    ) -> [String: Change] {
        attribution == .itself ? changes(environment, home: home, temporaryFolder: temporaryFolder) : [:]
    }

    static func isDropped(_ name: String) -> Bool {
        name == "CFFIXED_USER_HOME" || name == "DIRHELPER_USER_DIR_SUFFIX" || name.hasPrefix("SQLITE_")
    }

    /// Makes those changes to this process's environment, if BriefBar has its own permissions: first thing, before any
    /// framework reads it.
    public static func secure(_ attribution: Attribution = .current) {
        guard attribution == .itself else { return }
        // Before asking macOS for your temporary folder, which it would move.
        unsetenv("DIRHELPER_USER_DIR_SUFFIX")
        let environment = ProcessInfo.processInfo.environment
        for (name, change) in changes(environment, home: UserHome.url.path, temporaryFolder: temporaryFolder(), attribution: attribution) {
            switch change {
            case .set(let value): setenv(name, value, 1)
            case .remove: unsetenv(name)
            }
        }
    }

    /// The temporary folder macOS gives your account (`confstr`), or nil when it doesn't say.
    static func temporaryFolder() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 else { return nil }
        let folder = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return folder.isEmpty ? nil : folder
    }
}
