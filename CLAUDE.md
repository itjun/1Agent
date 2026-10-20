# 1Agent private maintenance notes

This repository is maintained privately by eachann1024. The macOS app is named **1Agent** with bundle identifier `com.itjun.1agent` and URL scheme `oneagent://`. It installs to `/Applications/1Agent.app` and leaves official Ghostty (`com.mitchellh.ghostty`, `ghostty://`) in place. If `/Applications/Ghostty.app` is a previous build of this app, the install script removes it and restores the official app from `~/iLearn/backups` when that zip exists. Settings saved while this app used the Ghostty bundle id are copied back into `com.itjun.1agent` once at launch. `GooseAgent` remains the Swift module name; the Xcode project/target is still `1Agent`.

## Local build

On macOS with Xcode and XcodeGen installed:

```sh
make build
```

Avoid adding release automation, public update feeds, or upstream marketing assets.
