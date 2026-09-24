# Goose Agent

Private macOS workspace for Goose Agent, a native terminal UI for local and remote coding-agent sessions.

## Local build

Requires macOS, Xcode, and XcodeGen. Generate the project and build a debug app with:

```sh
make build
```

The app uses bundle identifier `dev.eachann.gooseagent`; the Finder-visible app name is **Goose Agent**.

## Sidebar

In Priority sessions, New Space appears before New Terminal. Available agents enabled in Settings appear directly below New Terminal in the configured order; choosing one opens it in the current space or asks for a space when none is selected. The sidebar scrolls with the session list when these shortcuts exceed the window height.
