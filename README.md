# Goose Agent

Private macOS app that opens SSH sessions from your `~/.ssh/config`.

The sidebar is a vertical list of open tabs. ⌘T opens a new tab where you pick a `Host` from `~/.ssh/config` (including `Include`). Choosing one runs `/usr/bin/ssh -tt -- <alias>`, so ProxyJump, keys, and the rest of the config stay with OpenSSH. The remote shell is started with `TERM=xterm-256color`.

## Local build

Requires macOS, Xcode, and XcodeGen:

```sh
make build
```

The app uses bundle identifier `dev.eachann.gooseagent`; the Finder-visible app name is **Goose Agent**.
