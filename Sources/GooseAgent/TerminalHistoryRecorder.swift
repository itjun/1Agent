import Foundation
import GhosttyTerminal

/// Serializes received output, screen-boundary captures and periodic captures. The PTY
/// callback only enqueues; parsing, readback and disk serialization stay off the main queue.
final class TerminalHistoryRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.itjun.1agent.terminal-history.capture", qos: .utility)
    private let geometryLock = NSLock()
    private let key: UUID
    private let session: InMemoryTerminalSession
    private var parser = TerminalHistoryBoundaryParser()
    private var alternate = false
    private var mainText = ""
    private var mainFirstRow: UInt64 = 0
    private var restoredPrefix = ""
    private var total: UInt64 = 0
    private var offset: UInt64 = 0
    private var visible: UInt64 = 24
    private var cancelled = false
    private var dirty = false
    private var lastCapture = Date.distantPast

    init(key: UUID, session: InMemoryTerminalSession) { self.key = key; self.session = session }

    func prepare(completion: @escaping @Sendable (TerminalHistorySnapshot?) -> Void) {
        TerminalHistoryStore.shared.load(key) { [weak self] snapshot in
            guard let self else { completion(nil); return }
            self.queue.async {
                self.restoredPrefix = snapshot?.mainText ?? ""
                completion(snapshot)
            }
        }
    }

    func updateScrollbar(total: UInt64, offset: UInt64, visible: UInt64) {
        geometryLock.lock()
        self.total = total; self.offset = offset; self.visible = max(1, visible)
        geometryLock.unlock()
        queue.async { [weak self] in self?.dirty = true }
    }

    func receive(_ data: Data) {
        queue.async { [self] in
            guard !cancelled else { return }
            let changes = parser.scan(data)
            var start = 0
            for change in changes {
                if change.offset > start { session.receive(data.subdata(in: start..<change.offset)) }
                session.waitForPendingOutput()
                if !alternate { captureMain() }
                else if !change.alternate { capture(force: true) }
                // The final h/l byte has not yet reached Ghostty: the read above still sees
                // the old screen, including when ESC/CSI arrived in a previous PTY chunk.
                session.receive(data.subdata(in: change.offset..<(change.offset + 1)))
                alternate = change.alternate
                start = change.offset + 1
            }
            if start < data.count { session.receive(data.subdata(in: start..<data.count)) }
            dirty = true
        }
    }

    func checkpoint(force: Bool = false, completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            if !cancelled { capture(force: force) }
            completion?()
        }
    }

    func cancel(removeArchive: Bool) {
        queue.async { [self] in
            cancelled = true
            if removeArchive { TerminalHistoryStore.shared.remove(key) }
        }
    }

    private func geometry() -> (total: UInt64, offset: UInt64, visible: UInt64) {
        geometryLock.lock(); defer { geometryLock.unlock() }
        return (total, offset, visible)
    }

    private func captureMain() {
        if let read = session.readScreenText(maxRows: TerminalHistorySnapshot.lineLimit,
                                             maxBytes: TerminalHistorySnapshot.byteLimit) {
            mainText = read.text
            mainFirstRow = read.firstRow
        }
    }

    private func capture(force: Bool) {
        guard session.hasAttachedSurface, force || (dirty && Date().timeIntervalSince(lastCapture) >= 10) else { return }
        session.waitForPendingOutput()
        if !alternate { captureMain() }
        let metrics = geometry()
        guard let screen = session.readViewportText() else { return }
        let divider = restoredPrefix.isEmpty || mainText.isEmpty ? "" : "\n\n— · —\n\n"
        let prefix = restoredPrefix + divider
        let prefixRows = prefix.isEmpty ? 0 : prefix.filter { $0 == "\n" }.count
        let first = min(metrics.offset, mainFirstRow)
        let rawOffset = Int(metrics.offset - first)
        let viewportTop = alternate ? rawOffset : TerminalHistorySnapshot.viewportRow(
            in: mainText, viewport: screen, preferred: rawOffset
        )
        let snapshot = TerminalHistorySnapshot(
            mainText: prefix + mainText, lastScreenText: screen,
            mainViewportTop: prefixRows + viewportTop,
            visibleRows: Int(metrics.visible), wasAlternateScreen: alternate
        )
        TerminalHistoryStore.shared.save(snapshot, for: key)
        lastCapture = Date(); dirty = false
    }
}
