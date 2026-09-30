import Foundation

@main
enum CommandFinishedPolicyTests {
    static func main() {
        durations()
        fallback()
        configured()
        print("ok")
    }

    static func durations() {
        expect(CommandFinishedPolicy.seconds(fromGhosttyDuration: "45s") == 45, "45s")
        expect(CommandFinishedPolicy.seconds(fromGhosttyDuration: "1h30m") == 5400, "1h30m")
        expect(CommandFinishedPolicy.seconds(fromGhosttyDuration: "1m 5s") == 65, "spaces between parts")
        expect(CommandFinishedPolicy.seconds(fromGhosttyDuration: "500ms") == 0.5, "milliseconds")
        expect(CommandFinishedPolicy.seconds(fromGhosttyDuration: "10") == nil, "a number needs a unit")
        expect(CommandFinishedPolicy.seconds(fromGhosttyDuration: "s") == nil, "a unit needs a number")
        expect(CommandFinishedPolicy.seconds(fromGhosttyDuration: "5x") == nil, "unknown unit")
        expect(CommandFinishedPolicy.seconds(fromGhosttyDuration: "") == nil, "empty")
    }

    static func fallback() {
        let policy = CommandFinishedPolicy.from([])
        expect(policy == .fallback, "no snippet keys means the fallback")
        expect(policy.actions(duration: 12, attended: false) == (true, false), "long command in a hidden session notifies")
        expect(policy.actions(duration: 12, attended: true) == (false, false), "the user is looking at it")
        expect(policy.actions(duration: 9, attended: false) == (false, false), "short commands stay quiet")
    }

    static func configured() {
        let bellOnly = CommandFinishedPolicy.from([entry("notify-on-command-finish", "always")])
        expect(bellOnly.actions(duration: 6, attended: true) == (false, true), "Ghostty's default action is only the bell")
        expect(bellOnly.actions(duration: 4, attended: true) == (false, false), "Ghostty's default threshold is 5s")

        let notify = CommandFinishedPolicy.from([
            entry("notify-on-command-finish", "unfocused"),
            entry("notify-on-command-finish-action", "no-bell,notify"),
            entry("notify-on-command-finish-after", "2s"),
        ])
        expect(notify.actions(duration: 3, attended: false) == (true, false), "configured action and threshold")
        expect(notify.actions(duration: 3, attended: true) == (false, false), "unfocused skips an attended session")

        let never = CommandFinishedPolicy.from([
            entry("notify-on-command-finish", "always"),
            entry("notify-on-command-finish", "never"),
        ])
        expect(never.actions(duration: 100, attended: false) == (false, false), "the last line wins")

        let badValue = CommandFinishedPolicy.from([
            entry("notify-on-command-finish", "always"),
            entry("notify-on-command-finish-after", "soon"),
        ])
        expect(badValue.threshold == CommandFinishedPolicy.ghosttyDefaultThreshold, "an unreadable duration is ignored")
    }

    static func entry(_ key: String, _ value: String) -> TerminalConfigEntry {
        TerminalConfigEntry(key: key, value: value)
    }

    static func expect(_ condition: Bool, _ message: String) {
        if !condition { fail(message) }
    }

    static func fail(_ message: String) -> Never {
        fputs("FAIL \(message)\n", stderr)
        exit(1)
    }
}
