import Foundation

/// Exists only on tabs reopened from the previous app session, never on new terminals.
struct TerminalRestoration: Equatable {
    let departedAt: Date?
    var outputID: UUID? = nil

    /// Display-only input to Ghostty, never stdin for the restored shell/SSH.
    var previousOutput: String? {
        guard let outputID, let text = TerminalOutputStore.shared.load(outputID), !text.isEmpty else { return nil }
        return text.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n"
    }

    func notice(restoredAt: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "MM/dd HH:mm"

        let departure = departedAt.map {
            String(format: String(localized: "Left at %@"), formatter.string(from: $0))
        } ?? String(localized: "Left at unknown time")
        let restoration = String(format: String(localized: "Restored at %@"), formatter.string(from: restoredAt))
        // Output only: never send these lines to the shell or an SSH authentication prompt.
        return "\r\n\u{1b}[2m── \(departure) ──\u{1b}[0m\r\n\r\n\u{1b}[2m── \(restoration) ──\u{1b}[0m\r\n\r\n"
    }
}
