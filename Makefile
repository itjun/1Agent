.PHONY: gen build install run test test-appearance test-terminal-restoration test-quick-command-drop test-sidebar-groups test-app-icons generate-app-icons clean
.PHONY: test-command-transparency
.PHONY: test-modal-appearance
.PHONY: test-system-integration
.PHONY: test-terminal-windows test-scripting-replies
.PHONY: test-terminal-automation
.PHONY: test-terminal-compatibility test-terminal-stress
.PHONY: test-app-update-controller
.PHONY: test-app-update-restart
.PHONY: prepare-libghostty
.PHONY: test-release-signing

test-release-signing:
	python3 scripts/test-release-signing.py

test-terminal-automation:
	python3 scripts/test-terminal-automation.py

test-terminal-compatibility:
	bash scripts/test-terminal-windows.sh "" --compatibility
	ONEAGENT_COMPATIBILITY_NO_FEATURES=1 bash scripts/test-terminal-windows.sh "" --shell-compatibility

test-terminal-stress:
	bash scripts/test-terminal-windows.sh "" --stress-compatibility

test-terminal-windows:
	bash scripts/test-terminal-windows.sh

.PHONY: test-command-drag
test-command-drag:
	bash scripts/test-terminal-windows.sh "" --command-drag

test-scripting-replies:
	clang -fobjc-arc -framework Foundation -I Sources/OneAgent Sources/OneAgent/ScriptingReplyBridge.m Tests/ScriptingReplyBridgeTests.m -o /tmp/oneagent-scripting-reply-tests
	/tmp/oneagent-scripting-reply-tests

test-system-integration:
	swiftc -parse-as-library Sources/OneAgent/TerminalAssociations.swift Tests/TerminalAssociationsTests.swift -o /tmp/oneagent-system-integration-tests
	/tmp/oneagent-system-integration-tests

test-command-transparency:
	python3 scripts/test-command-transparency.py

# Command Line Tools cannot run xcodebuild. Prefer the full Xcode.app when that is the case.
ifeq ($(shell xcode-select -p 2>/dev/null),/Library/Developer/CommandLineTools)
  export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
endif

CODE_SIGN_IDENTITY ?= -
APP_BUNDLE = 1Agent.app
# ".noindex" keeps Spotlight/LaunchServices from listing the build copy next to /Applications.
DERIVED_DATA = build/DerivedData.noindex
APP_BUILT = $(DERIVED_DATA)/Build/Products/Debug/$(APP_BUNDLE)

gen:
	xcodegen generate

generate-app-icons:
	node scripts/generate-app-icons.mjs

test-app-icons:
	bash scripts/test-app-icons.sh

test-app-update-controller:
	bash scripts/test-app-update-controller.sh

test-app-update-restart:
	bash scripts/test-app-update-restart.sh

# Compile, then install into /Applications (quit → replace → relaunch if needed).
build: gen
	./scripts/build-libghostty.sh
	set -o pipefail; xcodebuild -project 1Agent.xcodeproj -scheme 1Agent -configuration Debug -derivedDataPath $(DERIVED_DATA) -clonedSourcePackagesDirPath build/SourcePackages build CODE_SIGN_IDENTITY="$(CODE_SIGN_IDENTITY)" CODE_SIGN_STYLE=Manual -skipPackagePluginValidation | tee /tmp/1agent-build.log | tail -8
	if [ "$(CODE_SIGN_IDENTITY)" = "-" ]; then ./scripts/local-codesign.sh "$(CURDIR)/$(APP_BUILT)"; fi
	./scripts/install-app.sh "$(CURDIR)/$(APP_BUILT)"

prepare-libghostty:
	./scripts/build-libghostty.sh

install:
	./scripts/install-app.sh "$(CURDIR)/$(APP_BUILT)"

run: build
	open "/Applications/$(APP_BUNDLE)"

test: test-release-signing test-ssh-configuration test-command-transparency test-system-integration test-scripting-replies
	swiftc -O -parse-as-library -o /tmp/oneagent-terminal-output-store-tests Sources/OneAgent/TerminalOutputStore.swift Tests/TerminalOutputStoreTests.swift
	/tmp/oneagent-terminal-output-store-tests
	swiftc -parse-as-library -o /tmp/oneagent-remote-bridge-tests Sources/OneAgent/QuickCommand.swift Sources/OneAgent/CommandBridgeSocket.swift Sources/OneAgent/RemoteCommandBridge.swift Sources/OneAgent/TerminalSessionConnection.swift Tests/RemoteCommandBridgeTests.swift
	/tmp/oneagent-remote-bridge-tests
	swiftc -parse-as-library -o /tmp/oneagent-local-bridge-tests Sources/OneAgent/QuickCommand.swift Sources/OneAgent/CommandBridgeSocket.swift Sources/OneAgent/LocalCommandBridge.swift Sources/OneAgent/TerminalSessionConnection.swift Tests/LocalCommandBridgeTests.swift
	/tmp/oneagent-local-bridge-tests
	swiftc -o /tmp/oneagent-remote-shell-tests Sources/OneAgent/RemoteShellIntegration.swift Tests/RemoteShellIntegrationTests.swift
	/tmp/oneagent-remote-shell-tests
	python3 scripts/test-remote-shell-cleanup.py
	swiftc -parse-as-library -o /tmp/oneagent-remote-palette-tests Sources/OneAgent/ApplicationIcon.swift Sources/OneAgent/Theme.swift Tests/RemotePaletteTests.swift
	/tmp/oneagent-remote-palette-tests
	swiftc -parse-as-library -o /tmp/oneagent-app-update-tests Sources/OneAgent/AppUpdate.swift Tests/AppUpdateTests.swift
	/tmp/oneagent-app-update-tests
	ONEAGENT_REMOTE_INTEGRATION_TEST=1 python3 scripts/test-quick-command-bridge.py
	swiftc -parse-as-library -o /tmp/oneagent-quick-command-tests Sources/OneAgent/QuickCommand.swift Sources/OneAgent/QuickCommandTransfer.swift Sources/OneAgent/QuickCommandStore.swift Sources/OneAgent/QuickCommandHistory.swift Sources/OneAgent/WorkspacePresentation.swift Tests/QuickCommandTests.swift
	/tmp/oneagent-quick-command-tests
	python3 scripts/test-quick-command-bridge.py
	python3 scripts/test-quick-command-startup.py
	swiftc -parse-as-library -o /tmp/oneagent-command-literal-editor-test Sources/OneAgent/CommandLiteralEditor.swift Tests/CommandLiteralEditorTests.swift
	/tmp/oneagent-command-literal-editor-test
	swiftc -parse-as-library -o /tmp/oneagent-family-dialog-tests Sources/OneAgent/Theme.swift Sources/OneAgent/ApplicationIcon.swift Sources/OneAgent/FocusRing.swift Sources/OneAgent/SheetLayout.swift Sources/OneAgent/FamilyModal.swift Sources/OneAgent/FamilyAlert.swift Tests/FamilyDialogTests.swift
	/tmp/oneagent-family-dialog-tests
	swiftc -parse-as-library -o /tmp/oneagent-family-menu-test Sources/OneAgent/Theme.swift Sources/OneAgent/ApplicationIcon.swift Sources/OneAgent/FamilyMenu.swift Tests/FamilyMenuTests.swift
	/tmp/oneagent-family-menu-test
	bash scripts/test-preview-syntax.sh
	swiftc -parse-as-library -o /tmp/oneagent-pinned-locations-test Sources/OneAgent/Files/PinnedLocations.swift Tests/PinnedLocationsTests.swift
	/tmp/oneagent-pinned-locations-test
	swiftc -o /tmp/oneagent-workspace-presentation-test Sources/OneAgent/WorkspacePresentation.swift Sources/OneAgent/PaneLayout.swift Sources/OneAgent/WorkspaceBoard.swift Tests/WorkspacePresentationTests.swift
	/tmp/oneagent-workspace-presentation-test
	swiftc -o /tmp/oneagent-native-sidebar-test Sources/OneAgent/NativeSidebarSplit.swift Sources/OneAgent/WorkspacePresentation.swift Tests/NativeSidebarSplitTests.swift
	/tmp/oneagent-native-sidebar-test
	swiftc -o /tmp/oneagent-ssh-config-test Sources/OneAgent/SSHConfig.swift Tests/SSHConfigTests.swift
	/tmp/oneagent-ssh-config-test
	swiftc -framework AppKit -o /tmp/oneagent-external-open-test Sources/OneAgent/PaneLayout.swift Sources/OneAgent/WorkspaceBoard.swift Sources/OneAgent/ExternalOpen.swift Tests/ExternalOpenTests.swift
	/tmp/oneagent-external-open-test
	swiftc -o /tmp/oneagent-pane-layout-test Sources/OneAgent/PaneLayout.swift Sources/OneAgent/WorkspaceBoard.swift Tests/PaneLayoutTests.swift
	/tmp/oneagent-pane-layout-test
	swiftc -o /tmp/oneagent-workspace-board-test Sources/OneAgent/PaneLayout.swift Sources/OneAgent/WorkspaceBoard.swift Tests/WorkspaceBoardTests.swift
	/tmp/oneagent-workspace-board-test
	swiftc -o /tmp/oneagent-main-window-frame-test Sources/OneAgent/MainWindowFrame.swift Tests/MainWindowFrameTests.swift
	/tmp/oneagent-main-window-frame-test
	swiftc -o /tmp/oneagent-terminal-settings-test Sources/OneAgent/TerminalSettings.swift Tests/TerminalSettingsTests.swift
	/tmp/oneagent-terminal-settings-test
	swiftc -o /tmp/oneagent-command-finished-policy-test Sources/OneAgent/TerminalSettings.swift Sources/OneAgent/CommandFinishedPolicy.swift Tests/CommandFinishedPolicyTests.swift
	/tmp/oneagent-command-finished-policy-test
	swiftc -o /tmp/oneagent-shell-escape-test Sources/OneAgent/ShellEscape.swift Tests/ShellEscapeTests.swift
	/tmp/oneagent-shell-escape-test
	swiftc -o /tmp/oneagent-shell-integration-test Sources/OneAgent/TerminalSettings.swift Sources/OneAgent/ShellIntegration.swift Tests/ShellIntegrationTests.swift
	/tmp/oneagent-shell-integration-test
	swiftc -o /tmp/oneagent-ghostty-config-importer-test Sources/OneAgent/TerminalSettings.swift Sources/OneAgent/GhosttyConfigImporter.swift Tests/GhosttyConfigImporterTests.swift
	/tmp/oneagent-ghostty-config-importer-test
	swiftc -o /tmp/oneagent-keyboard-shortcuts-test Sources/OneAgent/KeyboardShortcuts.swift Tests/KeyboardShortcutsTests.swift
	/tmp/oneagent-keyboard-shortcuts-test
	swiftc -o /tmp/oneagent-drop-zone-layout-test Sources/OneAgent/DropZoneLayout.swift Tests/DropZoneLayoutTests.swift
	/tmp/oneagent-drop-zone-layout-test
	swiftc -o /tmp/oneagent-file-rules-test Sources/OneAgent/Files/FileRules.swift Tests/FileRulesTests.swift
	/tmp/oneagent-file-rules-test
	swiftc -o /tmp/oneagent-text-file-test Sources/OneAgent/Files/TextFile.swift Tests/TextFileTests.swift
	/tmp/oneagent-text-file-test
	swiftc -o /tmp/oneagent-ssh-launch-test Sources/OneAgent/SSHLaunch.swift Tests/SSHLaunchTests.swift
	/tmp/oneagent-ssh-launch-test
	./scripts/test-file-safety.sh
	bash scripts/test-upload-check.sh

# Uses the production Debug module. Run make build first.
test-modal-appearance:
	bash scripts/test-modal-appearance.sh

.PHONY: test-terminal-font
test-terminal-font:
	bash scripts/test-terminal-font.sh

test-appearance:
	bash scripts/test-family-appearance.sh

.PHONY: test-sidebar-appearance
test-sidebar-appearance:
	bash scripts/test-sidebar-appearance.sh

# Uses the production Debug module and isolated native terminal surfaces. Run make build first.
test-terminal-restoration:
	bash scripts/test-terminal-restoration.sh

# Uses the production Debug module with isolated preferences and no shell/network access.
test-quick-command-drop:
	bash scripts/test-quick-command-drop.sh

.PHONY: test-quick-command-sidebar
test-quick-command-sidebar:
	bash scripts/test-quick-command-sidebar.sh

.PHONY: test-command-sidebar-restoration
test-command-sidebar-restoration:
	bash scripts/test-command-sidebar-restoration.sh

# Production model and persisted sidebar grouping, using isolated storage and no SSH/shells.
test-sidebar-groups:
	bash scripts/test-sidebar-groups.sh

.PHONY: test-sidebar-panel-drop
test-sidebar-panel-drop:
	bash scripts/test-sidebar-panel-drop.sh

.PHONY: test-terminal-pane-drag
test-terminal-pane-drag:
	bash scripts/test-terminal-pane-drag.sh

.PHONY: test-close-terminal-shortcut
test-close-terminal-shortcut:
	bash scripts/test-close-terminal-shortcut.sh

clean:
	rm -rf build 1Agent.xcodeproj

# Production transport replay with isolated preferences and no SSH/network access.
test-remote-directory:
	bash scripts/test-remote-directory.sh

# Production host information presentation, isolated from user sessions.
.PHONY: test-host-information
test-host-information:
	bash scripts/test-host-information.sh

.PHONY: test-ssh-configuration
test-ssh-configuration:
	swiftc -parse-as-library Sources/OneAgent/SSHConfigurationResolver.swift Tests/SSHConfigurationResolverTests.swift -o /tmp/oneagent-ssh-resolution-tests
	/tmp/oneagent-ssh-resolution-tests

# Production reconnect model and network recovery, isolated from user sessions.
.PHONY: test-terminal-reconnect
test-terminal-reconnect:
	bash scripts/test-terminal-reconnect.sh

.PHONY: test-terminal-program test-session-host test-hosted-terminal
test-terminal-program:
	swiftc -parse-as-library Sources/OneAgent/TerminalProgram.swift Tests/TerminalProgramTests.swift -o /tmp/oneagent-program-tests
	/tmp/oneagent-program-tests

test-session-host:
	bash scripts/test-session-snapshot.sh
	bash scripts/build-session-host.sh build/1AgentSessionHost
	python3 scripts/test-session-host.py

test-hosted-terminal:
	bash scripts/test-hosted-terminal.sh
