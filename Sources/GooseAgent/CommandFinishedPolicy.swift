import Foundation

/// What to do when a shell-integrated command exits. The engine only reports the exit; Ghostty's
/// `notify-on-command-finish`, `-action` and `-after` are applied by the host, read here from the
/// advanced snippet.
struct CommandFinishedPolicy: Equatable {
    enum Mode: String {
        case never
        case unfocused
        case always
    }

    /// Without `notify-on-command-finish` in the snippet: notify for a command at least this long
    /// in a session the user is not looking at.
    static let fallbackThreshold: TimeInterval = 10
    /// Ghostty's default for `notify-on-command-finish-after`.
    static let ghosttyDefaultThreshold: TimeInterval = 5

    static let fallback = CommandFinishedPolicy(
        mode: .unfocused,
        notify: true,
        bell: false,
        threshold: CommandFinishedPolicy.fallbackThreshold
    )

    var mode: Mode
    var notify: Bool
    var bell: Bool
    var threshold: TimeInterval

    /// Later lines win, as in a Ghostty config file. An unreadable value keeps the one before it.
    static func from(_ entries: [TerminalConfigEntry]) -> CommandFinishedPolicy {
        var mode: Mode?
        // Ghostty's `notify-on-command-finish-action` default is `bell,no-notify`.
        var notify = false
        var bell = true
        var threshold = CommandFinishedPolicy.ghosttyDefaultThreshold
        for entry in entries {
            let value = entry.value.trimmingCharacters(in: .whitespaces).lowercased()
            switch entry.key {
            case "notify-on-command-finish":
                if let parsed = Mode(rawValue: value) {
                    mode = parsed
                }
            case "notify-on-command-finish-action":
                if value == "true" {
                    notify = true
                    bell = true
                } else if value == "false" {
                    notify = false
                    bell = false
                } else {
                    for flag in value.split(separator: ",") {
                        let name = flag.trimmingCharacters(in: .whitespaces)
                        switch name {
                        case "notify": notify = true
                        case "no-notify": notify = false
                        case "bell": bell = true
                        case "no-bell": bell = false
                        default: break
                        }
                    }
                }
            case "notify-on-command-finish-after":
                if let seconds = CommandFinishedPolicy.seconds(fromGhosttyDuration: value) {
                    threshold = seconds
                }
            default:
                break
            }
        }
        guard let mode else { return .fallback }
        return CommandFinishedPolicy(mode: mode, notify: notify, bell: bell, threshold: threshold)
    }

    /// `attended`: the app is frontmost and the session is on screen.
    func actions(duration: TimeInterval, attended: Bool) -> (notify: Bool, bell: Bool) {
        if mode == .never {
            return (false, false)
        }
        if mode == .unfocused && attended {
            return (false, false)
        }
        if duration < threshold {
            return (false, false)
        }
        return (notify, bell)
    }

    /// Ghostty duration syntax: numbers with units, summed, e.g. `1h30m`, `45s`, `500ms`.
    static func seconds(fromGhosttyDuration text: String) -> TimeInterval? {
        let units: [String: TimeInterval] = [
            "y": 365 * 86400,
            "w": 7 * 86400,
            "d": 86400,
            "h": 3600,
            "m": 60,
            "s": 1,
            "ms": 0.001,
            "us": 0.000001,
            "µs": 0.000001,
            "ns": 0.000000001,
        ]
        var total: TimeInterval = 0
        var number = ""
        var unit = ""
        var parts = 0

        func flush() -> Bool {
            guard let value = Double(number), let scale = units[unit] else { return false }
            total += value * scale
            parts += 1
            number = ""
            unit = ""
            return true
        }

        for character in text where !character.isWhitespace {
            if character.isASCII && character.isNumber {
                if !unit.isEmpty {
                    guard flush() else { return nil }
                }
                number.append(character)
            } else {
                guard !number.isEmpty else { return nil }
                unit.append(character)
            }
        }
        if !number.isEmpty || !unit.isEmpty {
            guard flush() else { return nil }
        }
        if parts == 0 {
            return nil
        }
        return total
    }
}
