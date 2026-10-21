import Foundation

/// A file's identity, size and modification time, to tell when a path points at a new file or a file
/// has grown.
public struct FileInfo: Sendable, Equatable {
    public struct ID: Sendable, Equatable {
        public var device: Int64
        public var inode: UInt64
    }

    public var id: ID
    public var size: UInt64
    /// Modification time in nanoseconds since 1970.
    public var modified: Int64

    public init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        self.init(info)
    }

    public init?(descriptor: Int32) {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return nil }
        self.init(info)
    }

    private init(_ info: stat) {
        id = ID(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
        size = UInt64(max(0, info.st_size))
        modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
    }
}
