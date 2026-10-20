import AppKit
import ObjectiveC
import SwiftUI
@testable import GooseAgent

/// Render production dialog content in the production modal host, with isolated
/// preferences/files and no shell, SSH, command execution, save or import actions.
@main enum ModalAppearanceTests {
    @MainActor static func main() {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { fputs("ModalAppearanceTests failed: \(error)\n", stderr); exit(1) }
        }
        NSApp.run()
    }

    @MainActor static var failures: [String] = []
    @MainActor static func expect(_ condition: Bool, _ message: String) {
        if !condition { failures.append(message); print("FAIL: \(message)") }
    }

    @MainActor static func run() async throws {
        let home = ProcessInfo.processInfo.environment["ONEAGENT_TEST_HOME"]!
        precondition(home.hasPrefix("/private/tmp/oneagent-modal-appearance."))
        precondition(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path == URL(fileURLWithPath: home).resolvingSymlinksInPath().path)
        let defaults = UserDefaults(suiteName: "oneagent.modal-appearance.\(UUID())")!
        let getter = class_getClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults"))!
        let previous = method_getImplementation(getter)
        let block: @convention(block) (AnyObject) -> UserDefaults = { _ in defaults }
        method_setImplementation(getter, imp_implementationWithBlock(block))
        defer { method_setImplementation(getter, previous) }
        let model = AppModel(), state = model.mainWindow
        let context = QuickCommandContext(directory: home)
        let item = QuickCommand(alias: "外观检查", command: "printf '%s\\n' '中文文字'", scope: .local)
        let paste = try QuickCommandPasteRequest(transfer: QuickCommandTransfer(commands: [item]), context: context)
        let plan = GhosttyConfigImport.makePlan()
        let fixtures: [(String, CGFloat, CGFloat, AnyView)] = [
            ("host picker", SheetLayout.search, SheetLayout.sessionBodyHeight, AnyView(HostPicker(model: model, window: state))),
            ("command palette", SheetLayout.search, SheetLayout.commandPaletteHeight, AnyView(TerminalCommandPalette(model: model, window: state, onClose: {}))),
            ("command editor", SheetLayout.quickCommand, SheetLayout.quickCommandHeight, AnyView(QuickCommandEditor(item: item, hosts: [], onClose: {}))),
            ("command details", SheetLayout.quickCommand, SheetLayout.quickCommandHeight, AnyView(QuickCommandDetails(item: item, onClose: {}))),
            ("command confirmation", SheetLayout.quickCommand, SheetLayout.quickCommandHeight, AnyView(QuickCommandConfirmation(confirmation: QuickCommandConfirmationTarget(item: item, context: context), model: model, window: state, onClose: {}))),
            ("command paste", SheetLayout.quickCommand, SheetLayout.quickCommandHeight, AnyView(QuickCommandPasteView(request: paste, onClose: {}, onSaved: { _ in }))),
            ("command library", SheetLayout.commandLibrary, SheetLayout.commandLibraryHeight, AnyView(QuickCommandLibraryView(model: model, window: state, onClose: {}))),
            ("command history", SheetLayout.commandLibrary, SheetLayout.commandLibraryHeight, AnyView(QuickCommandHistoryView(context: context, hosts: [], onClose: {}))),
            ("command import", SheetLayout.commandLibrary, SheetLayout.commandLibraryHeight, AnyView(QuickCommandImportView(library: QuickCommandLibrary(commands: [item]), hosts: [], onClose: {}))),
            ("folder picker", SheetLayout.folderPicker, SheetLayout.sessionBodyHeight, AnyView(FamilyFolderPicker(initialDirectory: home, onCancel: {}, onChoose: { _ in }))),
            ("settings import preview", SheetLayout.importPreview, SheetLayout.importPreviewBodyHeight, AnyView(GhosttyImportPreviewSheet(plan: plan, onCancel: {}, onImport: {})))
        ]
        let owner = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1101, height: 801), styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        owner.makeKeyAndOrderFront(nil)
        defer { FamilyMenuPresenter.shared.dismiss(); owner.close() }
        for (name, width, height, view) in fixtures {
            owner.contentView = NSHostingView(rootView: AuditHost(content: view, width: width, height: height))
            try await until { owner.childWindows?.contains { $0 is FamilyModalWindow } == true }
            let dialog = owner.childWindows!.first { $0 is FamilyModalWindow }!
            for dark in [false, true, false] {
                defaults.set(dark ? "dark" : "light", forKey: TerminalAppearance.storageKey)
                AppearanceDriver.shared.reapply()
                await settle()
                let card = (dialog.contentView as! FamilyModalBackdrop).card!
                checkSurface(card, dark: dark, name: name)
                // Exercise a real nested sheet entry rather than recreating its content.
                if name == "command library", dark {
                    let button = elements(card).first { object in
                        ["accessibilityTitle", "accessibilityLabel", "accessibilityValue"].contains { key in
                            let raw = value(object, key)
                            return ((raw as? String) ?? (raw as? NSAttributedString)?.string) == String(localized: "New Quick Command")
                        } && object.responds(to: NSSelectorFromString("accessibilityPerformPress"))
                    }
                    expect(button != nil, "library exposes its nested editor action")
                    guard let button else { continue }
                    expect(invoke(button, "accessibilityPerformPress"), "nested editor action activates")
                    try await until { dialog.childWindows?.contains { $0 is FamilyModalWindow } == true }
                    let nested = dialog.childWindows!.first { $0 is FamilyModalWindow }!
                    await settle()
                    checkSurface((nested.contentView as! FamilyModalBackdrop).card!, dark: true, name: "library → nested editor")
                    nested.cancelOperation(nil)
                    try await until { dialog.childWindows?.isEmpty != false }
                }
            }
            dialog.cancelOperation(nil)
            try await until { owner.childWindows?.isEmpty != false }
            print("CHECKED: \(name), light → dark → light, native input colors and dismissal")
        }
        // The production workspace anchor must capture the same palette as its
        // content, even without the optional Host Information feature installed.
        owner.contentView = NSHostingView(rootView: RootView(model: model, window: state))
        defaults.set("dark", forKey: TerminalAppearance.storageKey)
        AppearanceDriver.shared.reapply()
        await settle()
        state.quickCommandConfirmation = QuickCommandConfirmationTarget(item: item, context: context)
        try await until { owner.childWindows?.contains { $0 is FamilyModalWindow } == true }
        let rootDialog = owner.childWindows!.first { $0 is FamilyModalWindow }!
        for dark in [true, false] {
            defaults.set(dark ? "dark" : "light", forKey: TerminalAppearance.storageKey)
            AppearanceDriver.shared.reapply()
            await settle()
            checkSurface((rootDialog.contentView as! FamilyModalBackdrop).card!, dark: dark, name: "workspace confirmation")
        }
        rootDialog.cancelOperation(nil)
        try await until { owner.childWindows?.isEmpty != false && state.quickCommandConfirmation == nil }
        print("CHECKED: actual workspace confirmation inherits light/dark appearance")
        owner.contentView = NSView()
        let alert = FamilyAlert()
        alert.messageText = "确认操作"
        alert.informativeText = "用于检查文字及深浅色的原生确认弹窗。"
        let input = FamilyNativeTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 32))
        input.stringValue = "中文名称"
        alert.accessoryView = input
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: owner) { _ in }
        for dark in [true, false] {
            defaults.set(dark ? "dark" : "light", forKey: TerminalAppearance.storageKey)
            AppearanceDriver.shared.reapply()
            await settle()
            checkSurface(alert.presentation!.backdrop.card!, dark: dark, name: "native confirmation")
        }
        alert.cancel()

        let transfer = TransferToast.shared.begin("传输提示外观检查", in: owner)
        await settle()
        let toast = owner.childWindows!.first!
        for dark in [true, false] {
            defaults.set(dark ? "dark" : "light", forKey: TerminalAppearance.storageKey)
            AppearanceDriver.shared.reapply()
            await settle()
            checkSurface(toast.contentView!, dark: dark, name: "transfer toast", elevated: true)
        }
        TransferToast.shared.finish(transfer, "检查完成")
        if !failures.isEmpty { throw NSError(domain: "ModalAppearanceTests", code: failures.count, userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")]) }
        print("ModalAppearanceTests passed: all dialog surfaces, live appearance changes, workspace confirmation, nested editor, native confirmation and transfer toast")
    }

    @MainActor static func checkSurface(_ view: NSView, dark: Bool, name: String, elevated: Bool = false) {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let pixel = bitmap.colorAt(x: 20, y: 20)!
        let chrome = WindowChrome(isDark: dark)
        // cacheDisplay is tagged with the display ICC profile; compare in that
        // space instead of interpreting those channels as untagged sRGB.
        let expected = NSColor(elevated ? chrome.elevated : chrome.background).usingColorSpace(bitmap.colorSpace)!
        expect(abs(pixel.redComponent - expected.redComponent) < 0.03 && abs(pixel.greenComponent - expected.greenComponent) < 0.03 && abs(pixel.blueComponent - expected.blueComponent) < 0.03, "\(name): \(dark ? "dark" : "light") surface, actual \(pixel)")
        let expectedText = NSColor(chrome.text).usingColorSpace(.sRGB)!
        for object in elements(view) {
            let color: NSColor?
            if let field = object as? CommandLiteralTextField { color = field.textColor }
            else if let editor = object as? CommandLiteralTextView { color = editor.textColor }
            else if let field = object as? FamilyNativeTextField { color = field.textColor }
            else { continue }
            guard let actual = color?.usingColorSpace(.sRGB) else { expect(false, "\(name): missing native text color"); continue }
            expect(abs(actual.redComponent - expectedText.redComponent) < 0.01 && abs(actual.greenComponent - expectedText.greenComponent) < 0.01 && abs(actual.blueComponent - expectedText.blueComponent) < 0.01, "\(name): native input text follows appearance, dark=\(dark)")
        }
    }
    @MainActor static func settle() async { try? await Task.sleep(for: .milliseconds(150)) }
    @MainActor static func until(_ condition: () -> Bool) async throws {
        for _ in 0..<30 { if condition() { return }; await settle() }
        throw NSError(domain: "ModalAppearanceTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for modal presentation/dismissal"])
    }
    @MainActor static func value(_ object: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
    }
    @MainActor static func invoke(_ object: NSObject, _ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let method = object.method(for: selector) else { return false }
        typealias Action = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method, to: Action.self)(object, selector)
    }
    @MainActor static func elements(_ root: Any) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        func walk(_ object: Any) -> [NSObject] {
            guard let object = object as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            return [object] + ((value(object, "accessibilityChildren") as? [Any] ?? []) + ((object as? NSView)?.subviews ?? [])).flatMap(walk)
        }
        return walk(root)
    }
}

private struct AuditHost: View {
    let content: AnyView
    let width: CGFloat
    let height: CGFloat
    @State private var presented = true
    @ObservedObject private var appearance = AppearanceDriver.shared
    var body: some View {
        Color.clear.familySheet(isPresented: $presented, width: width, height: height) { content }
            .environment(\.windowChrome, WindowChrome(isDark: appearance.isDark))
            .preferredColorScheme(appearance.interfaceColorScheme)
    }
}
