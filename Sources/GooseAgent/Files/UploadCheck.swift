import AppKit
import CryptoKit

/// Before an upload from this Mac to a host: finds text files that are not UTF-8 + LF, asks which
/// to convert, and uploads converted copies from a temporary folder. Local files never change.
enum UploadCheck {
    struct Finding: Sendable {
        var path: String
        /// Shown in the list: the path below the dropped item, starting with its name.
        var display: String
        var encoding: String
        var lineEnding: String
        var inferred: Bool
        var defaultSelected: Bool
        var digest: String
    }

    /// What to upload instead of the dropped items; `staging` is removed by `cleanUp`.
    struct Prepared {
        var items: [FileTransfer.Item]
        var staging: URL?

        func cleanUp() {
            if let staging { try? FileManager.default.removeItem(at: staging) }
        }
    }

    /// Nil means cancel. Downloads and local copies pass through unchanged.
    @MainActor
    static func prepare(_ items: [FileTransfer.Item], from source: any FileSystem, to target: any FileSystem,
                        window: NSWindow?) async throws -> Prepared? {
        guard !source.isRemote, target.isRemote else { return Prepared(items: items, staging: nil) }
        let cancellation = FileOperationContext.cancellation ?? FileOperationCancellation()
        return try await withTaskCancellationHandler {
            let findings = try await Task.detached(priority: .userInitiated) { try scan(items, cancellation: cancellation) }.value
            try cancellation.check()
            guard !findings.isEmpty else { return Prepared(items: items, staging: nil) }
            guard let picked = await ask(findings, in: window, cancellation: cancellation) else { return nil }
            try cancellation.check()
            guard !picked.isEmpty else { return Prepared(items: items, staging: nil) }
            let prepared = try await Task.detached(priority: .userInitiated) {
                try stage(items, converting: picked, findings: findings, cancellation: cancellation)
            }.value
            do { try cancellation.check() }
            catch { prepared.cleanUp(); throw error }
            return prepared
        } onCancel: { cancellation.cancel() }
    }

    static func scan(_ items: [FileTransfer.Item], cancellation: FileOperationCancellation? = nil) throws -> [Finding] {
        var findings: [Finding] = []
        func check(_ path: String, display: String) throws {
            try cancellation?.check()
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return }
            let name = (path as NSString).lastPathComponent
            guard TextFile.mayConvertOnUpload(name: name),
                  let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
                  size > 0, size <= TextFile.uploadConversionLimit,
                  let data = FileManager.default.contents(atPath: path),
                  let decoded = TextFile.uploadConversion(name: name, data: data) else { return }
            findings.append(Finding(
                path: path, display: display,
                encoding: decoded.encoding.label, lineEnding: decoded.lineEnding.label,
                inferred: decoded.isInferred,
                defaultSelected: !decoded.isInferred && !["bat", "cmd", "ps1"].contains((name as NSString).pathExtension.lowercased()),
                digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            ))
        }
        for item in items {
            try cancellation?.check()
            let root = (item.path as NSString).lastPathComponent
            guard item.isDirectory else {
                try check(item.path, display: root)
                continue
            }
            // Relative enumeration preserves the caller's /var or /private/var spelling,
            // so findings still match the original item when staging the selected files.
            guard let walker = FileManager.default.enumerator(atPath: item.path) else { continue }
            for case let relative as String in walker {
                try cancellation?.check()
                let path = FileRules.join(item.path, relative)
                var info = stat()
                guard lstat(path, &info) == 0 else { continue }
                if info.st_mode & S_IFMT == S_IFLNK { walker.skipDescendants(); continue }
                guard info.st_mode & S_IFMT == S_IFREG else { continue }
                try check(path, display: root + "/" + relative)
            }
        }
        return findings
    }

    /// The paths to convert: every checked row. Empty means upload everything as it is.
    @MainActor
    static func ask(_ findings: [Finding], in window: NSWindow?, cancellation: FileOperationCancellation? = nil) async -> Set<String>? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(format: String(localized: "%d text files are not UTF-8 + LF"), findings.count)
        alert.informativeText = String(localized: "Checked files are uploaded as UTF-8 (no BOM) with LF line endings. Files on this Mac are not changed.")

        let boxes = findings.map { finding -> NSButton in
            let title = "\(finding.display)  ·  \(finding.encoding)\(finding.inferred ? " (" + String(localized: "Inferred") + ")" : "") · \(finding.lineEnding)"
            let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            box.state = finding.defaultSelected ? .on : .off
            box.lineBreakMode = .byTruncatingMiddle
            box.toolTip = finding.path
            return box
        }
        let stack = NSStackView(views: boxes)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let width = SheetLayout.uploadCheckListWidth
        let height = min(SheetLayout.uploadCheckListMaxHeight, max(24, stack.fittingSize.height) + 4)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        for box in boxes {
            box.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -4).isActive = true
        }
        alert.accessoryView = scroll

        alert.addButton(withTitle: String(localized: "Convert and Upload"))
        alert.addButton(withTitle: String(localized: "Upload As Is"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        // Queue cancellation must also release a pending confirmation sheet.
        let cancellationTimer = Timer(timeInterval: 0.1, repeats: true) { _ in
            guard cancellation?.isCancelled == true else { return }
            MainActor.assumeIsolated {
                if let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .abort) }
                else if NSApp.modalWindow === alert.window { NSApp.abortModal() }
            }
        }
        RunLoop.main.add(cancellationTimer, forMode: .common)
        RunLoop.main.add(cancellationTimer, forMode: .modalPanel)
        defer { cancellationTimer.invalidate() }
        let response = if let window { await alert.beginSheetModal(for: window) } else { alert.runModal() }
        guard cancellation?.isCancelled != true else { return nil }
        switch response {
        case .alertFirstButtonReturn:
            return Set(zip(findings, boxes).filter { $0.1.state == .on }.map(\.0.path))
        case .alertSecondButtonReturn:
            return []
        default:
            return nil
        }
    }

    /// Items holding a converted file are copied into a temporary folder under the same name and
    /// converted there; the rest upload from where they are.
    static func stage(_ items: [FileTransfer.Item], converting paths: Set<String>, findings: [Finding] = [],
                      cancellation: FileOperationCancellation? = nil) throws -> Prepared {
        let manager = FileManager.default
        try cancellation?.check()
        let staging = manager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ghostty-upload-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var staged: [FileTransfer.Item] = []
        do {
            for item in items {
                try cancellation?.check()
                let prefix = item.path.hasSuffix("/") ? item.path : item.path + "/"
                let inside = paths.filter { $0 == item.path || $0.hasPrefix(prefix) }
                guard !inside.isEmpty else {
                    staged.append(item)
                    continue
                }
                let itemStaging = staging.appendingPathComponent(UUID().uuidString)
                try manager.createDirectory(at: itemStaging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let copy = itemStaging.appendingPathComponent((item.path as NSString).lastPathComponent)
                try copyForStaging(item.path, to: copy.path, cancellation: cancellation)
                for path in inside {
                    try cancellation?.check()
                    let target = path == item.path ? copy.path : copy.path + "/" + path.dropFirst(prefix.count)
                    try requireStagedRegularFile(target, inside: itemStaging)
                    let attributes = try manager.attributesOfItem(atPath: target)
                    guard let size = attributes[.size] as? Int,
                          size <= TextFile.uploadConversionLimit else { throw FileError.message(String(localized: "The file is too large to convert safely")) }
                    let data = try Data(contentsOf: URL(fileURLWithPath: target))
                    guard data.count <= TextFile.uploadConversionLimit,
                          let decoded = TextFile.decode(data) else { throw FileSafety.changed() }
                    if let finding = findings.first(where: { $0.path == path }),
                       finding.digest != SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() {
                        throw FileSafety.changed()
                    }
                    try cancellation?.check()
                    try requireStagedRegularFile(target, inside: itemStaging)
                    try TextFile.utf8LF(decoded.text).write(to: URL(fileURLWithPath: target), options: .atomic)
                    if let mode = attributes[.posixPermissions] {
                        try? manager.setAttributes([.posixPermissions: mode], ofItemAtPath: target)
                    }
                }
                staged.append(FileTransfer.Item(path: copy.path, isDirectory: item.isDirectory))
            }
            try cancellation?.check()
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
        return Prepared(items: staged, staging: staging)
    }

    /// A copied symlink is harmless until conversion follows it. Refuse every symlink between
    /// the private staging root and the file, and require the resolved path to stay inside it.
    private static func requireStagedRegularFile(_ path: String, inside root: URL) throws {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        let prefix = rootPath + "/"
        guard candidate.path.hasPrefix(prefix), candidate.resolvingSymlinksInPath().path.hasPrefix(prefix) else {
            throw FileSafety.changed()
        }
        let parts = candidate.path.dropFirst(prefix.count).split(separator: "/")
        var current = URL(fileURLWithPath: rootPath)
        for (index, part) in parts.enumerated() {
            current.appendPathComponent(String(part))
            var info = stat()
            guard lstat(current.path, &info) == 0,
                  info.st_mode & S_IFMT == (index == parts.count - 1 ? S_IFREG : S_IFDIR) else {
                throw FileSafety.changed()
            }
        }
    }

    /// Copy is a cancellable process, including large directory trees. The source is never modified.
    private static func copyForStaging(_ path: String, to target: String, cancellation: FileOperationCancellation?) throws {
        try cancellation?.check()
        let process = Process(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/cp")
        process.arguments = ["-pRP", path, target]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try cancellation?.register(process)
        defer { cancellation?.unregister(process) }
        try process.run()
        cancellation?.processStarted(process)
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try cancellation?.check()
        guard process.terminationStatus == 0 else {
            throw FileError.message(String(decoding: errorData, as: UTF8.self))
        }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
