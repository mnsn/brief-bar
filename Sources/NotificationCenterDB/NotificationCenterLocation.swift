import Foundation

/// Where Notification Center keeps its database.
public enum NotificationCenterLocation {
    /// Notification Center's SQLite database, which macOS protects: reading it needs Full Disk Access.
    public static func systemDatabase(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
    }

    /// Whether two paths name the same file, allowing for symbolic links and letter case (APFS is
    /// usually case-insensitive). Errs toward "the same", which only makes BriefBar more careful.
    public static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        let first = a.standardizedFileURL.resolvingSymlinksInPath().path
        let second = b.standardizedFileURL.resolvingSymlinksInPath().path
        if first.compare(second, options: .caseInsensitive) == .orderedSame { return true }
        var one = stat()
        var other = stat()
        guard stat(a.path, &one) == 0, stat(b.path, &other) == 0 else { return false }
        return one.st_dev == other.st_dev && one.st_ino == other.st_ino
    }
}
