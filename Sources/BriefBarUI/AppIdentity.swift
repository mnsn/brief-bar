import Foundation

/// BriefBar's own names: its bundle identifier, which is also its preferences' domain and its log's
/// subsystem.
package enum AppIdentity {
    package static let bundleIdentifier = "com.asaf.BriefBar"
    package static let name = "BriefBar"

    /// Whether this is the installed app, rather than a binary run from Terminal or `.build`.
    package static var isBundled: Bool { Bundle.main.bundleIdentifier == bundleIdentifier }

    /// The installed app's preferences, also from the command line. Inside the app that's the standard
    /// defaults: macOS won't open your own domain as a suite.
    package static var installedAppDefaults: UserDefaults? {
        isBundled ? .standard : UserDefaults(suiteName: bundleIdentifier)
    }

    package static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build"
    }
}
