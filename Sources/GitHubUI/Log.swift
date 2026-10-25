import BriefBarUI
import os

/// Diagnostics: `log show --last 10m --predicate 'subsystem == "com.asaf.BriefBar" && category == "github"'`
///
/// Only counts, states and errors. Never titles, repositories or tokens.
enum Log {
    static let app = Logger(subsystem: AppIdentity.bundleIdentifier, category: "github")
}
