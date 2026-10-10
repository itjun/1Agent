# 1Agent

Private macOS app that opens SSH sessions from your `~/.ssh/config`.

The sidebar is a vertical list of open tabs. ⌘T opens a new tab where you pick a `Host` from `~/.ssh/config` (including `Include`). Choosing one runs `/usr/bin/ssh -tt -- <alias>`, so ProxyJump, keys, and the rest of the config stay with OpenSSH. The remote shell is started with `TERM=xterm-256color`.

## Local build

Requires macOS, Xcode, and XcodeGen:

```sh
make build
```

The app is named **1Agent** and uses bundle identifier `com.itjun.1agent` with URL scheme `oneagent://`. `make build` installs it to `/Applications/1Agent.app`. Official Ghostty keeps its own bundle id and `ghostty://`. The Swift module is still `GooseAgent`.
