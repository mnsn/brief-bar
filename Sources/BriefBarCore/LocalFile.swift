import Darwin
import Foundation

/// Reads a run's files without following a symbolic link: they're in folders any program running as you can write to,
/// and BriefBar may have Full Disk Access, which such a link would hand to whoever made it.
public enum LocalFile {
    /// The end of a regular file, up to `maxBytes`; nil for a link, a folder, or a file that isn't there.
    public static func tail(of url: URL, maxBytes: Int) -> Data? {
        tail(descriptor: open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK), maxBytes: maxBytes)
    }

    /// The end of a file below a folder, opened without following a symbolic link below it (`openFile(below:_:)`): at
    /// most `maxBytes`; nil unless it's a regular file.
    public static func tail(below root: URL, _ components: [String], maxBytes: Int) -> Data? {
        tail(descriptor: openFile(below: root, components), maxBytes: maxBytes)
    }

    /// The start of a file below a folder, opened without following a symbolic link below it (`openFile(below:_:)`): at
    /// most `maxBytes`, and when the file last changed; nil unless it's a regular file.
    public static func head(below root: URL, _ components: [String], maxBytes: Int) -> (data: Data, modified: Date)? {
        let descriptor = openFile(below: root, components)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              let data = try? handle.read(upToCount: max(maxBytes, 0)) ?? Data()
        else { return nil }
        let modified = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return (data, Date(timeIntervalSince1970: modified))
    }

    /// Opens a file below a folder, read-only, without following a symbolic link below it: neither the file nor any
    /// folder on the way to it may be one, so it can't lead out of the folder, which may be one itself, as `~/.copilot`
    /// can. Each component is a single name, never `..`. -1 when it can't be opened so.
    public static func openFile(below root: URL, _ components: [String]) -> Int32 {
        guard let name = components.last,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") })
        else { return -1 }
        var folder = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        for component in components.dropLast() where folder >= 0 {
            let next = openat(folder, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(folder)
            folder = next
        }
        guard folder >= 0 else { return -1 }
        defer { close(folder) }
        return openat(folder, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    }

    private static func tail(descriptor: Int32, maxBytes: Int) -> Data? {
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let size = UInt64(max(info.st_size, 0))
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil else { return nil }
        return try? handle.read(upToCount: Int(size - start)) ?? Data()
    }

    /// Whether the path is a symbolic link.
    public static func isLink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
    }
}
