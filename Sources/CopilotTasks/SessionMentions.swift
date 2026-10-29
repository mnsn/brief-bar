import BriefBarCore
import Darwin
import Foundation

/// Which sessions' logs mention a pull request or a work item by a link to it: to find the session that opened a pull
/// request when nothing else says, such as one that worked in a folder of repositories rather than on the pull request's
/// branch. A log is read in chunks, without following a symbolic link below the app's folder, only until its first mention.
public enum SessionMentions {
    /// What a mention is: a link that ends with its number, in its organization.
    public struct Target: Sendable, Equatable {
        /// The Azure DevOps organization, which the link names: in its path on dev.azure.com, or in its own host.
        public var organization: String
        public var number: Int
        /// What comes right before the number in a link to it, in lowercase: a link matches whatever its case, as Azure
        /// DevOps takes them.
        var prefixes: [String]

        /// A pull request's page, `…/_git/<repository>/pullrequest/<number>`, also written `pullRequest`, or its link in
        /// the REST API, `…/pullRequests/<number>`.
        public static func pullRequest(organization: String, number: Int) -> Target {
            Target(organization: organization, number: number, prefixes: ["pullrequest/", "pullrequests/"])
        }

        /// A work item's page, `…/_workitems/edit/<id>`, or its link in the REST API, `…/workItems/<id>`.
        public static func workItem(organization: String, id: Int) -> Target {
            Target(organization: organization, number: id, prefixes: ["_workitems/edit/", "workitems/"])
        }

        var needles: [[UInt8]] { prefixes.map { Array("\($0)\(number)".utf8) } }
    }

    /// How far before the number its link may start, in bytes: farther than any link to it reaches.
    static let window = 512

    /// Whether a session's log, `session-state/<id>/events.jsonl` in the app's folder, mentions it (`mentions(_:in:)`).
    /// Opened without following a symbolic link below that folder (`LocalFile.openFile(below:_:)`): neither the log nor
    /// the session's folders may be one, so BriefBar, which may have Full Disk Access, reads nothing outside the app's
    /// sessions. False for an ID that isn't a session's.
    public static func mentions(_ target: Target, inSession id: String, home: URL, chunkSize: Int = 1 << 20) -> Bool {
        guard AppSessions.isSessionID(id) else { return false }
        let descriptor = LocalFile.openFile(below: home, AppSessions.stateFile(id, "events.jsonl", home: home))
        return mentions(target, descriptor: descriptor, chunkSize: chunkSize)
    }

    /// Whether the log mentions it: its number right after one of its links' paths, not followed by another digit, in a
    /// link to its organization, `https://dev.azure.com/<organization>/…` or `https://<organization>.visualstudio.com/…`.
    /// False for a symbolic link, or anything but a regular file.
    static func mentions(_ target: Target, in events: URL, chunkSize: Int = 1 << 20) -> Bool {
        mentions(target, descriptor: open(events.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK), chunkSize: chunkSize)
    }

    private static func mentions(_ target: Target, descriptor: Int32, chunkSize: Int) -> Bool {
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }

        let needles = target.needles
        let organization = Array(target.organization.utf8).map(lowercased)
        guard !organization.isEmpty, let longest = needles.map(\.count).max() else { return false }
        // What's kept of the bytes read before: enough for a link that starts in them, and the window before it.
        let overlap = window + longest
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: max(chunkSize, overlap))
        while true {
            let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            // In lowercase, as the prefixes are: a link's path matches whatever its case.
            chunk.withUnsafeMutableBytes { bytes in
                for index in 0..<count { bytes[index] = lowercased(bytes[index]) }
            }
            buffer.append(contentsOf: chunk[..<count])
            if found(needles, organization: organization, in: buffer, isEnd: false) { return true }
            if buffer.count > overlap { buffer.removeFirst(buffer.count - overlap) }
        }
        return found(needles, organization: organization, in: buffer, isEnd: true)
    }

    /// Whether the bytes hold a mention. One whose next byte hasn't been read yet waits for it, unless they're the last:
    /// it's then at least `window` bytes from the start of the bytes kept, so its link's start is still there.
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
                    if self.organization(ofLinkTo: at, in: bytes) == organization { return true }
                }
            }
            return false
        }
    }

    /// The organization of the Azure DevOps link whose path reaches `end`, lowercased: its path's first segment on
    /// `dev.azure.com`, or the first part of an organization's own host, `<organization>.visualstudio.com`. Nil when the
    /// bytes before `end`, within `window`, aren't part of such a link: back to its `http://` or `https://`, nothing that
    /// ends a link, such as a space or a quote.
    static func organization(ofLinkTo end: Int, in bytes: UnsafeRawBufferPointer) -> [UInt8]? {
        let floor = max(0, end - window)
        var index = end - 1
        var separator: Int?
        while index >= floor {
            let byte = bytes[index]
            if endsLink(byte) { return nil }
            if byte == slash, index >= 2, bytes[index - 1] == slash, bytes[index - 2] == colon {
                separator = index - 2
                break
            }
            index -= 1
        }
        guard let separator, hasScheme(endingAt: separator, in: bytes) else { return nil }
        // The host, without a user name or a port.
        let hostStart = separator + 3
        var hostEnd = hostStart
        while hostEnd < end, bytes[hostEnd] != slash { hostEnd += 1 }
        guard hostEnd < end else { return nil }
        var host = bytes[hostStart..<hostEnd].map(lowercased)
        if let at = host.lastIndex(of: 0x40) { host = Array(host[(at + 1)...]) }
        if let port = host.firstIndex(of: colon) { host = Array(host[..<port]) }
        if host == devAzure {
            let segmentStart = hostEnd + 1
            var segmentEnd = segmentStart
            while segmentEnd < end, bytes[segmentEnd] != slash { segmentEnd += 1 }
            guard segmentEnd < end, segmentEnd > segmentStart else { return nil }
            return bytes[segmentStart..<segmentEnd].map(lowercased)
        }
        if host.count > visualStudio.count, host.suffix(visualStudio.count).elementsEqual(visualStudio) {
            return Array(host.dropLast(visualStudio.count))
        }
        return nil
    }

    private static let slash = UInt8(ascii: "/")
    private static let colon = UInt8(ascii: ":")
    private static let devAzure = Array("dev.azure.com".utf8)
    private static let visualStudio = Array(".visualstudio.com".utf8)

    /// `http` or `https`, right before the `://` at `separator`.
    private static func hasScheme(endingAt separator: Int, in bytes: UnsafeRawBufferPointer) -> Bool {
        ["https", "http"].contains { scheme in
            let letters = Array(scheme.utf8)
            guard separator >= letters.count else { return false }
            return bytes[(separator - letters.count)..<separator].map(lowercased).elementsEqual(letters)
        }
    }

    /// What can't be part of a link: spaces and control characters, quotes and backticks, brackets, and the backslash
    /// that escapes a quote in JSON.
    private static func endsLink(_ byte: UInt8) -> Bool {
        byte <= 0x20 || byte == 0x7F || linkEnds.contains(byte)
    }

    private static let linkEnds = Set("\"'`<>()[]{}|^\\".utf8)

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        (0x41...0x5A).contains(byte) ? byte | 0x20 : byte
    }
}
