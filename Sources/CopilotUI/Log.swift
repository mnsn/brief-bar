import BriefBarUI
import os

/// Diagnostics: `log show --last 10m --predicate 'subsystem == "com.asaf.BriefBar" && category == "copilot"'`
///
/// Only counts, states and errors. Never session names or prompts.
enum Log {
    static let app = Logger(subsystem: AppIdentity.bundleIdentifier, category: "copilot")
}
