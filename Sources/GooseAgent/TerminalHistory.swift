import Foundation

/// Plain rendered text only. Never store PTY bytes, terminal modes, or executable input.
struct TerminalHistorySnapshot: Codable, Equatable, Sendable {
    static let version = 1
    static let lineLimit = 20_000
    static let byteLimit = 8 * 1024 * 1024
    var version = Self.version
    var capturedAt: Date
    var mainText: String
    var lastScreenText: String
    var mainViewportTop: Int
    var visibleRows: Int
    var wasAlternateScreen: Bool

    init(mainText: String, lastScreenText: String, mainViewportTop: Int,
         visibleRows: Int, wasAlternateScreen: Bool, capturedAt: Date = Date()) {
        let screen = Self.bound(lastScreenText, rows: min(Self.lineLimit, max(1, visibleRows)), bytes: Self.byteLimit / 4)
        let main = Self.bound(mainText, rows: Self.lineLimit - screen.lineCount,
                              bytes: Self.byteLimit - screen.text.utf8.count)
        self.capturedAt = capturedAt
        self.mainText = main.text
        self.lastScreenText = screen.text
        self.mainViewportTop = min(max(0, mainViewportTop - main.droppedRows), max(0, main.lineCount - 1))
        self.visibleRows = min(Self.lineLimit, max(1, visibleRows))
        self.wasAlternateScreen = wasAlternateScreen
    }

    var isEmpty: Bool { mainText.isEmpty && lastScreenText.isEmpty }

    /// Match the actual rendered viewport when an asynchronous scrollbar callback is
    /// behind a burst of output. Prefer its reported row when repeated content matches.
    static func viewportRow(in main: String, viewport: String, preferred: Int) -> Int {
        func rows(_ text: String) -> [String] {
            text.split(separator: "\n", omittingEmptySubsequences: false).map { row in
                var end = row.endIndex
                while end > row.startIndex, row[row.index(before: end)] == " " { end = row.index(before: end) }
                return String(row[..<end])
            }
        }
        let haystack = rows(main), needle = rows(viewport)
        guard !needle.isEmpty, haystack.count >= needle.count else { return max(0, preferred) }
        func matches(_ index: Int) -> Bool {
            index >= 0 && index + needle.count <= haystack.count
                && haystack[index..<(index + needle.count)].elementsEqual(needle)
        }
        if matches(preferred) { return preferred }
        for index in stride(from: haystack.count - needle.count, through: 0, by: -1) {
            if matches(index) { return index }
        }
        // SCREEN exports logical lines, while VIEWPORT preserves physical soft wraps.
        // Anchor a wrapped viewport to its containing logical line for text-history
        // navigation; the separate Last Screen retains the exact physical layout.
        if let fragment = needle.first(where: { !$0.isEmpty }) {
            if preferred >= 0, preferred < haystack.count, haystack[preferred].contains(fragment) { return preferred }
            if let index = haystack.lastIndex(where: { $0.contains(fragment) }) { return index }
        }
        return min(max(0, preferred), max(0, haystack.count - needle.count))
    }

    /// Terminal readback is already text; strip all remaining control scalars except TAB/LF
    /// as defense in depth. Even a corrupted archive can only reach a read-only NSTextView.
    static func plainText(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return String(String.UnicodeScalarView(normalized.unicodeScalars.filter {
            $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0)
        }))
    }

    struct Bounded {
        var text: String
        var droppedRows: Int
        var lineCount: Int
    }

    static func bound(_ value: String, rows: Int, bytes: Int) -> Bounded {
        guard rows > 0, bytes > 0 else {
            return Bounded(text: "", droppedRows: value.filter { $0 == "\n" }.count, lineCount: 0)
        }
        let clean = plainText(value)
        guard !clean.isEmpty else { return Bounded(text: "", droppedRows: 0, lineCount: 0) }
        let lines = clean.split(separator: "\n", omittingEmptySubsequences: false)
        var dropped = max(0, lines.count - rows)
        var result = lines.suffix(rows).joined(separator: "\n")
        if result.utf8.count > bytes {
            let data = Array(result.utf8.suffix(bytes))
            var start = 0
            while start < data.count, data[start] & 0xC0 == 0x80 { start += 1 }
            let suffix = String(decoding: data[start...], as: UTF8.self)
            dropped += result.filter { $0 == "\n" }.count - suffix.filter { $0 == "\n" }.count
            result = suffix
        }
        return Bounded(text: result, droppedRows: dropped,
                       lineCount: result.isEmpty ? 0 : result.filter { $0 == "\n" }.count + 1)
    }

    /// Revalidate on load: Codable alone must not bypass the size/row/control limits.
    var validated: Self? {
        guard version == Self.version else { return nil }
        return Self(mainText: mainText, lastScreenText: lastScreenText,
                    mainViewportTop: mainViewportTop, visibleRows: visibleRows,
                    wasAlternateScreen: wasAlternateScreen, capturedAt: capturedAt)
    }
}

/// Detect only screen switches. This is not a text/VT parser and never interprets saved
/// history. Literal OSC/DCS/APC/PM/SOS payloads and UTF-8 continuation bytes cannot
/// create spurious switches. An ESC inside a string starts a new escape sequence,
/// matching Ghostty (including non-ST sequences). Offsets point to the final mode byte so the
/// host can archive the previous rendered screen before that byte reaches the engine.
struct TerminalHistoryBoundaryParser {
    struct Transition: Equatable { var offset: Int; var alternate: Bool }
    private enum State { case ground, escape, csi, string, stringEscape }
    private var state: State = .ground
    private var csi: [UInt8] = []
    private var utf8Remaining = 0
    private var stringUTF8Remaining = 0
    private var stringAllowsBEL = false
    private(set) var alternate = false

    mutating func scan(_ data: Data) -> [Transition] {
        var changes: [Transition] = []
        for (offset, byte) in data.enumerated() {
            switch state {
            case .ground:
                if utf8Remaining > 0, byte & 0xC0 == 0x80 { utf8Remaining -= 1; continue }
                utf8Remaining = 0
                if byte >= 0xC2 && byte <= 0xDF { utf8Remaining = 1 }
                else if byte >= 0xE0 && byte <= 0xEF { utf8Remaining = 2 }
                else if byte >= 0xF0 && byte <= 0xF4 { utf8Remaining = 3 }
                else if byte == 0x1B { state = .escape }
                else if byte == 0x9B { csi = []; state = .csi }
                else if [0x90, 0x98, 0x9D, 0x9E, 0x9F].contains(byte) {
                    stringAllowsBEL = byte == 0x9D; stringUTF8Remaining = 0; state = .string
                }
            case .escape:
                if byte == 0x5B { csi = []; state = .csi }
                else if [0x50, 0x58, 0x5D, 0x5E, 0x5F].contains(byte) {
                    stringAllowsBEL = byte == 0x5D; stringUTF8Remaining = 0; state = .string
                }
                else if byte == 0x1B { state = .escape }
                else {
                    if byte == 0x63, alternate {
                        alternate = false
                        changes.append(Transition(offset: offset, alternate: false))
                    }
                    state = .ground
                }
            case .csi:
                if byte == 0x1B { state = .escape; csi = [] }
                else if byte == 0x18 || byte == 0x1A { state = .ground; csi = [] }
                // VT executes embedded C0 controls without consuming CSI parameters.
                else if byte < 0x20 || byte == 0x7F { continue }
                else if byte >= 0x40 && byte <= 0x7E {
                    if (byte == 0x68 || byte == 0x6C), csi.first == 0x3F {
                        let parameters = String(decoding: csi.dropFirst(), as: UTF8.self).split(separator: ";")
                        if parameters.contains(where: {
                            $0.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
                                && [47, 1047, 1049].contains(Int($0) ?? -1)
                        }) {
                            let next = byte == 0x68
                            if next != alternate {
                                alternate = next
                                changes.append(Transition(offset: offset, alternate: next))
                            }
                        }
                    }
                    state = .ground; csi = []
                } else if csi.count < 128 { csi.append(byte) }
                else { csi = []; state = .ground }
            case .string:
                if stringUTF8Remaining > 0, byte & 0xC0 == 0x80 { stringUTF8Remaining -= 1; continue }
                stringUTF8Remaining = 0
                if byte >= 0xC2 && byte <= 0xDF { stringUTF8Remaining = 1 }
                else if byte >= 0xE0 && byte <= 0xEF { stringUTF8Remaining = 2 }
                else if byte >= 0xF0 && byte <= 0xF4 { stringUTF8Remaining = 3 }
                else if byte == 0x1B { state = .stringEscape }
                else if (byte == 0x07 && stringAllowsBEL) || byte == 0x9C || byte == 0x18 || byte == 0x1A { state = .ground }
            case .stringEscape:
                if byte == 0x5C || byte == 0x18 || byte == 0x1A { state = .ground }
                else if byte == 0x5B { csi = []; state = .csi }
                else if [0x50, 0x58, 0x5D, 0x5E, 0x5F].contains(byte) {
                    stringAllowsBEL = byte == 0x5D; stringUTF8Remaining = 0; state = .string
                } else if byte == 0x1B { state = .escape }
                else {
                    if byte == 0x63, alternate {
                        alternate = false
                        changes.append(Transition(offset: offset, alternate: false))
                    }
                    state = .ground
                }
            }
        }
        return changes
    }
}

/// All disk IO is serialized off the main thread, with atomic 0600 files in an app-owned
/// 0700 directory. UUID keys prevent terminal names or remote paths from becoming paths.
final class TerminalHistoryStore: @unchecked Sendable {
    static let shared = TerminalHistoryStore(directory: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("1Agent/TerminalHistory", isDirectory: true))
    let directory: URL
    private let queue = DispatchQueue(label: "com.itjun.1agent.terminal-history.disk", qos: .utility)
    private var removed: Set<UUID> = []

    init(directory: URL) { self.directory = directory }

    static func key(for sessionID: String) -> UUID? {
        UUID(uuidString: String(sessionID.split(separator: "#", maxSplits: 1).first ?? ""))
    }

    func load(_ key: UUID, completion: @escaping @Sendable (TerminalHistorySnapshot?) -> Void) {
        queue.async { [self] in
            let url = path(key)
            guard !removed.contains(key),
                  let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                  size <= TerminalHistorySnapshot.byteLimit * 3,
                  let data = try? Data(contentsOf: url),
                  let snapshot = try? JSONDecoder().decode(TerminalHistorySnapshot.self, from: data) else {
                completion(nil); return
            }
            completion(snapshot.validated)
        }
    }

    func save(_ snapshot: TerminalHistorySnapshot, for key: UUID) {
        queue.async { [self] in
            guard !removed.contains(key), !snapshot.isEmpty, let valid = snapshot.validated else { return }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700])
                let data = try JSONEncoder().encode(valid)
                try data.write(to: path(key), options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path(key).path)
            } catch {
                // A failed atomic replacement leaves the last valid archive intact.
                NSLog("1Agent terminal history could not be saved: %@", error.localizedDescription)
            }
        }
    }

    func remove(_ key: UUID) {
        queue.async { [self] in
            removed.insert(key)
            try? FileManager.default.removeItem(at: path(key))
        }
    }

    func flush(completion: @escaping @Sendable () -> Void) { queue.async(execute: completion) }
    private func path(_ key: UUID) -> URL { directory.appendingPathComponent(key.uuidString + ".json") }
}
