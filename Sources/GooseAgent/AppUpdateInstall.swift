import Foundation

/// 替换正在运行的 .app：同目录改名交换，目录不可写时请求管理员授权。
enum AppUpdateInstall {
    private static let stagingPrefix = ".1agent-update-"

    static func currentBundle() -> Result<String, AppUpdateFailure> {
        let path = Bundle.main.bundlePath
        if path.hasSuffix(".app") { return .success(path) }
        return .failure(.notAnApp)
    }

    static func cleanup() {
        guard case .success(let bundle) = currentBundle() else { return }
        try? FileManager.default.removeItem(atPath: bundle + ".old")
        let parent = (bundle as NSString).deletingLastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent) else { return }
        for name in names where name.hasPrefix(stagingPrefix) {
            try? FileManager.default.removeItem(atPath: (parent as NSString).appendingPathComponent(name))
        }
    }

    static func apply(archive: String) -> Result<String, AppUpdateFailure> {
        guard case .success(let bundle) = currentBundle() else { return .failure(.notAnApp) }
        let parent = (bundle as NSString).deletingLastPathComponent
        let staging = (parent as NSString).appendingPathComponent(stagingPrefix + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)
        } catch {
            if isPermission(error) { return applyPrivileged(archive: archive, bundle: bundle) }
            return .failure(.extractFailed)
        }
        defer { try? FileManager.default.removeItem(atPath: staging) }
        switch extractApp(archive: archive, directory: staging) {
        case .failure(let error):
            return .failure(error)
        case .success(let newApp):
            switch swap(target: bundle, replacement: newApp) {
            case .success:
                return .success(bundle)
            case .failure(let error):
                if error == .replaceFailed && isParentUnwritable(parent) {
                    return applyPrivileged(archive: archive, bundle: bundle)
                }
                return .failure(error)
            }
        }
    }

    private static func extractApp(archive: String, directory: String) -> Result<String, AppUpdateFailure> {
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive, directory]
        let pipe = Pipe()
        ditto.standardError = pipe
        do {
            try ditto.run()
        } catch {
            return .failure(.extractFailed)
        }
        ditto.waitUntilExit()
        if ditto.terminationStatus != 0 { return .failure(.extractFailed) }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return .failure(.extractFailed)
        }
        for name in names where name.hasSuffix(".app") {
            let app = (directory as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            let macos = (app as NSString).appendingPathComponent("Contents/MacOS")
            if FileManager.default.fileExists(atPath: macos, isDirectory: &isDirectory), isDirectory.boolValue {
                let xattr = Process()
                xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                xattr.arguments = ["-dr", "com.apple.quarantine", app]
                try? xattr.run()
                xattr.waitUntilExit()
                return .success(app)
            }
            return .failure(.incompleteApp)
        }
        return .failure(.noAppInArchive)
    }

    private static func swap(target: String, replacement: String) -> Result<Void, AppUpdateFailure> {
        let backup = target + ".old"
        try? FileManager.default.removeItem(atPath: backup)
        do {
            try FileManager.default.moveItem(atPath: target, toPath: backup)
        } catch {
            if isPermission(error) { return .failure(.replaceFailed) }
            return .failure(.replaceFailed)
        }
        do {
            try FileManager.default.moveItem(atPath: replacement, toPath: target)
        } catch {
            do {
                try FileManager.default.moveItem(atPath: backup, toPath: target)
            } catch {
                return .failure(.replaceFailed)
            }
            return .failure(.replaceFailed)
        }
        return .success(())
    }

    private static func applyPrivileged(archive: String, bundle: String) -> Result<String, AppUpdateFailure> {
        let staging = (NSTemporaryDirectory() as NSString).appendingPathComponent(stagingPrefix + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)
        } catch {
            return .failure(.extractFailed)
        }
        defer { try? FileManager.default.removeItem(atPath: staging) }
        let newApp: String
        switch extractApp(archive: archive, directory: staging) {
        case .success(let path): newApp = path
        case .failure(let error): return .failure(error)
        }
        let lines = [
            "on run argv",
            "set src to item 1 of argv",
            "set dst to item 2 of argv",
            "set bak to dst & \".old\"",
            "do shell script \"/bin/rm -rf \" & quoted form of bak & \" && /bin/mv \" & quoted form of dst & \" \" & quoted form of bak & \" && { /bin/mv \" & quoted form of src & \" \" & quoted form of dst & \" || { /bin/mv \" & quoted form of bak & \" \" & quoted form of dst & \"; exit 1; }; }\" with administrator privileges",
            "end run",
        ]
        var arguments: [String] = []
        for line in lines {
            arguments.append("-e")
            arguments.append(line)
        }
        arguments.append(newApp)
        arguments.append(bundle)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            return .failure(.adminFailed)
        }
        process.waitUntilExit()
        if process.terminationStatus == 0 { return .success(bundle) }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if output.contains("-128") { return .failure(.cancelledAdmin) }
        return .failure(.adminFailed)
    }

    private static func isPermission(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(EACCES) { return true }
        if ns.code == NSFileWriteNoPermissionError { return true }
        return false
    }

    private static func isParentUnwritable(_ parent: String) -> Bool {
        FileManager.default.isWritableFile(atPath: parent) == false
    }
}
