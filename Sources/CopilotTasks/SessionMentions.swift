import Darwin
import Foundation

/// Which sessions' logs mention a pull request or a work item by a link to it: to find the session that opened a pull
/// request when nothing else says, such as one that worked in a folder of repositories rather than on the pull request's
/// branch. A log is read in chunks, without following a symbolic link, only until its first mention.
public enum SessionMentions {
    /// What a mention is: a link that ends with its number, in its organization.
    public struct Target: Sendable, Equatable {
        /// The Azure DevOps organization, which a link names shortly before the number.
        public var organization: String
        public var number: Int
        /// What comes right before the number in a link to it.
        var prefixes: [String]

        /// A pull request's page, `…/_git/<repository>/pullrequest/<number>`, or its link in the REST API,
        /// `…/pullRequests/<number>`.
        public static func pullRequest(organization: String, number: Int) -> Target {
            Target(organization: organization, number: number, prefixes: ["pullrequest/", "pullRequests/", "pullrequests/"])
        }

        /// A work item's page, `…/_workitems/edit/<id>`, or its link in the REST API, `…/workItems/<id>`.
        public static func workItem(organization: String, id: Int) -> Target {
            Target(organization: organization, number: id, prefixes: ["_workitems/edit/", "workItems/", "workitems/"])
        }

        var needles: [[UInt8]] { prefixes.map { Array("\($0)\(number)".utf8) } }
    }

    /// How far before the number the organization's name may be, in bytes: farther than in any link to it.
    static let window = 512

    /// Whether the log mentions it: its number right after one of its links' paths, and not followed by another digit,
    /// with its organization's name shortly before. False for a symbolic link, or anything but a regular file.
    public static func mentions(_ target: Target, in events: URL, chunkSize: Int = 1 << 20) -> Bool {
        let descriptor = open(events.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }

        let needles = target.needles
        let organization = Array(target.organization.lowercased().utf8)
        guard !organization.isEmpty, let longest = needles.map(\.count).max() else { return false }
        // What's kept of the bytes read before: enough for a link that starts in them, and the window before it.
        let overlap = window + longest
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: max(chunkSize, overlap))
        while true {
            let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            buffer.append(contentsOf: chunk[..<count])
            if found(needles, organization: organization, in: buffer, isEnd: false) { return true }
            if buffer.count > overlap { buffer.removeFirst(buffer.count - overlap) }
        }
        return found(needles, organization: organization, in: buffer, isEnd: true)
    }

    /// Whether the bytes hold a mention. One whose next byte hasn't been read yet waits for it, unless they're the last.
    static func found(_ needles: [[UInt8]], organization: [UInt8], in buffer: [UInt8], isEnd: Bool) -> Bool {
        buffer.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return false }
            for needle in needles {
                var start = 0
                while start + needle.count <= bytes.count,
                      let match = needle.withUnsafeBytes({ memmem(base + start, bytes.count - start, $0.baseAddress, $0.count) }) {
                    let at = base.distance(to: UnsafeRawPointer(match))
                    let next = at + needle.count
                    start = at + 1
                    if next == bytes.count, !isEnd { continue }
                    if next < bytes.count, (0x30...0x39).contains(bytes[next]) { continue }
                    let from = max(0, at - window)
                    let before = bytes[from..<at].map { (0x41...0x5A).contains($0) ? $0 | 0x20 : $0 }
                    let named = before.withUnsafeBytes { window in
                        organization.withUnsafeBytes { memmem(window.baseAddress, window.count, $0.baseAddress, $0.count) } != nil
                    }
                    if named { return true }
                }
            }
            return false
        }
    }
}
