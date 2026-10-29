# libghostty-spm Swift wrapper

Source: https://github.com/Lakr233/libghostty-spm, tag `1.6.20260929`.
The Swift wrapper remains based on that release. The macOS engine is built from
Ghostty `v1.4.0` (`83fb95624b0439ee660c2679b43b38c8b63769cd`) using
`scripts/build-libghostty.sh`. The script checks the source archive SHA-256 and
applies `Patches/ghostty-v1.4.0.patch`; the generated framework is not tracked.
The patch ports libghostty-spm's host-managed I/O, rendering and screen-history
changes to v1.4.0. It is based on the patch stack from libghostty-spm
`2.2.2026102101`, with adaptations for v1.4.0 and Zig 0.17.0.

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

Validation: after `make build`, `make test-terminal-restoration` exercises the
history and restored input on native Ghostty surfaces in isolated test storage.
