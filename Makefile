.PHONY: gen build install run test test-appearance clean

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

# Compile, then install into /Applications (quit → replace → relaunch if needed).
build: gen
	set -o pipefail; xcodebuild -project 1Agent.xcodeproj -scheme 1Agent -configuration Debug -derivedDataPath $(DERIVED_DATA) -clonedSourcePackagesDirPath build/SourcePackages build CODE_SIGN_IDENTITY="$(CODE_SIGN_IDENTITY)" CODE_SIGN_STYLE=Manual -skipPackagePluginValidation | tee /tmp/1agent-build.log | tail -8
	if [ "$(CODE_SIGN_IDENTITY)" = "-" ]; then ./scripts/local-codesign.sh "$(CURDIR)/$(APP_BUILT)"; fi
	./scripts/install-app.sh "$(CURDIR)/$(APP_BUILT)"

install:
	./scripts/install-app.sh "$(CURDIR)/$(APP_BUILT)"

run: build
	open "/Applications/$(APP_BUNDLE)"

test:
	swiftc -parse-as-library -o /tmp/oneagent-family-dialog-tests Sources/GooseAgent/Theme.swift Sources/GooseAgent/FocusRing.swift Sources/GooseAgent/SheetLayout.swift Sources/GooseAgent/FamilyModal.swift Sources/GooseAgent/FamilyAlert.swift Tests/FamilyDialogTests.swift
	/tmp/oneagent-family-dialog-tests
	swiftc -parse-as-library -o /tmp/oneagent-family-menu-test Sources/GooseAgent/Theme.swift Sources/GooseAgent/FamilyMenu.swift Tests/FamilyMenuTests.swift
	/tmp/oneagent-family-menu-test
	swiftc -parse-as-library -o /tmp/oneagent-preview-syntax-test Sources/GooseAgent/Files/PreviewSyntax.swift Sources/GooseAgent/Files/NativeTextPreview.swift Sources/GooseAgent/Theme.swift Sources/GooseAgent/FamilyMenu.swift Tests/PreviewSyntaxTests.swift
	/tmp/oneagent-preview-syntax-test
	swiftc -parse-as-library -o /tmp/oneagent-pinned-locations-test Sources/GooseAgent/Files/PinnedLocations.swift Tests/PinnedLocationsTests.swift
	/tmp/oneagent-pinned-locations-test
	swiftc -o /tmp/oneagent-workspace-presentation-test Sources/GooseAgent/WorkspacePresentation.swift Sources/GooseAgent/PaneLayout.swift Sources/GooseAgent/WorkspaceBoard.swift Tests/WorkspacePresentationTests.swift
	/tmp/oneagent-workspace-presentation-test
	swiftc -o /tmp/goose-native-sidebar-test Sources/GooseAgent/NativeSidebarSplit.swift Sources/GooseAgent/WorkspacePresentation.swift Tests/NativeSidebarSplitTests.swift
	/tmp/goose-native-sidebar-test
	swiftc -o /tmp/goose-ssh-config-test Sources/GooseAgent/SSHConfig.swift Tests/SSHConfigTests.swift
	/tmp/goose-ssh-config-test
	swiftc -o /tmp/goose-external-open-test Sources/GooseAgent/PaneLayout.swift Sources/GooseAgent/WorkspaceBoard.swift Sources/GooseAgent/ExternalOpen.swift Tests/ExternalOpenTests.swift
	/tmp/goose-external-open-test
	swiftc -o /tmp/goose-pane-layout-test Sources/GooseAgent/PaneLayout.swift Sources/GooseAgent/WorkspaceBoard.swift Tests/PaneLayoutTests.swift
	/tmp/goose-pane-layout-test
	swiftc -o /tmp/goose-workspace-board-test Sources/GooseAgent/PaneLayout.swift Sources/GooseAgent/WorkspaceBoard.swift Tests/WorkspaceBoardTests.swift
	/tmp/goose-workspace-board-test
	swiftc -o /tmp/goose-settings-window-frame-test Sources/GooseAgent/SettingsWindowFrame.swift Tests/SettingsWindowFrameTests.swift
	/tmp/goose-settings-window-frame-test
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
	bash scripts/test-terminal-history.sh
	bash scripts/test-upload-check.sh

# Uses the production Debug module. Run make build first.
test-appearance:
	bash scripts/test-family-appearance.sh

clean:
	rm -rf build 1Agent.xcodeproj GooseAgent.xcodeproj
