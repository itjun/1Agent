import GhosttyTerminal

/// Kept with the history feature; the existing relay remains the sole engine delegate.
extension TerminalEventRelay: TerminalSurfaceScrollbarDelegate {
    func terminalDidUpdateScrollbar(_ scrollbar: TerminalScrollbar) {
        terminal?.processHost?.historyRecorder?.updateScrollbar(
            total: scrollbar.total, offset: scrollbar.offset, visible: scrollbar.len
        )
    }
}
