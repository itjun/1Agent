.PHONY: gen build install run test test-appearance test-terminal-restoration test-quick-command-drop test-sidebar-groups test-app-icons generate-app-icons clean
.PHONY: test-command-transparency
.PHONY: test-modal-appearance
.PHONY: test-system-integration
.PHONY: test-defaults-migration
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
	NATTY_COMPATIBILITY_NO_FEATURES=1 bash scripts/test-terminal-windows.sh "" --shell-compatibility

test-terminal-stress:
	bash scripts/test-terminal-windows.sh "" --stress-compatibility

test-terminal-windows:
	bash scripts/test-terminal-windows.sh

.PHONY: test-command-drag
test-command-drag:
	bash scripts/test-terminal-windows.sh "" --command-drag

test-scripting-replies:
	clang -fobjc-arc -framework Foundation -I Sources/Natty Sources/Natty/ScriptingReplyBridge.m Tests/ScriptingReplyBridgeTests.m -o /tmp/natty-scripting-reply-tests
	/tmp/natty-scripting-reply-tests

test-system-integration:
	swiftc -parse-as-library Sources/Natty/TerminalAssociations.swift Tests/TerminalAssociationsTests.swift -o /tmp/natty-system-integration-tests
	/tmp/natty-system-integration-tests

test-defaults-migration:
	swiftc -parse-as-library Sources/Natty/LegacyDefaultsMigration.swift Tests/LegacyDefaultsMigrationTests.swift -o /tmp/natty-defaults-migration-tests
	/tmp/natty-defaults-migration-tests

test-command-transparency:
	python3 scripts/test-command-transparency.py

# Command Line Tools cannot run xcodebuild. Prefer the full Xcode.app when that is the case.
ifeq ($(shell xcode-select -p 2>/dev/null),/Library/Developer/CommandLineTools)
  export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
endif

CODE_SIGN_IDENTITY ?= -
APP_BUNDLE = Natty.app
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
	set -o pipefail; xcodebuild -project Natty.xcodeproj -scheme Natty -configuration Debug -derivedDataPath $(DERIVED_DATA) -clonedSourcePackagesDirPath build/SourcePackages build CODE_SIGN_IDENTITY="$(CODE_SIGN_IDENTITY)" CODE_SIGN_STYLE=Manual -skipPackagePluginValidation | tee /tmp/natty-build.log | tail -8
	if [ "$(CODE_SIGN_IDENTITY)" = "-" ]; then ./scripts/local-codesign.sh "$(CURDIR)/$(APP_BUILT)"; fi
	./scripts/install-app.sh "$(CURDIR)/$(APP_BUILT)"

prepare-libghostty:
	./scripts/build-libghostty.sh

install:
	./scripts/install-app.sh "$(CURDIR)/$(APP_BUILT)"

run: build
	open "/Applications/$(APP_BUNDLE)"

test: test-release-signing test-ssh-configuration test-command-transparency test-system-integration test-scripting-replies test-defaults-migration
	swiftc -O -parse-as-library -o /tmp/natty-terminal-output-store-tests Sources/Natty/LegacyDefaultsMigration.swift Sources/Natty/TerminalOutputStore.swift Tests/TerminalOutputStoreTests.swift
	/tmp/natty-terminal-output-store-tests
	swiftc -parse-as-library -o /tmp/natty-remote-bridge-tests Sources/Natty/QuickCommand.swift Sources/Natty/CommandBridgeSocket.swift Sources/Natty/RemoteCommandBridge.swift Sources/Natty/TerminalSessionConnection.swift Tests/RemoteCommandBridgeTests.swift
	/tmp/natty-remote-bridge-tests
	swiftc -parse-as-library -o /tmp/natty-local-bridge-tests Sources/Natty/QuickCommand.swift Sources/Natty/CommandBridgeSocket.swift Sources/Natty/LocalCommandBridge.swift Sources/Natty/TerminalSessionConnection.swift Tests/LocalCommandBridgeTests.swift
	/tmp/natty-local-bridge-tests
	swiftc -o /tmp/natty-remote-shell-tests Sources/Natty/RemoteShellIntegration.swift Tests/RemoteShellIntegrationTests.swift
	/tmp/natty-remote-shell-tests
	python3 scripts/test-remote-shell-cleanup.py
	swiftc -parse-as-library -o /tmp/natty-remote-palette-tests Sources/Natty/ApplicationIcon.swift Sources/Natty/Theme.swift Tests/RemotePaletteTests.swift
	/tmp/natty-remote-palette-tests
	swiftc -parse-as-library -o /tmp/natty-app-update-tests Sources/Natty/AppUpdate.swift Tests/AppUpdateTests.swift
	/tmp/natty-app-update-tests
	NATTY_REMOTE_INTEGRATION_TEST=1 python3 scripts/test-quick-command-bridge.py
	swiftc -parse-as-library -o /tmp/natty-quick-command-tests Sources/Natty/QuickCommand.swift Sources/Natty/QuickCommandTransfer.swift Sources/Natty/LegacyDefaultsMigration.swift Sources/Natty/QuickCommandStore.swift Sources/Natty/QuickCommandHistory.swift Sources/Natty/WorkspacePresentation.swift Tests/QuickCommandTests.swift
	/tmp/natty-quick-command-tests
	python3 scripts/test-quick-command-bridge.py
	python3 scripts/test-quick-command-startup.py
	swiftc -parse-as-library -o /tmp/natty-command-literal-editor-test Sources/Natty/CommandLiteralEditor.swift Tests/CommandLiteralEditorTests.swift
	/tmp/natty-command-literal-editor-test
	swiftc -parse-as-library -o /tmp/natty-family-dialog-tests Sources/Natty/Theme.swift Sources/Natty/ApplicationIcon.swift Sources/Natty/FocusRing.swift Sources/Natty/SheetLayout.swift Sources/Natty/FamilyModal.swift Sources/Natty/FamilyAlert.swift Tests/FamilyDialogTests.swift
	/tmp/natty-family-dialog-tests
	swiftc -parse-as-library -o /tmp/natty-family-menu-test Sources/Natty/Theme.swift Sources/Natty/ApplicationIcon.swift Sources/Natty/FamilyMenu.swift Tests/FamilyMenuTests.swift
	/tmp/natty-family-menu-test
	bash scripts/test-preview-syntax.sh
	swiftc -parse-as-library -o /tmp/natty-pinned-locations-test Sources/Natty/Files/PinnedLocations.swift Tests/PinnedLocationsTests.swift
	/tmp/natty-pinned-locations-test
	swiftc -o /tmp/natty-workspace-presentation-test Sources/Natty/WorkspacePresentation.swift Sources/Natty/PaneLayout.swift Sources/Natty/WorkspaceBoard.swift Tests/WorkspacePresentationTests.swift
	/tmp/natty-workspace-presentation-test
	swiftc -o /tmp/natty-native-sidebar-test Sources/Natty/NativeSidebarSplit.swift Sources/Natty/WorkspacePresentation.swift Tests/NativeSidebarSplitTests.swift
	/tmp/natty-native-sidebar-test
	swiftc -o /tmp/natty-ssh-config-test Sources/Natty/SSHConfig.swift Tests/SSHConfigTests.swift
	/tmp/natty-ssh-config-test
	swiftc -framework AppKit -o /tmp/natty-external-open-test Sources/Natty/PaneLayout.swift Sources/Natty/WorkspaceBoard.swift Sources/Natty/ExternalOpen.swift Tests/ExternalOpenTests.swift
	/tmp/natty-external-open-test
	swiftc -o /tmp/natty-pane-layout-test Sources/Natty/PaneLayout.swift Sources/Natty/WorkspaceBoard.swift Tests/PaneLayoutTests.swift
	/tmp/natty-pane-layout-test
	swiftc -o /tmp/natty-workspace-board-test Sources/Natty/PaneLayout.swift Sources/Natty/WorkspaceBoard.swift Tests/WorkspaceBoardTests.swift
	/tmp/natty-workspace-board-test
	swiftc -o /tmp/natty-main-window-frame-test Sources/Natty/MainWindowFrame.swift Tests/MainWindowFrameTests.swift
	/tmp/natty-main-window-frame-test
	swiftc -o /tmp/natty-terminal-settings-test Sources/Natty/TerminalSettings.swift Tests/TerminalSettingsTests.swift
	/tmp/natty-terminal-settings-test
	swiftc -o /tmp/natty-command-finished-policy-test Sources/Natty/TerminalSettings.swift Sources/Natty/CommandFinishedPolicy.swift Tests/CommandFinishedPolicyTests.swift
	/tmp/natty-command-finished-policy-test
	swiftc -o /tmp/natty-shell-escape-test Sources/Natty/ShellEscape.swift Tests/ShellEscapeTests.swift
	/tmp/natty-shell-escape-test
	swiftc -o /tmp/natty-shell-integration-test Sources/Natty/TerminalSettings.swift Sources/Natty/ShellIntegration.swift Tests/ShellIntegrationTests.swift
	/tmp/natty-shell-integration-test
	swiftc -o /tmp/natty-ghostty-config-importer-test Sources/Natty/TerminalSettings.swift Sources/Natty/GhosttyConfigImporter.swift Tests/GhosttyConfigImporterTests.swift
	/tmp/natty-ghostty-config-importer-test
	swiftc -o /tmp/natty-keyboard-shortcuts-test Sources/Natty/KeyboardShortcuts.swift Tests/KeyboardShortcutsTests.swift
	/tmp/natty-keyboard-shortcuts-test
	swiftc -o /tmp/natty-drop-zone-layout-test Sources/Natty/DropZoneLayout.swift Tests/DropZoneLayoutTests.swift
	/tmp/natty-drop-zone-layout-test
	swiftc -o /tmp/natty-file-rules-test Sources/Natty/Files/FileRules.swift Tests/FileRulesTests.swift
	/tmp/natty-file-rules-test
	swiftc -o /tmp/natty-text-file-test Sources/Natty/Files/TextFile.swift Tests/TextFileTests.swift
	/tmp/natty-text-file-test
	swiftc -o /tmp/natty-ssh-launch-test Sources/Natty/SSHLaunch.swift Tests/SSHLaunchTests.swift
	/tmp/natty-ssh-launch-test
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
	rm -rf build Natty.xcodeproj

# Production transport replay with isolated preferences and no SSH/network access.
test-remote-directory:
	bash scripts/test-remote-directory.sh

# Production host information presentation, isolated from user sessions.
.PHONY: test-host-information
test-host-information:
	bash scripts/test-host-information.sh

.PHONY: test-ssh-configuration
test-ssh-configuration:
	swiftc -parse-as-library Sources/Natty/SSHConfigurationResolver.swift Tests/SSHConfigurationResolverTests.swift -o /tmp/natty-ssh-resolution-tests
	/tmp/natty-ssh-resolution-tests

# Production reconnect model and network recovery, isolated from user sessions.
.PHONY: test-terminal-reconnect
test-terminal-reconnect:
	bash scripts/test-terminal-reconnect.sh

.PHONY: test-terminal-program test-session-host test-hosted-terminal
test-terminal-program:
	swiftc -parse-as-library Sources/Natty/TerminalProgram.swift Tests/TerminalProgramTests.swift -o /tmp/natty-program-tests
	/tmp/natty-program-tests

test-session-host:
	bash scripts/test-session-snapshot.sh
	bash scripts/build-session-host.sh build/NattySessionHost
	python3 scripts/test-session-host.py

test-hosted-terminal:
	bash scripts/test-hosted-terminal.sh
