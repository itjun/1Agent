import Foundation

enum CommandHistoryFormat: String, CaseIterable, Identifiable {
    case zsh, bash, fish
    var id: String { rawValue }
    var relativePath: String {
        switch self {
        case .zsh: return ".zsh_history"
        case .bash: return ".bash_history"
        case .fish: return ".local/share/fish/fish_history"
        }
    }
}

struct CommandHistoryCandidate: Identifiable, Equatable {
    var id: String { command }
    var command: String
    var count: Int
    var lastUsed: Date?
}

struct CommandHistoryResult {
    var candidates: [CommandHistoryCandidate]
    var parsedCount: Int
    var truncated: Bool
}

enum CommandHistoryParser {
    static let byteLimit = 4 * 1024 * 1024
    static let recordLimit = 5_000

    static func parse(_ data: Data, format: CommandHistoryFormat, truncated: Bool) -> CommandHistoryResult {
        var text = String(decoding: data, as: UTF8.self)
        if truncated {
            // Drop the partial leading line. Structured formats additionally discard any
            // continuation until a complete record header, below.
            text = text.firstIndex(of: "\n").map { String(text[text.index(after: $0)...]) } ?? ""
        }
        let lines = text.components(separatedBy: "\n")
        var records: [(String, Date?)] = []
        var omittedRecords = false
        var buffer: String?
        var date: Date?
        func append(_ value: String, _ date: Date?) {
            records.append((value, date))
            if records.count > recordLimit * 2 {
                records.removeFirst(records.count - recordLimit)
                omittedRecords = true
            }
        }
        func flush() {
            if let buffer, !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { append(buffer, date) }
            buffer = nil; date = nil
        }
        switch format {
        case .fish:
            for line in lines {
                if line.hasPrefix("- cmd: ") { flush(); buffer = fishUnescape(String(line.dropFirst(7))) }
                else if line.hasPrefix("  when:"), let stamp = Double(line.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                    date = Date(timeIntervalSince1970: stamp)
                }
            }
            flush()
        case .bash:
            let timestamped = lines.contains { bashTimestamp($0) != nil }
            for line in lines {
                if let stamp = bashTimestamp(line) { flush(); date = Date(timeIntervalSince1970: stamp); buffer = "" }
                else if timestamped {
                    guard buffer != nil else { continue }
                    if buffer!.isEmpty { buffer = line } else { buffer! += "\n" + line }
                } else if !line.isEmpty { append(line, nil) }
            }
            if timestamped { if buffer?.hasSuffix("\n") == true { buffer!.removeLast() }; flush() }
        case .zsh:
            let extended = lines.contains { zshHeader($0) != nil }
            var continuing = false
            for line in lines {
                if continuing {
                    buffer = (buffer ?? "") + "\n" + line
                } else if let header = zshHeader(line) {
                    flush(); date = header.1; buffer = header.0
                } else {
                    flush()
                    if extended && truncated && records.isEmpty { continue }
                    buffer = line
                }
                continuing = buffer?.hasSuffix("\\") == true
                if continuing { buffer!.removeLast() } else { flush() }
            }
            // An unfinished record at the file tail is not a candidate.
            if !continuing { flush() }
        }
        let recent = records.suffix(recordLimit)
        var grouped: [String: CommandHistoryCandidate] = [:]
        for (command, date) in recent where command.utf8.count <= 65_536 && !command.contains("\u{fffd}") {
            var row = grouped[command] ?? CommandHistoryCandidate(command: command, count: 0, lastUsed: nil)
            row.count += 1
            if let date, row.lastUsed == nil || date > row.lastUsed! { row.lastUsed = date }
            grouped[command] = row
        }
        return CommandHistoryResult(candidates: grouped.values.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            if $0.lastUsed != $1.lastUsed { return ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
            return $0.command < $1.command
        }, parsedCount: recent.count, truncated: truncated || omittedRecords || records.count > recordLimit)
    }

    private static func bashTimestamp(_ line: String) -> Double? {
        guard line.hasPrefix("#"), line.count > 1, line.dropFirst().allSatisfy(\.isNumber) else { return nil }
        return Double(line.dropFirst())
    }
    private static func zshHeader(_ line: String) -> (String, Date?)? {
        guard line.hasPrefix(": "), let semicolon = line.firstIndex(of: ";") else { return nil }
        let parts = line[line.index(line.startIndex, offsetBy: 2)..<semicolon].split(separator: ":")
        guard parts.count == 2, let time = Double(parts[0]), Double(parts[1]) != nil else { return nil }
        return (String(line[line.index(after: semicolon)...]), Date(timeIntervalSince1970: time))
    }
    private static func fishUnescape(_ line: String) -> String {
        var output = "", escaped = false
        for c in line {
            if escaped {
                switch c {
                case "n": output.append("\n")
                case "\\": output.append("\\")
                default: output.append("\\"); output.append(c)
                }
                escaped = false
            } else if c == "\\" { escaped = true } else { output.append(c) }
        }
        if escaped { output.append("\\") }
        return output
    }
}
