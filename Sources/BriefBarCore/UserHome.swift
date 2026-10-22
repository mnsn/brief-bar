import Darwin
import Foundation

/// Your home folder, as the user database names it (`getpwuid_r`). Use it rather than FileManager's, which follows
/// `CFFIXED_USER_HOME`, or `HOME`: whoever starts BriefBar sets those. If the user database can't say, a folder that
/// holds nothing, so nothing is read or written there.
public enum UserHome {
    public static let url: URL = {
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: max(Int(sysconf(_SC_GETPW_R_SIZE_MAX)), 16_384))
        if getpwuid_r(getuid(), &record, &buffer, buffer.count, &result) == 0, let result, let directory = result.pointee.pw_dir {
            let path = String(cString: directory)
            if !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        }
        return URL(fileURLWithPath: "/var/empty", isDirectory: true)
    }()
}
