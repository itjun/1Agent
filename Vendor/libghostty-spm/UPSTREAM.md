# libghostty-spm Swift wrapper

Source: https://github.com/Lakr233/libghostty-spm, tag `1.6.20260929`.
Only the package manifest, source/resources, and license are vendored. Build products,
Git metadata, and the binary framework are not included. The binary artifact URL and
SHA-256 checksum in `Package.swift` are unchanged from that release.

1Agent adds `InMemoryTerminalSession.readScreenText(maxRows:maxBytes:)`, a read-only,
bounded returned-text export of the currently active screen. It does not read the inactive
primary screen while an alternate screen is active. The host archives the primary
screen before forwarding an alternate-screen switch, then stores alternate-screen
viewport text separately. Historical text is displayed in an AppKit text view; it is
never replayed as terminal input or output.

SCREEN exports logical text lines: it joins soft wraps even with `rectangle: true`.
VIEWPORT is read one physical row at a time to preserve the last visible grid. A text
history view anchors its scroll position to the matching logical line; it does not
claim to preserve terminal colors, cursor state, or interactive TUI operation.

The upstream test target is omitted because upstream test fixtures are not vendored.
1Agent's archive model, stream-boundary parser, and persistence tests live in `Tests`.

The C API exports its selected screen into a temporary allocation before the wrapper
can bound the result. That allocation follows the engine scrollback limit; enforcing a
separate hard C-allocation cap would require a new binary API. The wrapper never uses
asynchronous scrollbar totals to cut off newer output.

Validation: `bash scripts/test-terminal-history.sh` from the application root runs
isolated model/storage/parser tests and, after the dependencies have been built,
a real Ghostty surface test. The engine test uses an invisible AppKit window with an
in-memory backend; it does not start a shell or SSH process.
