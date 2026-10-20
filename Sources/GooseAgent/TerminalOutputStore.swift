import Darwin
import Foundation

/// Private, bounded display text. Never archive/replay raw PTY bytes: they can
/// contain clipboard operations, terminal queries or other side effects.
/// SGR color/style sequences (`ESC [ … m`) are the only escapes kept.
struct TerminalOutputStore {
    static let shared = TerminalOutputStore()
    static let byteLimit = 8 * 1024 * 1024
    static let lineLimit = 20_000
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.itjun.1agent/terminal-output", isDirectory: true)
    }

    private func url(for id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".txt") }

    func load(_ id: UUID) -> String? {
        let url = url(for: id)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= Self.byteLimit,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.byteLimit + 1), data.count <= Self.byteLimit,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return Self.displayText(text)
    }

    func save(_ text: String, for id: UUID) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".output-" + UUID().uuidString)
        defer { try? manager.removeItem(at: temporary) }
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: Data(Self.displayText(text).utf8))
            try handle.synchronize()
            try handle.close()
        } catch { try? handle.close(); throw error }
        guard rename(temporary.path, url(for: id).path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    /// Unmounted restored tabs keep their existing archive. Remove only logs
    /// belonging to terminals that are no longer in the saved session.
    func prune(keeping ids: Set<UUID>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "txt" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !ids.contains(id) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func displayText(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let scalars = Array(normalized.unicodeScalars)
        var kept = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let value = scalars[index].value
            if value == 0x1B {
                index = advancePastEscape(in: scalars, at: index, keepingSGRIn: &kept)
                continue
            }
            if value == 9 || value == 10 || (value >= 32 && !((127...159).contains(value))) {
                kept.append(scalars[index])
            }
            index += 1
        }
        let safe = String(kept)
        // Trim only empty viewport rows, keeping whitespace within log lines.
        var trimmed = safe
        while trimmed.last == "\n" { trimmed.removeLast() }
        let bytes = Array(trimmed.utf8)
        var start = max(0, bytes.count - byteLimit)
        while start < bytes.count, bytes[start] & 0xC0 == 0x80 { start += 1 }
        var lines = 1
        var cursor = bytes.count
        while cursor > start {
            cursor -= 1
            if bytes[cursor] == 10 {
                if lines == lineLimit { start = cursor + 1; break }
                lines += 1
            }
        }
        return String(decoding: bytes[start...], as: UTF8.self)
    }

    /// Returns the index after the escape sequence starting at `start`. Appends SGR
    /// sequences to `kept`; strings (OSC, DCS, APC…) and other CSI are dropped with their payload.
    private static func advancePastEscape(in scalars: [Unicode.Scalar], at start: Int, keepingSGRIn kept: inout String.UnicodeScalarView) -> Int {
        var index = start + 1
        guard index < scalars.count else { return index }
        let introducer = scalars[index].value
        index += 1
        if introducer == 0x5B {
            var isStyle = true
            while index < scalars.count, (0x20...0x3F).contains(scalars[index].value) {
                let value = scalars[index].value
                let isDigit = (0x30...0x39).contains(value)
                if !isDigit && value != 0x3B && value != 0x3A { isStyle = false }
                index += 1
            }
            guard index < scalars.count else { return index }
            if isStyle && scalars[index] == "m" {
                kept.append(contentsOf: scalars[start...index])
            }
            return index + 1
        }
        if [0x5D, 0x50, 0x58, 0x5E, 0x5F].contains(introducer) {
            while index < scalars.count {
                if scalars[index].value == 0x07 { return index + 1 }
                if scalars[index].value == 0x1B, index + 1 < scalars.count, scalars[index + 1] == "\\" { return index + 2 }
                index += 1
            }
            return index
        }
        while index < scalars.count, (0x20...0x2F).contains(scalars[index - 1].value) {
            index += 1
        }
        return index
    }
}
