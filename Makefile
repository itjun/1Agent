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

test-terminal-automation:
	python3 scripts/test-terminal-automation.py

test-terminal-compatibility:
	bash scripts/test-terminal-windows.sh "" --compatibility
	ONEAGENT_COMPATIBILITY_NO_FEATURES=1 bash scripts/test-terminal-windows.sh "" --shell-compatibility

test-terminal-stress:
	bash scripts/test-terminal-windows.sh "" --stress-compatibility

test-terminal-windows:
	bash scripts/test-terminal-windows.sh

test-scripting-replies:
	clang -fobjc-arc -framework Foundation -I Sources/GooseAgent Sources/GooseAgent/ScriptingReplyBridge.m Tests/ScriptingReplyBridgeTests.m -o /tmp/oneagent-scripting-reply-tests
	/tmp/oneagent-scripting-reply-tests

test-system-integration:
	swiftc -parse-as-library Sources/GooseAgent/TerminalAssociations.swift Tests/TerminalAssociationsTests.swift -o /tmp/oneagent-system-integration-tests
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

test: test-command-transparency test-system-integration test-scripting-replies
	swiftc -O -parse-as-library -o /tmp/oneagent-terminal-output-store-tests Sources/GooseAgent/TerminalOutputStore.swift Tests/TerminalOutputStoreTests.swift
	/tmp/oneagent-terminal-output-store-tests
	swiftc -parse-as-library -o /tmp/oneagent-remote-bridge-tests Sources/GooseAgent/QuickCommand.swift Sources/GooseAgent/LocalCommandBridge.swift Tests/RemoteCommandBridgeTests.swift
	/tmp/oneagent-remote-bridge-tests
	swiftc -o /tmp/oneagent-remote-shell-tests Sources/GooseAgent/RemoteShellIntegration.swift Tests/RemoteShellIntegrationTests.swift
	/tmp/oneagent-remote-shell-tests
	python3 scripts/test-remote-shell-cleanup.py
	swiftc -parse-as-library -o /tmp/oneagent-remote-palette-tests Sources/GooseAgent/ApplicationIcon.swift Sources/GooseAgent/Theme.swift Tests/RemotePaletteTests.swift
	/tmp/oneagent-remote-palette-tests
	swiftc -parse-as-library -o /tmp/oneagent-app-update-tests Sources/GooseAgent/AppUpdate.swift Tests/AppUpdateTests.swift
	/tmp/oneagent-app-update-tests
	ONEAGENT_REMOTE_INTEGRATION_TEST=1 python3 scripts/test-quick-command-bridge.py
	swiftc -parse-as-library -o /tmp/oneagent-quick-command-tests Sources/GooseAgent/QuickCommand.swift Sources/GooseAgent/QuickCommandTransfer.swift Sources/GooseAgent/QuickCommandStore.swift Sources/GooseAgent/QuickCommandHistory.swift Sources/GooseAgent/WorkspacePresentation.swift Tests/QuickCommandTests.swift
	/tmp/oneagent-quick-command-tests
	python3 scripts/test-quick-command-bridge.py
	python3 scripts/test-quick-command-startup.py
	swiftc -parse-as-library -o /tmp/oneagent-command-literal-editor-test Sources/GooseAgent/CommandLiteralEditor.swift Tests/CommandLiteralEditorTests.swift
	/tmp/oneagent-command-literal-editor-test
	swiftc -parse-as-library -o /tmp/oneagent-family-dialog-tests Sources/GooseAgent/Theme.swift Sources/GooseAgent/ApplicationIcon.swift Sources/GooseAgent/FocusRing.swift Sources/GooseAgent/SheetLayout.swift Sources/GooseAgent/FamilyModal.swift Sources/GooseAgent/FamilyAlert.swift Tests/FamilyDialogTests.swift
	/tmp/oneagent-family-dialog-tests
	swiftc -parse-as-library -o /tmp/oneagent-family-menu-test Sources/GooseAgent/Theme.swift Sources/GooseAgent/ApplicationIcon.swift Sources/GooseAgent/FamilyMenu.swift Tests/FamilyMenuTests.swift
	/tmp/oneagent-family-menu-test
	swiftc -parse-as-library -o /tmp/oneagent-preview-syntax-test Sources/GooseAgent/Files/PreviewSyntax.swift Sources/GooseAgent/Files/NativeTextPreview.swift Sources/GooseAgent/Theme.swift Sources/GooseAgent/ApplicationIcon.swift Sources/GooseAgent/FamilyMenu.swift Tests/PreviewSyntaxTests.swift
	/tmp/oneagent-preview-syntax-test
	swiftc -parse-as-library -o /tmp/oneagent-pinned-locations-test Sources/GooseAgent/Files/PinnedLocations.swift Tests/PinnedLocationsTests.swift
	/tmp/oneagent-pinned-locations-test
	swiftc -o /tmp/oneagent-workspace-presentation-test Sources/GooseAgent/WorkspacePresentation.swift Sources/GooseAgent/PaneLayout.swift Sources/GooseAgent/WorkspaceBoard.swift Tests/WorkspacePresentationTests.swift
	/tmp/oneagent-workspace-presentation-test
	swiftc -o /tmp/goose-native-sidebar-test Sources/GooseAgent/NativeSidebarSplit.swift Sources/GooseAgent/WorkspacePresentation.swift Tests/NativeSidebarSplitTests.swift
	/tmp/goose-native-sidebar-test
	swiftc -o /tmp/goose-ssh-config-test Sources/GooseAgent/SSHConfig.swift Tests/SSHConfigTests.swift
	/tmp/goose-ssh-config-test
	swiftc -framework AppKit -o /tmp/goose-external-open-test Sources/GooseAgent/PaneLayout.swift Sources/GooseAgent/WorkspaceBoard.swift Sources/GooseAgent/ExternalOpen.swift Tests/ExternalOpenTests.swift
	/tmp/goose-external-open-test
	swiftc -o /tmp/goose-pane-layout-test Sources/GooseAgent/PaneLayout.swift Sources/GooseAgent/WorkspaceBoard.swift Tests/PaneLayoutTests.swift
	/tmp/goose-pane-layout-test
	swiftc -o /tmp/goose-workspace-board-test Sources/GooseAgent/PaneLayout.swift Sources/GooseAgent/WorkspaceBoard.swift Tests/WorkspaceBoardTests.swift
	/tmp/goose-workspace-board-test
	swiftc -o /tmp/goose-settings-window-frame-test Sources/GooseAgent/SettingsWindowFrame.swift Tests/SettingsWindowFrameTests.swift
	/tmp/goose-settings-window-frame-test
	swiftc -o /tmp/goose-main-window-frame-test Sources/GooseAgent/MainWindowFrame.swift Tests/MainWindowFrameTests.swift
	/tmp/goose-main-window-frame-test
	swiftc -o /tmp/goose-terminal-settings-test Sources/GooseAgent/TerminalSettings.swift Tests/TerminalSettingsTests.swift
	/tmp/goose-terminal-settings-test
	swiftc -o /tmp/goose-command-finished-policy-test Sources/GooseAgent/TerminalSettings.swift Sources/GooseAgent/CommandFinishedPolicy.swift Tests/CommandFinishedPolicyTests.swift
	/tmp/goose-command-finished-policy-test
	swiftc -o /tmp/goose-shell-escape-test Sources/GooseAgent/ShellEscape.swift Tests/ShellEscapeTests.swift
	/tmp/goose-shell-escape-test
	swiftc -o /tmp/goose-shell-integration-test Sources/GooseAgent/TerminalSettings.swift Sources/GooseAgent/ShellIntegration.swift Tests/ShellIntegrationTests.swift
	/tmp/goose-shell-integration-test
	swiftc -o /tmp/goose-ghostty-config-importer-test Sources/GooseAgent/TerminalSettings.swift Sources/GooseAgent/GhosttyConfigImporter.swift Tests/GhosttyConfigImporterTests.swift
	/tmp/goose-ghostty-config-importer-test
	swiftc -o /tmp/goose-keyboard-shortcuts-test Sources/GooseAgent/KeyboardShortcuts.swift Tests/KeyboardShortcutsTests.swift
	/tmp/goose-keyboard-shortcuts-test
	swiftc -o /tmp/goose-drop-zone-layout-test Sources/GooseAgent/DropZoneLayout.swift Tests/DropZoneLayoutTests.swift
	/tmp/goose-drop-zone-layout-test
	swiftc -o /tmp/goose-file-rules-test Sources/GooseAgent/Files/FileRules.swift Tests/FileRulesTests.swift
	/tmp/goose-file-rules-test
	swiftc -o /tmp/goose-text-file-test Sources/GooseAgent/Files/TextFile.swift Tests/TextFileTests.swift
	/tmp/goose-text-file-test
	swiftc -o /tmp/oneagent-ssh-launch-test Sources/GooseAgent/SSHLaunch.swift Tests/SSHLaunchTests.swift
	/tmp/oneagent-ssh-launch-test
	./scripts/test-file-safety.sh
	bash scripts/test-upload-check.sh

# Uses the production Debug module. Run make build first.
test-modal-appearance:
	bash scripts/test-modal-appearance.sh

test-appearance:
	bash scripts/test-family-appearance.sh

# Uses the production Debug module and isolated native terminal surfaces. Run make build first.
test-terminal-restoration:
	bash scripts/test-terminal-restoration.sh

# Uses the production Debug module with isolated preferences and no shell/network access.
test-quick-command-drop:
	bash scripts/test-quick-command-drop.sh

# Production model and persisted sidebar grouping, using isolated storage and no SSH/shells.
test-sidebar-groups:
	bash scripts/test-sidebar-groups.sh

.PHONY: test-sidebar-panel-drop
test-sidebar-panel-drop:
	bash scripts/test-sidebar-panel-drop.sh

clean:
	rm -rf build 1Agent.xcodeproj GooseAgent.xcodeproj

# Production transport replay with isolated preferences and no SSH/network access.
test-remote-directory:
	bash scripts/test-remote-directory.sh

# Production host information presentation, isolated from user sessions.
.PHONY: test-host-information
test-host-information:
	bash scripts/test-host-information.sh
