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
        checkContextMenuGesture()
        let context = QuickCommandContext(directory: home)
        let item = QuickCommand(alias: "外观检查", command: "printf '%s\\n' '中文文字'", scope: .local)
        try QuickCommandStore.shared.save(item)
        try await checkCommandPreview(item, model: model)
        let paste = try QuickCommandPasteRequest(transfer: QuickCommandTransfer(commands: [item]), context: context)
        let plan = GhosttyConfigImport.makePlan()
        if let language = ProcessInfo.processInfo.environment["ONEAGENT_TEST_LANGUAGE"] {
            let expectedImport = language == "zh-Hans" ? "导入" : "Import"
            let expectedExport = language == "zh-Hans" ? "导出" : "Export"
            expect(String(localized: "Import…") == expectedImport, "\(language) import label is complete")
            expect(String(localized: "Export…") == expectedExport, "\(language) export label is complete")
        }
        let fixtures: [(String, CGFloat, CGFloat, AnyView)] = [
            ("host picker", SheetLayout.search, SheetLayout.sessionBodyHeight, AnyView(HostPicker(model: model, window: state))),
            ("command editor", SheetLayout.commandEditor, SheetLayout.commandEditorHeight, AnyView(QuickCommandEditor(item: item, hosts: [], onClose: {}))),
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
            try await until { owner.attachedSheet != nil }
            let dialog = owner.attachedSheet!
            for dark in [false, true, false] {
                defaults.set(dark ? "dark" : "light", forKey: TerminalAppearance.storageKey)
                AppearanceDriver.shared.reapply()
                await settle()
                let card = (dialog.contentView as! FamilyModalBackdrop).card!
                checkSurface(card, dark: dark, name: name)
                if name == "command library" {
                    for (id, title) in [("quickCommands.library.actions", String(localized: "Actions")),
                                        ("quickCommands.library.edit", String(localized: "Edit"))] {
                        let button = elements(card).first { value($0, "accessibilityIdentifier") as? String == id }
                        expect(button != nil, "library exposes \(id)")
                        guard let button else { continue }
                        let selector = NSSelectorFromString("accessibilityFrame")
                        typealias FrameGetter = @convention(c) (AnyObject, Selector) -> NSRect
                        if button.responds(to: selector) {
                            let frame = unsafeBitCast(button.method(for: selector), to: FrameGetter.self)(button, selector)
                            let width = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14)]).width
                            // 面板菜单是文字加下拉箭头；编辑按钮另含图标和按钮内边距。
                            let accessoryWidth: CGFloat = id == "quickCommands.library.actions" ? 10 : 20
                            expect(frame.width >= width + accessoryWidth, "\(id) has room for its complete label")
                        } else { expect(false, "\(id) exposes its frame") }
                    }
                }
                // Exercise a real nested sheet entry rather than recreating its content.
                if name == "command library", dark {
                    var updated = item
                    updated.alias = "刷新后的名称"
                    updated.command = "printf refreshed"
                    try QuickCommandStore.shared.save(updated)
                    await settle()
                    let refreshed = elements(card).first { value($0, "accessibilityIdentifier") as? String == "quickCommand." + item.id.uuidString }
                    let rowText = refreshed.map { row in
                        ["accessibilityTitle", "accessibilityLabel"].compactMap { value(row, $0) as? String }.joined(separator: " ")
                    } ?? ""
                    expect(rowText.contains(updated.alias) && rowText.contains(updated.command), "saved edits refresh the visible command row")
                    try QuickCommandStore.shared.save(item)
                    await settle()
                    let actions = elements(card).first {
                        value($0, "accessibilityIdentifier") as? String == "quickCommands.library.actions"
                    }
                    let probe = NativeMenuProbe()
                    defer { probe.stop() }
                    expect(actions != nil && invoke(actions!, "accessibilityPerformPress"), "library opens its actions menu")
                    await settle()
                    let menuLabels = probe.menu?.items.map(\.title) ?? []
                    for title in [String(localized: "New Quick Command"), String(localized: "Import Commands"), String(localized: "Export Commands")] {
                        expect(menuLabels.contains(title), "library actions include \(title)")
                    }
                    FamilyMenuPresenter.shared.dismiss()
                    let button = elements(card).first { object in
                        value(object, "accessibilityIdentifier") as? String == "quickCommands.library.edit"
                            && object.responds(to: NSSelectorFromString("accessibilityPerformPress"))
                    }
                    expect(button != nil, "library exposes its command edit action")
                    guard let button else { continue }
                    expect(invoke(button, "accessibilityPerformPress"), "nested editor action activates")
                    try await until { dialog.attachedSheet != nil }
                    let nested = dialog.attachedSheet!
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
        try await until { owner.attachedSheet != nil }
        let rootDialog = owner.attachedSheet!
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
            expect(alert.window.sheetParent === owner, "confirmation stays a native sheet across appearance changes")
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
        print("ModalAppearanceTests passed: all dialog surfaces, live appearance changes, workspace confirmation, nested details, native confirmation and transfer toast")
    }

    @MainActor static func checkCommandPreview(_ item: QuickCommand, model: AppModel) async throws {
        let state = WindowState()
        let owner = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: AnyView(QuickCommandSidebar(model: model, window: state).frame(width: 260)
            .environment(\.windowChrome, WindowChrome(isDark: true))))
        owner.contentView = host
        owner.makeKeyAndOrderFront(nil)
        defer { owner.orderOut(nil) }
        await settle()
        func button(_ id: String) -> NSObject? {
            elements(host).first { value($0, "accessibilityIdentifier") as? String == id
                && $0.responds(to: NSSelectorFromString("accessibilityPerformPress")) }
        }
        let row = button("quickCommand." + item.id.uuidString)
        expect(row != nil && invoke(row!, "accessibilityPerformPress"), "single click opens command preview popover")
        await settle()
        expect(button("quickCommands.preview.copy") != nil, "command preview popover offers copying")
        expect(!state.isToolPreviewOpen && state.section == .terminals, "selection does not open a separate card or leave the terminal")
        expect(state.quickCommandConfirmation == nil, "preview never asks to execute")
        let sidebarText = elements(host).flatMap { object in
            ["accessibilityValue", "accessibilityLabel"].compactMap { value(object, $0) as? String }
        }.joined(separator: " ")
        expect(sidebarText.contains(item.command), "sidebar preview shows complete literal command")
        expect(invoke(button("quickCommands.new")!, "accessibilityPerformPress"), "sidebar add routes to command management")
        expect(state.section == .commands && state.commandLibraryDraft != nil, "new command opens the main command page")
        expect(owner.attachedSheet == nil, "sidebar add does not open a modal")
        state.commandLibraryDraft = nil
        host.rootView = AnyView(QuickCommandLibraryView(model: model, window: state, isWorkspace: true, onClose: {})
            .environment(\.windowChrome, WindowChrome(isDark: true)))
        await settle()
        let edit = button("quickCommands.library.edit")
        expect(edit != nil && invoke(edit!, "accessibilityPerformPress"), "main command page offers editing")
        await settle()
        expect(owner.attachedSheet == nil, "editing stays in the main page")
        let fields = elements(host)
        expect(fields.contains { ($0 as? CommandLiteralTextField)?.stringValue == item.alias }, "main page edits selected name")
        let editor = fields.compactMap { $0 as? CommandLiteralTextView }.first!
        expect(editor.string == item.command, "main page edits complete command text")
        editor.insertText("cancelled draft", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        await settle()
        expect(invoke(button("quickCommand.cancel")!, "accessibilityPerformPress"), "cancel exits page editing")
        await settle()
        expect(state.commandLibraryDraft == nil && state.section == .commands, "cancel returns to main command list")
        expect(QuickCommandStore.shared.commands.first { $0.id == item.id }?.command == item.command, "cancel keeps saved command")
        expect(invoke(button("quickCommands.library.edit")!, "accessibilityPerformPress"), "page editor can be reopened")
        await settle()
        let saveEditor = elements(host).compactMap { $0 as? CommandLiteralTextView }.first!
        let savedText = "printf 'saved in command workspace\\n'"
        saveEditor.insertText(savedText, replacementRange: NSRange(location: 0, length: (saveEditor.string as NSString).length))
        await settle()
        let save = button("quickCommand.save")!
        _ = invoke(save, "accessibilityPerformPress")
        _ = invoke(save, "accessibilityPerformPress")
        try await until { state.commandLibraryDraft == nil }
        expect(QuickCommandStore.shared.commands.first { $0.id == item.id }?.command == savedText, "page save persists literal command")
        expect(QuickCommandStore.shared.commands.filter { $0.id == item.id }.count == 1, "repeated save does not duplicate command")
        await settle()
        expect(button("quickCommands.library.edit") != nil && owner.attachedSheet == nil, "save returns to the main list without a modal")
        try QuickCommandStore.shared.save(item)
        state.commandLibraryCollection = .common
        await settle()
        let newProbe = NativeMenuProbe()
        defer { newProbe.stop() }
        expect(invoke(button("quickCommands.library.actions")!, "accessibilityPerformPress"), "public library opens its actions menu")
        await settle()
        let newCommand = newProbe.menu?.items.firstIndex { $0.title == String(localized: "New Quick Command") }
        expect(newCommand != nil, "public library offers a native new-command menu item")
        if let newCommand { newProbe.menu?.performActionForItem(at: newCommand) }
        await settle()
        expect(state.commandLibraryDraft?.scope == .all, "public library draft has no host binding")
        expect(!elements(host).contains { value($0, "accessibilityIdentifier") as? String == "quickCommand.host" }, "public editor does not ask for a host")
        expect(!elements(host).contains { value($0, "accessibilityIdentifier") as? String == "quickCommand.directory" }, "public editor does not ask for a directory")
        expect(invoke(button("quickCommand.cancel")!, "accessibilityPerformPress"), "public text draft can be cancelled")
        await settle()
        host.rootView = AnyView(QuickCommandLibraryNavigation(model: model, window: state)
            .environment(\.windowChrome, WindowChrome(isDark: true)))
        await settle()
        expect(button("quickCommands.library.collection.common") != nil, "empty public library remains available in main sidebar")
        expect(invoke(button("quickCommands.library.collection.local")!, "accessibilityPerformPress"), "main sidebar switches command category")
        expect(state.commandLibraryCollection == .local, "main sidebar and detail share collection selection")
        model.showSection(.terminals, in: state)
        expect(state.section == .terminals && !state.presentation.filesVisible, "terminal navigation leaves command page")
        expect(try JSONDecoder().decode(AppSection.self, from: Data("\"commands\"".utf8)) == .commands, "command page restores from saved session")
        print("CHECKED: sidebar text preview without separate card; main command page add/edit/save/cancel and navigation")
    }

    @MainActor static func checkContextMenuGesture() {
        let owner = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let row = FamilyContextAnchorView(frame: NSRect(x: 200, y: 100, width: 180, height: 40))
        var menuRequests = 0
        row.items = { menuRequests += 1; return [FamilyMenuItem(title: "Edit command")] }
        owner.contentView = content
        content.addSubview(row)
        owner.orderFront(nil)
        defer { FamilyMenuPresenter.shared.dismiss(); owner.orderOut(nil) }
        let router = FamilyContextMenus.shared
        func event(_ type: NSEvent.EventType, _ point: NSPoint = NSPoint(x: 220, y: 120), _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                              windowNumber: owner.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        let probe = NativeMenuProbe()
        defer { probe.stop() }
        expect(router.handle(event(.rightMouseDown)) == nil && menuRequests == 1, "right down opens the command row menu and stops routing")
        let menu = probe.menu
        expect(menu != nil, "command context menu is presented")
        expect(router.handle(event(.rightMouseUp)) == nil, "right up must not reach the terminal and replace the command menu")
        expect(menu?.items.first?.title == "Edit command", "native menu retains the row command through tracking")
        FamilyMenuPresenter.shared.dismiss()
        expect(router.handle(event(.rightMouseUp)) != nil, "unpaired terminal right up remains available")
        let controlProbe = NativeMenuProbe()
        defer { controlProbe.stop() }
        expect(router.handle(event(.leftMouseDown, NSPoint(x: 220, y: 120), .control)) == nil, "control click opens the row menu")
        expect(router.handle(event(.leftMouseUp)) == nil, "control release before mouse up must not activate the underlying row")
        FamilyMenuPresenter.shared.dismiss()
        expect(router.handle(event(.rightMouseDown, NSPoint(x: 20, y: 20))) != nil, "right click outside command rows keeps normal terminal routing")
        expect(router.handle(event(.rightMouseUp, NSPoint(x: 20, y: 20))) != nil, "terminal right release is not consumed")
        expect(router.handle(event(.leftMouseDown)) != nil, "normal row selection and dragging keep their mouse down")
        expect(router.handle(event(.leftMouseUp)) != nil, "normal row selection keeps its mouse up")
        print("CHECKED: command context menu owns right/control-click press and release; terminal and normal selection remain available")
    }

    @MainActor static func checkSurface(_ view: NSView, dark: Bool, name: String, elevated: Bool = false) {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // 1x 显示密度时 (20, 20) 会落在标题字形上；顶部中央留白才是背景。
        let pixel = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 8)!
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
            var resolved: NSColor?
            (object as? NSView)?.effectiveAppearance.performAsCurrentDrawingAppearance {
                resolved = color?.usingColorSpace(.sRGB)
            }
            guard let actual = resolved else { expect(false, "\(name): missing native text color"); continue }
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

/// NSMenu tracks synchronously; observe and close it from its tracking run loop.
@MainActor
private final class NativeMenuProbe {
    var menu: NSMenu?
    private var timer: Timer?
    init() {
        timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, let menu = FamilyMenuPresenter.shared.activeMenu else { return }
                self.menu = menu
                menu.cancelTracking()
                timer.invalidate()
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
        RunLoop.main.add(timer!, forMode: .eventTracking)
    }
    func stop() { timer?.invalidate() }
}
