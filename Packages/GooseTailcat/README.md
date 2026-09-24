# GooseTailcat

`GooseTailcat` is the repository-local Swift package that embeds the
[tailcat](https://github.com/tailscale/tailcat) (WireGuard/DERP) client so the
app reaches a remote gooseagent through the `gooseagent.tailcat` plugin — in-process,
with no helper binary and nothing to install on `PATH`.

The checked-in `Artifacts/Tailcat.xcframework` is the normal build input.
Rebuilding it is a dependency-maintenance operation, not part of ordinary app
or CI builds.

## Layout

- `go/bridge` — the shared transport core: one tailcat session per device,
  re-served on a local Unix socket (API on the listen path, client-protocol on
  the derived `-client` sibling). Consumed by both the gomobile face and the
  standalone CLI (`Tools/gooseagent-tailcat-bridge`).
- `go/tailcatmobile` — the gomobile-bound package. Exports only bindable types
  (`StartBridge(token, listenPath) error`, `StopBridge`, `BridgeError`), which
  gomobile turns into the `Tailcatmobile*` Swift symbols.
- `Sources/GooseTailcat` — the `TailcatBridge` actor over those symbols.
- `Artifacts/Tailcat.xcframework` — gomobile output: `ios-arm64`,
  `ios-arm64_x86_64-simulator`, `macos-arm64_x86_64`. gomobile emits a **static**
  archive per framework, so Xcode links the Go code into the app binary; the
  copied `Tailcat.framework` in the bundle is a codeless stub and is not a
  runtime dependency.

## Rebuild

Requires `go`, plus the `gomobile`/`gobind` version from `go/go.mod` on PATH:

```sh
go install golang.org/x/mobile/cmd/gomobile@v0.0.0-20260908204917-8b95e45f8d3e && gomobile init
sh Scripts/build-xcframework.sh
```

The script runs `gomobile bind -target=ios,iossimulator,macos -trimpath
-ldflags="-s -w -buildid="` from a fixed neutral copy of `go/`, which keeps
local workspace paths out of the archive and makes successive builds
byte-comparable. Stripping roughly halves the framework size; the exported
`Tailcatmobile*` symbols survive because they are cgo exports kept for linking.
