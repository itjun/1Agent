import AppKit
import SwiftUI
import ObjectiveC
@testable import GooseAgent

@main enum QuickCommandSidebarTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        Task { @MainActor in
            do { try await run(); print("QuickCommandSidebarTests passed"); exit(0) }
            catch { fputs("QuickCommandSidebarTests failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        NSApp.run()
    }

    @MainActor static func run() async throws {
        if CommandLine.arguments.contains("--fail-assertion") {
            try require(false, "验证断言失败正常退出")
        }
        if CommandLine.arguments.contains("--fail-missing-object") {
            let _: NSView = try unwrap(nil, "验证缺失对象正常退出")
        }
        let home = try unwrap(ProcessInfo.processInfo.environment["ONEAGENT_TEST_HOME"], "缺少隔离测试目录")
        try require(home.hasPrefix("/private/tmp/oneagent-quick-command-sidebar."))
        try require(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath() == URL(fileURLWithPath: home).resolvingSymlinksInPath())
        let suite = "oneagent.command-sidebar.\(UUID())"
        let defaults = try unwrap(UserDefaults(suiteName: suite), "无法创建隔离偏好设置")
        let getter = try unwrap(class_getClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults")))
        let previous = method_getImplementation(getter)
        let block: @convention(block) (AnyObject) -> UserDefaults = { _ in defaults }
        method_setImplementation(getter, imp_implementationWithBlock(block))
        defer { method_setImplementation(getter, previous); defaults.removePersistentDomain(forName: suite) }

        let model = AppModel(), state = model.mainWindow
        TerminalActivity.shared.model = model
        MainWindowManager.shared.show(state, model: model)
        let native = try unwrap(MainWindowManager.shared.window(for: state), "测试主窗口未创建")
        native.contentViewController = nil
        native.contentView = NSView(frame: native.contentLayoutRect)
        defer { MainWindowManager.shared.close(state) }
        try verifyScrolledCursorRegions(in: native)
        // 只挂载真实侧栏，不创建终端视图；脚本另由已有隔离 PTY 检查覆盖。
        model.openLocalTerminal(at: home, placement: .newTab, beside: UUID(), in: state)
        try await eventually { model.tabs.count == 1 }
        let original = try unwrap(model.tabs.first)
        let store = QuickCommandStore.shared
        try require(store.url.resolvingSymlinksInPath().path.hasPrefix(URL(fileURLWithPath: home).resolvingSymlinksInPath().path + "/"))
        var item = QuickCommand(alias: "构建应用", command: "printf '%s\\n' 'sidebar fixture'", scope: .local)
        try store.save(item)
        let second = QuickCommand(alias: "第二条", command: "printf second", scope: .local)
        try store.save(second)
        native.setContentSize(NSSize(width: 260, height: 700))
        func mount(isDark: Bool = false) {
            native.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
            native.contentView = NSHostingView(rootView: QuickCommandSidebar(model: model, window: state, tabID: original.id)
                .environment(\.windowChrome, WindowChrome(isDark: isDark)))
        }
        func capture(_ name: String) throws {
            guard let directory = ProcessInfo.processInfo.environment["ONEAGENT_COMMAND_SIDEBAR_QA_DIR"] else { return }
            let view = try unwrap(native.contentView)
            view.layoutSubtreeIfNeeded()
            let bitmap = try unwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try unwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
        mount()
        native.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await eventually { element("quickCommand." + item.id.uuidString, in: native) != nil }
        try require(element("quickCommands.toolbox.search", in: native) == nil)
        try require(!descendants(try unwrap(native.contentView)).contains { $0 is NSSearchField }, "快捷命令栏没有搜索")
        for id in ["quickCommands.new", "quickCommands.actions", "quickCommands.edit." + item.id.uuidString] {
            try require(element(id, in: native) == nil, "快捷命令栏不提供维护入口")
        }
        try require(!descendants(try unwrap(native.contentView)).contains { $0 is QuickCommandReorderTargetView }, "指令栏不提供拖动排序")
        try await eventually { element("quickCommands.run." + item.id.uuidString, in: native) != nil }
        try require(model.commandSidebars[original.id]?.selectedCommandID == item.id, "首次打开自动选中第一条指令")
        let rowID = "quickCommand." + item.id.uuidString
        let secondRowID = "quickCommand." + second.id.uuidString
        let initialRowHeight = try accessibilityFrame(try requiredElement(rowID, in: native)).height
        let initialSecondFrame = try accessibilityFrame(try requiredElement(secondRowID, in: native))
        try require(press(try requiredElement(secondRowID, in: native)))
        mount()
        try await eventually { element("quickCommands.code." + second.id.uuidString, in: native) != nil }
        try require(model.commandSidebars[original.id]?.selectedCommandID == second.id, "重新打开保留已选指令")
        try require(press(try requiredElement(rowID, in: native)))
        try await eventually { element("quickCommands.code." + item.id.uuidString, in: native) != nil }
        try require(!descendants(try unwrap(native.contentView)).contains { $0 is QuickCommandPreviewAnchorView }, "完整命令在底部，不打开悬浮窗")
        try require(try accessibilityFrame(try requiredElement(rowID, in: native)).height == initialRowHeight, "选择命令不改变行高")
        try require(try accessibilityFrame(try requiredElement(secondRowID, in: native)) == initialSecondFrame, "选择命令不推动其他行")
        try require(element("quickCommands.quickCopy." + item.id.uuidString, in: native) == nil, "列表不重复提供拷贝入口")
        try require(element("quickCommands.quickRun." + item.id.uuidString, in: native) == nil, "列表不重复提供执行入口")
        try await verifySidebarDrag(item.id, sessionID: original.sessionID, in: native)
        try capture("fixture-light")
        try require(model.commandSidebars[original.id]?.selectedCommandID == item.id)
        try require(model.tabs.count == 1 && state.quickCommandConfirmation == nil)
        let shortCommand = item.command
        let codeID = "quickCommands.code." + item.id.uuidString
        let shortHeight = try accessibilityFrame(try requiredElement(codeID, in: native)).height
        item.command = "printf '%s\\n' '" + String(repeating: "long-command-argument-", count: 12) + "'"
        try store.save(item)
        native.setContentSize(NSSize(width: 230, height: 700))
        try await eventually {
            guard let code = element(codeID, in: native) else { return false }
            return try accessibilityFrame(code).height > shortHeight * 3
        }
        let wrappedFrame = try accessibilityFrame(try requiredElement(codeID, in: native))
        try require(wrappedFrame.width <= 230, "长命令换行后不能溢出侧栏")
        let runFrame = try accessibilityFrame(try requiredElement("quickCommands.run." + item.id.uuidString, in: native))
        let previewFrame = try accessibilityFrame(try requiredElement("quickCommands.preview." + original.id.uuidString, in: native))
        try require(runFrame.maxY <= previewFrame.minY, "执行按钮固定在滚动预览下方，不能被长命令挤走")
        try require(try accessibilityFrame(try requiredElement(rowID, in: native)).height == initialRowHeight, "长命令不撑开列表")
        item.command += "\nprintf 'second line'\nprintf 'third line'"
        try store.save(item)
        try await eventually {
            guard let code = element(codeID, in: native) else { return false }
            return try accessibilityFrame(code).height > wrappedFrame.height
        }
        try capture("fixture-narrow-long")
        mount(isDark: true)
        try await eventually { element(codeID, in: native) != nil }
        try capture("fixture-dark")
        mount()
        item.command = shortCommand
        try store.save(item)
        native.setContentSize(NSSize(width: 260, height: 700))
        try await eventually { try accessibilityFrame(try requiredElement(codeID, in: native)).height <= shortHeight + 1 }
        print("PASS fixed command rows, stable selection, wrapped and scrollable preview with pinned actions")
        model.commandSidebars[original.id]?.isExpanded = true
        try await eventually { element("quickCommand." + second.id.uuidString, in: native) != nil }
        let terminal = SSHTerminalNSView(frame: .zero)
        terminal.sessionID = original.sessionID
        (try unwrap(native.contentView)).addSubview(terminal)
        native.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        native.makeFirstResponder(terminal)
        try await eventually { native.isKeyWindow && native.firstResponder === terminal }
        func key(_ code: UInt16, repeatKey: Bool = false) throws {
            let character: String
            switch code {
            case 36, 76: character = "\r"
            case 125: character = "\u{f701}"
            case 126: character = "\u{f700}"
            case 53: character = "\u{1b}"
            default: character = ""
            }
            let event = try unwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: native.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character,
                isARepeat: repeatKey, keyCode: code))
            NSApp.sendEvent(event)
        }
        try key(36)
        guard !model.commandExecution(for: original.id).isSubmitting else {
            throw NSError(domain: "QuickCommandSidebarTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "终端持有焦点时，Enter 被命令侧栏截获并触发了执行"])
        }
        try key(76)
        try key(125)
        try require(model.commandSidebars[original.id]?.selectedCommandID == item.id, "终端下方向键不切换侧栏命令")
        try key(126)
        try require(model.commandSidebars[original.id]?.selectedCommandID == item.id, "终端上方向键不切换侧栏命令")
        try key(53)
        try require(!model.commandExecution(for: original.id).isSubmitting, "终端回车不执行侧栏命令")
        try require(model.commandSidebars[original.id]?.isExpanded == true, "终端 Esc 不收起侧栏")
        try require(native.firstResponder === terminal, "侧栏展开不能抢走终端焦点")
        try require(press(try requiredElement(rowID, in: native)))
        try await eventually { native.firstResponder !== terminal }
        try key(125)
        try await eventually { model.commandSidebars[original.id]?.selectedCommandID == second.id }
        try key(126)
        try await eventually { model.commandSidebars[original.id]?.selectedCommandID == item.id }
        try key(126)
        try require(model.commandSidebars[original.id]?.selectedCommandID == item.id, "首项向上不越界")
        let keyboardExecution = model.commandExecution(for: original.id)
        try key(36, repeatKey: true)
        try require(!keyboardExecution.isSubmitting, "长按回车不执行")
        try key(36)
        try require(!keyboardExecution.isSubmitting, "选中侧栏命令后回车也不执行")
        try key(76)
        try require(!keyboardExecution.isSubmitting, "侧栏小键盘回车不执行")
        try key(36)
        try require(!keyboardExecution.isSubmitting && keyboardExecution.error == nil, "连续回车不发起侧栏命令")
        try key(53)
        try require(model.commandSidebars[original.id]?.isExpanded == false, "Esc 收起当前终端的命令栏")
        model.commandSidebars[original.id]?.isExpanded = true
        let editor = NSTextView(frame: (try unwrap(native.contentView)).bounds)
        (try unwrap(native.contentView)).addSubview(editor)
        native.makeFirstResponder(editor)
        try key(125)
        try require(model.commandSidebars[original.id]?.selectedCommandID == item.id, "文本编辑器不被拦截")
        editor.removeFromSuperview()
        terminal.removeFromSuperview()
        try store.remove(second.id)
        keyboardExecution.error = nil
        print("PASS terminal key isolation, focused-list navigation, no sidebar execution on Enter/keypad/repeat and editor isolation")
        let pasteboard = NSPasteboard.general
        let previousClipboard = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(previousClipboard.map { entries in
                let item = NSPasteboardItem()
                entries.forEach { item.setData($0.1, forType: $0.0) }
                return item
            })
        }
        try require(press(try requiredElement("quickCommands.copy." + item.id.uuidString, in: native)))
        try require(pasteboard.string(forType: .string) == item.command)
        mount()
        try await eventually { element("quickCommands.run." + item.id.uuidString, in: native) != nil }
        print("PASS no search, footer preview, a single copy entry and selection survives remount")

        model.openLocalTerminal(at: "/private/tmp", placement: .newTab, beside: original.id, in: state)
        try await eventually { model.tabs.count == 2 }
        let sibling = try unwrap(model.tabs.first { $0.id != original.id })
        model.selectOnly(sibling.id, in: state, focusTerminal: false)
        let originalExecution = model.commandExecution(for: original.id)
        try require(press(try requiredElement("quickCommands.run." + item.id.uuidString, in: native)))
        try require(originalExecution.isSubmitting)
        try require(!model.commandExecution(for: sibling.id).isSubmitting, "兄弟终端不显示执行状态")
        try require(!press(try requiredElement("quickCommands.run." + item.id.uuidString, in: native)), "提交期间执行入口禁用")
        try require(!model.runSidebarQuickCommand(item.id, in: state, targetTabID: original.id), "按钮与拖拽共享同一终端的提交守卫")
        try await eventually { !originalExecution.isSubmitting }
        try require(originalExecution.error != nil, "没有 shell 的目标必须明确报错")
        try await eventually { element("quickCommands.error." + original.id.uuidString, in: native) != nil }
        try require(state.selectedTabID == sibling.id && model.tabs.count == 2, "失败不能切到其他终端或新建终端")
        try await eventually { press(try requiredElement("quickCommands.run." + item.id.uuidString, in: native)) }
        try require(originalExecution.isSubmitting)
        try await eventually { !originalExecution.isSubmitting }
        print("PASS per-terminal execution guard, failure feedback and explicit retry")

        // 维护只在左侧“命令”工作区进行，保存后重新挂载使用栏应看到更新。
        state.section = .commands
        state.commandLibraryCollection = .local
        state.commandLibrarySelection = item.id
        native.setContentSize(NSSize(width: 1000, height: 760))
        native.contentView = NSHostingView(rootView: QuickCommandLibraryView(model: model, window: state, isWorkspace: true, onClose: {})
            .environment(\.windowChrome, WindowChrome(isDark: false)))
        try await eventually { element("quickCommands.library.edit", in: native) != nil }
        try await verifyLibraryKeyboard(item: item, state: state, in: native)
        try require(press(try requiredElement("quickCommands.library.edit", in: native)))
        try await eventually { element("quickCommand.script", in: native) != nil }
        try require(native.attachedSheet == nil, "在命令工作区内编辑")
        let script = try unwrap(element("quickCommand.script", in: native) as? NSTextView, "脚本编辑器不存在")
        native.makeFirstResponder(script)
        try key(125)
        try require(state.commandLibrarySelection == item.id, "编辑指令时方向键不切换列表")
        script.string = "printf edited"
        script.didChangeText()
        try require(press(try requiredElement("quickCommand.save", in: native)))
        try await eventually { state.commandLibraryDraft == nil && store.commands.first { $0.id == item.id }?.command == "printf edited" }
        try await eventually { element("quickCommands.library.edit", in: native) != nil }
        try require(press(try requiredElement("quickCommands.library.edit", in: native)))
        try await eventually { element("quickCommand.cancel", in: native) != nil }
        try require(press(try requiredElement("quickCommand.cancel", in: native)))
        try await eventually { state.commandLibraryDraft == nil }
        state.section = .terminals
        native.setContentSize(NSSize(width: 260, height: 700))
        mount()
        try await eventually { element("quickCommands.code." + item.id.uuidString, in: native) != nil }
        try require(element("quickCommands.edit." + item.id.uuidString, in: native) == nil)
        try require(press(try requiredElement("quickCommands.copy." + item.id.uuidString, in: native)))
        try require(pasteboard.string(forType: .string) == "printf edited", "命令管理保存后使用栏显示新内容")
        let reviewedContext = model.commandContext(in: state, targetTabID: original.id)
        try require(!model.runSidebarQuickCommand(item.id, in: state, expectedContext: reviewedContext,
                                                 expectedItem: item, targetTabID: original.id), "编辑后旧命令快照被拒绝")
        item = try unwrap(store.commands.first { $0.id == item.id })
        try store.remove(item.id)
        try await eventually { element("quickCommands.run." + item.id.uuidString, in: native) == nil }
        try require(!model.runSidebarQuickCommand(item.id, in: state, targetTabID: original.id))
        print("PASS management-page editing, live sidebar refresh, stale content and deleted-command rejection")

        let execution = QuickCommandSidebarExecution()
        let request = try QuickCommandRunRequest(item: item, context: QuickCommandContext(directory: home), directory: home)
        var deliveries = 0
        execution.run(request, perform: { _ in
            deliveries += 1
            try await Task.sleep(for: .milliseconds(650))
            throw QuickCommandError.unavailable
        })
        execution.run(request, perform: { _ in deliveries += 1 })
        try await Task.sleep(for: .milliseconds(550))
        try require(execution.isSubmitting && deliveries == 1, "Slow operations remain guarded beyond double-click interval")
        try await eventually { !execution.isSubmitting }
        try require(execution.error != nil)
        execution.run(request, perform: { _ in deliveries += 1 })
        try await eventually { !execution.isSubmitting }
        try require(deliveries == 2 && execution.error == nil)
        print("PASS slow submission guard, failure feedback and recovery")
    }

    @MainActor static func verifyLibraryKeyboard(item: QuickCommand, state: WindowState, in window: NSWindow) async throws {
        let store = QuickCommandStore.shared
        let additions = (0..<15).map { index in
            var command = QuickCommand(alias: "键盘候选 \(index)", command: "printf keyboard-\(index)", scope: .local)
            command.order = 100 + index
            return command
        }
        for command in additions { try store.save(command) }
        let ordered = store.commands.filter { $0.scope == .local }.sorted(by: QuickCommand.displayOrder)
        try require(ordered.count >= 2, "键盘测试至少需要两条命令")
        func arrow(_ isDown: Bool, modifiers: NSEvent.ModifierFlags = []) throws {
            let character = isDown ? "\u{f701}" : "\u{f700}"
            NSApp.sendEvent(try unwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: isDown ? 125 : 126)))
        }
        try require(press(try requiredElement("quickCommand." + item.id.uuidString, in: window)))
        try await Task.sleep(for: .milliseconds(100))
        try arrow(true)
        try await eventually { state.commandLibrarySelection == ordered[1].id }
        try await eventually {
            guard let copy = element("quickCommands.library.copy", in: window), press(copy) else { return false }
            return NSPasteboard.general.string(forType: .string) == ordered[1].command
        }
        try arrow(false)
        try await eventually { state.commandLibrarySelection == item.id }
        try arrow(false)
        try require(state.commandLibrarySelection == item.id, "首项向上停住")
        for command in ordered.dropFirst() {
            try arrow(true)
            try await eventually { state.commandLibrarySelection == command.id }
        }
        try arrow(true)
        try require(state.commandLibrarySelection == (try unwrap(ordered.last)).id, "末项向下停住")
        try await eventually {
            guard let row = element("quickCommand." + (try unwrap(ordered.last)).id.uuidString, in: window) else { return false }
            return window.convertToScreen(window.contentLayoutRect).contains(try accessibilityFrame(row))
        }
        let search = try unwrap(descendants(try unwrap(window.contentView)).compactMap { $0 as? NSSearchField }.first)
        search.selectText(nil)
        let editor = try unwrap(search.currentEditor() as? NSTextView, "搜索编辑器不存在")
        func searchFor(_ query: String) {
            editor.insertText(query, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        }
        searchFor("keyboard-1")
        let filtered = ordered.filter { $0.matchesSearch("keyboard-1") }
        try require(filtered.count >= 2, "搜索测试至少需要两个结果")
        try await eventually { state.commandLibrarySelection == filtered.last?.id }
        try arrow(false)
        try await eventually { state.commandLibrarySelection == filtered[filtered.count - 2].id }
        try require(window.firstResponder === editor, "搜索框用方向键选择后仍可继续输入")
        let beforeMarkedText = state.commandLibrarySelection
        editor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let handled = search.delegate?.control?(search, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
        try require(handled != true && state.commandLibrarySelection == beforeMarkedText, "中文输入法组词时不切换指令")
        editor.unmarkText()
        searchFor("no-matching-command")
        try await eventually { state.commandLibrarySelection == nil }
        try arrow(true)
        try arrow(false)
        try require(state.commandLibrarySelection == nil, "空结果不产生选择")
        searchFor("")
        try await eventually { state.commandLibrarySelection == item.id }
        for command in additions { try store.remove(command.id) }
        print("PASS library arrow selection, preview synchronization, boundaries, scrolling, filtered search and IME isolation")
    }

    @MainActor static func verifySidebarDrag(_ commandID: UUID, sessionID: String, in window: NSWindow) async throws {
        let visibleFrame = try unwrap(window.screen ?? NSScreen.main, "没有可用屏幕").visibleFrame
        let destinationWindow = NSPanel(contentRect: NSRect(x: visibleFrame.maxX - 280, y: visibleFrame.minY + 40, width: 260, height: 150),
                                        styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        destinationWindow.isReleasedWhenClosed = false
        destinationWindow.level = .floating
        // 合成事件不需要键盘焦点；切换到其他应用也不能让拖拽目标消失。
        destinationWindow.hidesOnDeactivate = false
        let terminal = SSHTerminalNSView(frame: NSRect(x: 0, y: 0, width: 260, height: 150))
        terminal.sessionID = sessionID
        var deliveries: [UUID] = []
        terminal.canDropQuickCommand = { $0 == commandID }
        terminal.onQuickCommandDrop = { id in
            if !CommandLine.arguments.contains("--fail-drag-delivery") { deliveries.append(id) }
            return true
        }
        destinationWindow.contentView = terminal
        defer {
            destinationWindow.close()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        if CommandLine.arguments.contains("--background-drag") {
            try await eventually("测试应用尚未完成初始激活") { NSApp.isActive }
            let finder = try unwrap(NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" },
                                    "后台拖拽回归测试需要 Finder 正在运行")
            try require(finder.activate(), "无法将焦点切换到 Finder")
            try await eventually("后台拖拽回归测试未进入非激活状态") { !NSApp.isActive }
        }
        destinationWindow.orderFrontRegardless()
        let screenPoint = destinationWindow.convertPoint(toScreen: NSPoint(x: 80, y: 50))
        try await eventually("拖拽目标未命中：visible=\(destinationWindow.isVisible)，active=\(NSApp.isActive)，落点窗口=\(String(describing: QuickCommandDragHandleView.dropDestination(at: screenPoint)?.window))") {
            destinationWindow.isVisible
                && QuickCommandDragHandleView.dropDestination(at: screenPoint)?.window === destinationWindow
        }
        try require(terminal.acceptsQuickCommand(commandID), "拖拽目标必须是可见终端")
        let content = try unwrap(window.contentView)
        var start = NSPoint.zero
        var dragHandle: QuickCommandDragHandleView?
        // AX 元素存在不代表 SwiftUI 的原生覆盖层已完成布局，等待真实命中而非固定延迟。
        try await eventually("指令行布局或拖拽层未就绪，命令=\(commandID)") {
            content.layoutSubtreeIfNeeded()
            guard let handle = descendants(content).compactMap({ $0 as? QuickCommandDragHandleView })
                .first(where: { $0.commandID == commandID }) else { return false }
            let visible = handle.bounds.intersection(handle.visibleRect)
            guard !visible.isEmpty, handle.window === window else { return false }
            start = handle.convert(NSPoint(x: visible.midX, y: visible.midY), to: nil)
            let hitPoint = content.superview?.convert(start, from: nil) ?? start
            guard content.hitTest(hitPoint) === handle else { return false }
            dragHandle = handle
            return true
        }
        let handle = try unwrap(dragHandle, "指令拖拽层不存在")
        let destination = window.convertPoint(fromScreen: screenPoint)
        try require(QuickCommandDragHandleView.dropDestination(at: screenPoint)?.window === destinationWindow,
                    "拖拽开始前目标窗口被遮挡")
        func mouse(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
            try unwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        NSApp.postEvent(try mouse(.leftMouseUp, at: destination), atStart: true)
        NSApp.postEvent(try mouse(.leftMouseDragged, at: destination), atStart: true)
        handle.mouseDown(with: try mouse(.leftMouseDown, at: start))
        try require(deliveries == [commandID], "真实指令行拖入终端只投递一次")
        let escape = try unwrap(NSEvent.keyEvent(with: .keyDown, location: destination, modifierFlags: [], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                     isARepeat: false, keyCode: 53))
        NSApp.postEvent(escape, atStart: true)
        NSApp.postEvent(try mouse(.leftMouseDragged, at: destination), atStart: true)
        handle.mouseDown(with: try mouse(.leftMouseDown, at: start))
        try require(deliveries == [commandID], "Esc 取消拖拽不执行")
        if CommandLine.arguments.contains("--background-drag") {
            try require(!NSApp.isActive && !destinationWindow.isKeyWindow, "后台拖拽不依赖激活应用或键盘焦点")
            print("PASS background drag without application activation or key window")
        }
        print("PASS production sidebar drag delivery and Escape cancellation")
    }

    @MainActor static func verifyScrolledCursorRegions(in window: NSWindow) throws {
        let clip = NSClipView(frame: NSRect(x: 0, y: 0, width: 260, height: 60))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        clip.documentView = document
        (try unwrap(window.contentView)).addSubview(clip)
        defer { clip.removeFromSuperview() }
        let controls: [NSView] = [TabDragHandleView(), QuickCommandDragHandleView(),
            FileTabHandleView(), PinnedLocationDragHandleView(), ClickableCursorView(), FamilyNativeButton()]
        for control in controls {
            control.frame = NSRect(x: 0, y: 0, width: 260, height: 40)
            document.addSubview(control)
        }
        for origin in [NSPoint(x: 0, y: 200), .zero, NSPoint(x: 0, y: 200)] {
            clip.scroll(to: origin)
            for control in controls {
                try require(control.bounds.intersection(control.visibleRect).isEmpty == (origin.y > 0))
                // 直接调用真实 AppKit 路径；回归时无效矩形会抛异常并使测试进程退出。
                control.resetCursorRects()
            }
        }
        print("PASS native cursor regions survive scroll out, return and repeated clipping")
    }

    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func value(_ element: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        return element.responds(to: selector) ? element.perform(selector)?.takeUnretainedValue() : nil
    }
    @MainActor static func element(_ id: String, in root: NSObject) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func find(_ object: NSObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            if value(object, "accessibilityIdentifier") as? String == id { return object }
            for child in value(object, "accessibilityChildren") as? [NSObject] ?? [] {
                if let match = find(child) { return match }
            }
            return nil
        }
        return find(root)
    }
    @MainActor static func accessibilityFrame(_ object: NSObject) throws -> CGRect {
        let selector = NSSelectorFromString("accessibilityFrame")
        try require(object.responds(to: selector), "界面元素不支持 accessibilityFrame")
        typealias Frame = @convention(c) (AnyObject, Selector) -> CGRect
        return unsafeBitCast(object.method(for: selector), to: Frame.self)(object, selector)
    }
    @MainActor static func press(_ object: NSObject) -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector)
    }
    static func unwrap<T>(_ value: T?, _ message: String = "缺少测试所需对象",
                          file: StaticString = #filePath, line: UInt = #line) throws -> T {
        guard let value else {
            throw NSError(domain: "QuickCommandSidebarTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "\(file):\(line): \(message)"])
        }
        return value
    }

    @MainActor static func requiredElement(_ id: String, in root: NSObject,
                                           file: StaticString = #filePath, line: UInt = #line) throws -> NSObject {
        try unwrap(element(id, in: root), "找不到界面元素 \(id)", file: file, line: line)
    }

    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String = "测试条件不成立",
                        file: StaticString = #filePath, line: UInt = #line) throws {
        guard try condition() else {
            throw NSError(domain: "QuickCommandSidebarTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "\(file):\(line): \(message)"])
        }
    }

    @MainActor static func eventually(_ message: @autoclosure () -> String = "等待测试状态超时", line: Int = #line, _ condition: () throws -> Bool) async throws {
        for _ in 0..<150 {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "QuickCommandSidebarTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(#filePath):\(line): \(message())"])
    }
}
