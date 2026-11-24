import Foundation

/// Backslash escaping for text typed at a shell prompt, with the same character set as Ghostty's
/// `Ghostty.Shell.escape`. Used for files dropped on a terminal.
enum ShellEscape {
    static let specialCharacters: Set<Character> = [
        "\\", " ", "(", ")", "[", "]", "{", "}", "<", ">", "\"", "'", "`",
        "!", "#", "$", "&", ";", "|", "*", "?", "\t",
    ]

    static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            if ShellEscape.specialCharacters.contains(character) {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }

    /// Dropped files as shell words on one line.
    static func dropText(paths: [String]) -> String {
        paths.map { ShellEscape.escape($0) }.joined(separator: " ")
    }
}
