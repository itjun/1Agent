import Foundation

@main
enum TerminalHistoryTests {
    static func main() throws {
        try boundsAndPersistence()
        boundariesAcrossChunks()
        print("ok terminal history")
    }

    static func boundsAndPersistence() throws {
        let huge = (0..<22_000).map { "row \($0) 中文" }.joined(separator: "\n")
        let snapshot = TerminalHistorySnapshot(mainText: huge, lastScreenText: "screen\ntext",
            mainViewportTop: 21_990, visibleRows: 24, wasAlternateScreen: false)
        expect(snapshot.mainText.hasSuffix("row 21999 中文"), "newest rows retained")
        expect(snapshot.mainText.split(separator: "\n").count + snapshot.lastScreenText.split(separator: "\n").count <= 20_000,
               "combined row budget")
        expect(snapshot.mainViewportTop < 20_000 && snapshot.mainViewportTop > 19_000, "scroll position adjusted after trimming")
        expect(TerminalHistorySnapshot.viewportRow(in: "a\nb\nc\nd", viewport: "c\nd", preferred: 0) == 2,
               "viewport match corrects a stale scrollbar event")
        expect(TerminalHistorySnapshot.viewportRow(in: "a  \nb  \na  \nb  ", viewport: "a\nb", preferred: 0) == 0,
               "repeated viewport preserves explicit scroll position")
        let bytes = TerminalHistorySnapshot.bound(String(repeating: "中🙂", count: 100), rows: 2, bytes: 17)
        expect(bytes.text.utf8.count <= 17 && !bytes.text.contains("�"), "byte trim stays at UTF-8 boundary")
        expect(TerminalHistorySnapshot.plainText("a\u{1b}\u{07}\u{9b}b\r\nc\t").contains("\u{1b}") == false,
               "archive strips terminal controls")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("1agent-history-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TerminalHistoryStore(directory: root)
        let key = UUID()
        expect(TerminalHistoryStore.key(for: "\(key)#17") == key, "stable identity across reconnect generations")
        expect(TerminalHistoryStore.key(for: "../../arbitrary") == nil, "paths cannot become archive keys")
        store.save(snapshot, for: key)
        flush(store)
        let loaded = load(store, key)
        expect(loaded == snapshot, "atomic archive round trip")
        let mode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(key.uuidString + ".json").path)[.posixPermissions] as? Int
        expect(mode == 0o600, "archive only readable by owner")
        store.remove(key)
        store.save(snapshot, for: key)
        flush(store)
        expect(load(store, key) == nil, "late checkpoint cannot recreate a closed tab archive")
        let corrupt = UUID()
        try Data("not json".utf8).write(to: root.appendingPathComponent(corrupt.uuidString + ".json"))
        expect(load(store, corrupt) == nil, "corrupt archive falls back to new session")
    }

    static func boundariesAcrossChunks() {
        let samples: [(String, [Bool])] = [
            ("before\u{1b}[?1049hTUI\u{1b}[?1049lafter", [true, false]),
            ("\u{1b}[?1;47h\u{1b}[?47h\u{1b}[?47l", [true, false]),
            ("\u{1b}[?001049h\u{1b}[?10\u{07}49l", [true, false]),
            ("\u{1b}]0;title [?1049h\u{07}text", []),
            ("\u{1b}Ppayload\u{07}[?1049h\u{1b}\\normal", []),
            ("\u{1b}]0;title \u{1b}[?1049h\u{07}text", [true]),
            ("\u{1b}Ppayload\u{07}\u{1b}[?1049h\u{1b}\\normal", [true]),
            ("\u{1b}]0;标题 Ü\u{1b}[?1049h\u{1b}\\normal", [true]),
            ("\u{1b}[?1049h\u{1b}c", [true, false]),
            ("\u{1b}[?1049\u{18}h", []),
            ("中文🙂\u{1b}[?1047h\u{1b}[?1047l", [true, false]),
        ]
        for (text, expected) in samples {
            let data = Data(text.utf8)
            // Every split tests a pending ESC/CSI/OSC/DCS/UTF-8 state across reads.
            for split in 0...data.count {
                var parser = TerminalHistoryBoundaryParser()
                let first = parser.scan(data.prefix(split))
                let second = parser.scan(data.suffix(data.count - split))
                expect((first + second).map(\.alternate) == expected, "boundary split \(split) of \(text.debugDescription)")
            }
            var parser = TerminalHistoryBoundaryParser()
            var actual: [Bool] = []
            for byte in data { actual += parser.scan(Data([byte])).map(\.alternate) }
            expect(actual == expected, "one-byte chunks")
        }
        var parser = TerminalHistoryBoundaryParser()
        let input = Data("hello\u{1b}[?1049hworld".utf8)
        let transition = parser.scan(input).first!
        expect(input[transition.offset] == Character("h").asciiValue, "capture before final mode byte")
        var unicode = TerminalHistoryBoundaryParser()
        // U+009B encoded as UTF-8 is not a standalone 8-bit CSI.
        expect(unicode.scan(Data("\u{009b}?1049h".utf8)).isEmpty, "UTF-8 continuation byte is not a CSI")
    }

    static func flush(_ store: TerminalHistoryStore) {
        let done = DispatchSemaphore(value: 0)
        store.flush { done.signal() }
        expect(done.wait(timeout: .now() + 5) == .success, "disk queue flushed")
    }

    static func load(_ store: TerminalHistoryStore, _ key: UUID) -> TerminalHistorySnapshot? {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        store.load(key) { box.value = $0; done.signal() }
        expect(done.wait(timeout: .now() + 5) == .success, "disk queue read")
        return box.value
    }

    final class ResultBox: @unchecked Sendable { var value: TerminalHistorySnapshot? }
    static func expect(_ value: Bool, _ reason: String) {
        if !value { fputs("FAIL: \(reason)\n", stderr); exit(1) }
    }
}
