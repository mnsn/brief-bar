import SwiftUI

/// Text as VoiceOver says it, and what it hears as something changes.
package enum SpokenText {
    /// Without the quotes around the names it quotes, "‘Retry backoff’", which it would read out: an apostrophe in a name,
    /// "‘Sam’s fix’", stays.
    package static func unquoted(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        var isQuoting = false
        for (index, character) in characters.enumerated() {
            if character == "‘" {
                isQuoting = true
                continue
            }
            if character == "’", isQuoting, index + 1 == characters.count || !characters[index + 1].isLetter {
                isQuoting = false
                continue
            }
            result.append(character)
        }
        return result
    }

    /// Says it to VoiceOver, wherever the keyboard is, as what you did, or asked for, comes to pass.
    package static func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }
}
