import BriefBarUI
import os

/// Diagnostics: `log show --last 10m --predicate 'subsystem == "com.asaf.BriefBar" && category == "teams"'`
///
/// Only counts, states and errors. Never chat names, messages or IDs.
enum Log {
    static let app = Logger(subsystem: AppIdentity.bundleIdentifier, category: "teams")
}
