# 1Agent (Ghostty) private maintenance notes

This repository is maintained privately by eachann1024. The macOS app is named **Ghostty** with bundle identifier `com.mitchellh.ghostty` and URL scheme `ghostty://`, so on this Mac it replaces the official Ghostty; it installs to `/Applications/Ghostty.app`, and the install script zips the official app to `~/iLearn/backups` before replacing it. Settings from the old `com.itjun.1agent` domain are copied over once at launch. `GooseAgent` remains the Swift module name; the Xcode project/target is still `1Agent`.

## Local build

On macOS with Xcode and XcodeGen installed:

```sh
make build
```

Avoid adding release automation, public update feeds, or upstream marketing assets.
