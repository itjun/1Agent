import AppKit

/// 外部应用只接收本机路径；远程目录绝不冒充同名本机目录。
@MainActor
enum WorkspaceExternalOpen {
    static func items(location: GitLocation, repositoryRoot: String?, repositoryURL: URL?) -> [FamilyMenuItem] {
        var items: [FamilyMenuItem] = []
        if location.host == nil {
            let directory = URL(fileURLWithPath: location.directory, isDirectory: true)
            items.append(FamilyMenuItem(title: String(localized: "Open in Finder"), image: WorkspaceExternalOpen.applicationIcon(at: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")), action: {
                NSWorkspace.shared.open([directory], withApplicationAt: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"), configuration: .init()) { _, error in
                    WorkspaceExternalOpen.show(error)
                }
            }))
            items.append(.separator)
            let applications = [("Visual Studio Code", "com.microsoft.VSCode", false),
                                ("Zed", "dev.zed.Zed", false),
                                ("Cursor", "com.todesktop.230313mzl4w4u92", false),
                                ("Xcode", "com.apple.dt.Xcode", false),
                                ("GitHub Desktop", "com.github.GitHubClient", true),
                                ("Sourcetree", "com.torusknot.SourceTreeNotMAS", true),
                                ("Fork", "com.DanPristupov.Fork", true),
                                ("Tower", "com.fournova.Tower3", true)]
            for (name, bundleID, isGitClient) in applications {
                guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { continue }
                let path = isGitClient ? repositoryRoot : location.directory
                items.append(FamilyMenuItem(title: name, image: WorkspaceExternalOpen.applicationIcon(at: app), enabled: path != nil, action: {
                    guard let path else { return }
                    if bundleID == "com.github.GitHubClient" {
                        WorkspaceExternalOpen.openGitHubDesktop(directory: URL(fileURLWithPath: path, isDirectory: true), app: app)
                    } else {
                        WorkspaceExternalOpen.open(URL(fileURLWithPath: path, isDirectory: true), with: app)
                    }
                }))
            }
            items.append(FamilyMenuItem(title: String(localized: "Choose Application…"), action: {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.application]
                panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.begin { response in
                    guard response == .OK, let app = panel.url else { return }
                    WorkspaceExternalOpen.open(directory, with: app)
                }
            }))
            items.append(.separator)
        } else {
            items.append(FamilyMenuItem(title: String(localized: "Desktop apps require a local folder."), enabled: false))
        }
        items.append(FamilyMenuItem(title: String(localized: "Open Repository in Browser"), enabled: repositoryURL != nil, action: {
            guard let repositoryURL else { return }
            if !NSWorkspace.shared.open(repositoryURL) {
                WorkspaceExternalOpen.show(FileError.message(String(localized: "Unable to open repository URL.")))
            }
        }))
        items.append(FamilyMenuItem(title: String(localized: "Copy Path"), action: {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(location.directory, forType: .string)
        }))
        return items
    }

    static func openGitHubDesktop(directory: URL, app: URL) {
        Task {
            do {
                let root = try await WorkspaceExternalOpen.repositoryRoot(in: directory)
                // 应用随附的 CLI 支持已有实例；参数数组保留空格等路径字符。
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [app.appendingPathComponent("Contents/Resources/app/static/github.sh").path, root]
                let result = try await ProcessRunner.run(process, outputLimit: 64 * 1024)
                if result.status != 0 { throw ProcessRunner.failure(result) }
            } catch { WorkspaceExternalOpen.show(error) }
        }
    }

    static func repositoryRoot(in directory: URL) async throws -> String {
        try await WorkspaceGit.checked(["rev-parse", "--show-toplevel"],
            at: GitLocation(host: nil, directory: directory.path)).trimmingCharacters(in: .newlines)
    }

    private static func open(_ directory: URL, with app: URL) {
        NSWorkspace.shared.open([directory], withApplicationAt: app, configuration: .init()) { _, error in
            WorkspaceExternalOpen.show(error)
        }
    }

    static func applicationIcon(at app: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: app.path).copy() as! NSImage
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    nonisolated private static func show(_ error: Error?) {
        guard let error else { return }
        DispatchQueue.main.async { AppNotifications.show(title: String(localized: "Unable to Open Application"), message: error.localizedDescription, level: .error) }
    }

    /// 仅转换网络 Git 地址；移除凭据、查询和片段，不打开 file/自定义协议。
    nonisolated static func repositoryWebURL(_ remote: String) -> URL? {
        let value = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        var source = value
        if !value.contains("://") {
            guard let at = value.firstIndex(of: "@"), let colon = value[at...].firstIndex(of: ":") else { return nil }
            source = "ssh://" + value[..<colon] + "/" + value[value.index(after: colon)...]
        }
        guard var components = URLComponents(string: source),
              let scheme = components.scheme?.lowercased(), ["https", "http", "ssh", "git"].contains(scheme),
              let host = components.host, !host.isEmpty, components.path.count > 1 else { return nil }
        if scheme == "ssh" || scheme == "git" { components.port = nil }
        components.scheme = scheme == "http" ? "http" : "https"
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        if components.path.hasSuffix(".git") { components.path.removeLast(4) }
        return components.url
    }
}
