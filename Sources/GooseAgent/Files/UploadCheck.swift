import AppKit

/// Before an upload from this Mac to a host: finds text files that are not UTF-8 + LF, asks which
/// to convert, and uploads converted copies from a temporary folder. Local files never change.
enum UploadCheck {
    struct Finding: Sendable {
        var path: String
        /// Shown in the list: the path below the dropped item, starting with its name.
        var display: String
        var encoding: String
        var lineEnding: String
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
        let findings = await Task.detached(priority: .userInitiated) { scan(items) }.value
        guard !findings.isEmpty else { return Prepared(items: items, staging: nil) }
        guard let picked = await ask(findings, in: window) else { return nil }
        guard !picked.isEmpty else { return Prepared(items: items, staging: nil) }
        return try await Task.detached(priority: .userInitiated) { try stage(items, converting: picked) }.value
    }

    static func scan(_ items: [FileTransfer.Item]) -> [Finding] {
        var findings: [Finding] = []
        func check(_ path: String, display: String) {
            let name = (path as NSString).lastPathComponent
            guard TextFile.mayConvertOnUpload(name: name),
                  let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
                  size > 0, size <= TextFile.uploadConversionLimit,
                  let data = FileManager.default.contents(atPath: path),
                  let decoded = TextFile.uploadConversion(name: name, data: data) else { return }
            findings.append(Finding(
                path: path, display: display,
                encoding: decoded.encoding.label, lineEnding: decoded.lineEnding.label
            ))
        }
        for item in items {
            let root = (item.path as NSString).lastPathComponent
            guard item.isDirectory else {
                check(item.path, display: root)
                continue
            }
            let base = URL(fileURLWithPath: item.path)
            guard let walker = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ) else { continue }
            for case let url as URL in walker {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
                let relative = String(url.path.dropFirst(base.path.count)).trimmingCharacters(in: ["/"])
                check(url.path, display: root + "/" + relative)
            }
        }
        return findings
    }

    /// The paths to convert: every checked row. Empty means upload everything as it is.
    @MainActor
    static func ask(_ findings: [Finding], in window: NSWindow?) async -> Set<String>? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(format: String(localized: "%d text files are not UTF-8 + LF"), findings.count)
        alert.informativeText = String(localized: "Checked files are uploaded as UTF-8 (no BOM) with LF line endings. Files on this Mac are not changed.")

        let boxes = findings.map { finding -> NSButton in
            let title = "\(finding.display)  ·  \(finding.encoding) · \(finding.lineEnding)"
            let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            box.state = .on
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
        let response = if let window { await alert.beginSheetModal(for: window) } else { alert.runModal() }
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
    static func stage(_ items: [FileTransfer.Item], converting paths: Set<String>) throws -> Prepared {
        let manager = FileManager.default
        let staging = manager.temporaryDirectory.appendingPathComponent("ghostty-upload-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        var staged: [FileTransfer.Item] = []
        do {
            for item in items {
                let prefix = item.path.hasSuffix("/") ? item.path : item.path + "/"
                let inside = paths.filter { $0 == item.path || $0.hasPrefix(prefix) }
                guard !inside.isEmpty else {
                    staged.append(item)
                    continue
                }
                let copy = staging.appendingPathComponent((item.path as NSString).lastPathComponent)
                if item.isDirectory {
                    try manager.copyItem(atPath: item.path, toPath: copy.path)
                }
                for path in inside {
                    let target = path == item.path ? copy.path : copy.path + "/" + path.dropFirst(prefix.count)
                    guard let data = manager.contents(atPath: path), let decoded = TextFile.decode(data) else { continue }
                    try? manager.removeItem(atPath: target)
                    try TextFile.utf8LF(decoded.text).write(to: URL(fileURLWithPath: target))
                    if let mode = (try? manager.attributesOfItem(atPath: path))?[.posixPermissions] {
                        try? manager.setAttributes([.posixPermissions: mode], ofItemAtPath: target)
                    }
                }
                staged.append(FileTransfer.Item(path: copy.path, isDirectory: item.isDirectory))
            }
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
        return Prepared(items: staged, staging: staging)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
