# 1Agent

Private macOS app that opens SSH sessions from your `~/.ssh/config`.

The sidebar is a vertical list of open tabs. ⌘T opens a new tab where you pick a `Host` from `~/.ssh/config` (including `Include`). Choosing one runs `/usr/bin/ssh -tt -- <alias>`, so ProxyJump, keys, and the rest of the config stay with OpenSSH. The remote shell is started with `TERM=xterm-256color`.

## Local build

Requires macOS, Xcode, and XcodeGen:

```sh
make build
```

The app is named **Ghostty** and uses bundle identifier `com.mitchellh.ghostty` with URL scheme `ghostty://`, replacing the official Ghostty on this Mac. `make build` installs it to `/Applications/Ghostty.app`; the official app is zipped to `~/iLearn/backups` first. Settings from the old `com.itjun.1agent` domain are copied once on first launch. The Swift module is still `GooseAgent`.
