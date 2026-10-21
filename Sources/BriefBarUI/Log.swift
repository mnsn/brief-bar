import os

/// Diagnostics: `log show --last 10m --predicate 'subsystem == "com.asaf.BriefBar"'`
///
/// Only counts, states and errors. Never names, messages, titles or IDs.
enum Log {
    static let app = Logger(subsystem: AppIdentity.bundleIdentifier, category: "app")
}
