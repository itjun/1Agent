.PHONY: gen build install run test clean

# Command Line Tools cannot run xcodebuild. Prefer the full Xcode.app when that is the case.
ifeq ($(shell xcode-select -p 2>/dev/null),/Library/Developer/CommandLineTools)
  export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
endif

CODE_SIGN_IDENTITY ?= -
APP_BUNDLE = Goose Agent.app
APP_BUILT = build/Build/Products/Debug/$(APP_BUNDLE)

gen:
	xcodegen generate

# Compile, then install into /Applications (quit → replace → relaunch if needed).
build: gen
	set -o pipefail; xcodebuild -project GooseAgent.xcodeproj -scheme GooseAgent -configuration Debug -derivedDataPath build build CODE_SIGN_IDENTITY="$(CODE_SIGN_IDENTITY)" CODE_SIGN_STYLE=Manual -skipPackagePluginValidation | tee /tmp/goose-agent-build.log | tail -8
	./scripts/install-app.sh "$(CURDIR)/$(APP_BUILT)"

install:
	./scripts/install-app.sh "$(CURDIR)/$(APP_BUILT)"

run: build
	open "/Applications/$(APP_BUNDLE)"

test:
	swiftc -o /tmp/goose-ssh-config-test Sources/GooseAgent/SSHConfig.swift Tests/SSHConfigTests.swift
	/tmp/goose-ssh-config-test

clean:
	rm -rf build GooseAgent.xcodeproj
