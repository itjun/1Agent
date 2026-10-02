import Foundation

/// The operations of one file pane column: 1Panel's local and SFTP browser calls.
protocol FileSystem: Sendable {
    /// Nil for this Mac.
    var host: String? { get }
    func home() async throws -> String
    /// Folders first, then by name, hidden files included.
    func list(_ directory: String) async throws -> [FileEntry]
    func existingNames(in directory: String, among names: [String]) async throws -> Set<String>
    func makeDirectory(_ path: String) async throws
    /// Fails when the name is taken; never truncates a file.
    func createFile(_ path: String) async throws
    func delete(_ paths: [String]) async throws
    /// At most `limit` bytes from the start of the file.
    func read(_ path: String, limit: Int) async throws -> Data
    func write(_ data: Data, to path: String) async throws
    func copy(_ path: String, to target: String) async throws
    /// Each folder with links resolved; a folder that cannot be resolved stays as given.
    func resolveFolders(_ paths: [String]) async -> [String]
}

extension FileSystem {
    var isRemote: Bool { host != nil }

    static func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

func fileSystem(for host: String?) -> any FileSystem {
    if let host, !host.isEmpty { return RemoteFileSystem(alias: host) }
    return LocalFileSystem()
}

struct LocalFileSystem: FileSystem {
    var host: String? { nil }

    func home() async throws -> String { NSHomeDirectory() }

    func list(_ directory: String) async throws -> [FileEntry] {
        try await Task.detached(priority: .userInitiated) {
            let url = URL(fileURLWithPath: directory)
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            let urls: [URL]
            do {
                urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)
            } catch {
                throw FileError.message(error.localizedDescription)
            }
            let entries = urls.map { item -> FileEntry in
                let values = try? item.resourceValues(forKeys: Set(keys))
                // attributesOfItem on ~/Downloads, ~/Documents or ~/Desktop triggers macOS's folder
                // access prompt; lstat does not.
                var info = stat()
                let permissions = lstat(item.path, &info) == 0 ? UInt16(info.st_mode & 0o7777) : 0
                let isDirectory = values?.isDirectory ?? false
                return FileEntry(
                    name: item.lastPathComponent,
                    path: item.path,
                    isDirectory: isDirectory,
                    size: Int64(values?.fileSize ?? 0),
                    mode: Self.modeString(permissions, directory: isDirectory),
                    modified: values?.contentModificationDate
                )
            }
            return Self.sorted(entries)
        }.value
    }

    func existingNames(in directory: String, among names: [String]) async throws -> Set<String> {
        Set(names.filter { FileManager.default.fileExists(atPath: FileRules.join(directory, $0)) })
    }

    func makeDirectory(_ path: String) async throws {
        guard !FileManager.default.fileExists(atPath: path) else {
            throw FileError.message(String(format: String(localized: "“%@” already exists"), (path as NSString).lastPathComponent))
        }
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        } catch {
            throw FileError.message(error.localizedDescription)
        }
    }

    func createFile(_ path: String) async throws {
        guard !FileManager.default.fileExists(atPath: path) else {
            throw FileError.message(String(format: String(localized: "“%@” already exists"), (path as NSString).lastPathComponent))
        }
        guard FileManager.default.createFile(atPath: path, contents: Data()) else {
            throw FileError.message(String(localized: "Could not create the file"))
        }
    }

    func delete(_ paths: [String]) async throws {
        for path in paths {
            if let refusal = FileRules.deleteRefusal(path, remote: false, home: NSHomeDirectory()) {
                throw FileError.message(refusal)
            }
        }
        try await Task.detached(priority: .userInitiated) {
            for path in paths {
                do {
                    try FileManager.default.removeItem(atPath: path)
                } catch {
                    throw FileError.message(error.localizedDescription)
                }
            }
        }.value
    }

    func read(_ path: String, limit: Int) async throws -> Data {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw FileError.message(String(localized: "Could not open the file"))
        }
        defer { try? handle.close() }
        return try handle.read(upToCount: limit) ?? Data()
    }

    func write(_ data: Data, to path: String) async throws {
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            throw FileError.message(error.localizedDescription)
        }
    }

    func copy(_ path: String, to target: String) async throws {
        do {
            try FileManager.default.copyItem(atPath: path, toPath: target)
        } catch {
            throw FileError.message(error.localizedDescription)
        }
    }

    func resolveFolders(_ paths: [String]) async -> [String] {
        paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    static func modeString(_ permissions: UInt16, directory: Bool) -> String {
        var text = directory ? "d" : "-"
        let symbols: [Character] = ["r", "w", "x"]
        for shift in stride(from: 8, through: 0, by: -1) {
            let on = permissions & (1 << UInt16(shift)) != 0
            text.append(on ? symbols[(8 - shift) % 3] : "-")
        }
        return text
    }
}

struct RemoteFileSystem: FileSystem {
    let alias: String
    var host: String? { alias }

    private static let findFormat = #"%y\t%Y\t%s\t%M\t%T@\t%f\0"#

    private func run(_ command: String, input: Data? = nil) async throws -> Data {
        try await RemoteShell.run(alias: alias, command: command, input: input)
    }

    func home() async throws -> String {
        let text = String(decoding: try await run("pwd"), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("/") ? text : "/"
    }

    func list(_ directory: String) async throws -> [FileEntry] {
        let path = FileRules.shellQuote(directory)
        let find = "find \(path) -mindepth 1 -maxdepth 1 -printf \(FileRules.shellQuote(Self.findFormat)) 2>/dev/null"
        if let data = try? await run(find), !data.isEmpty {
            return Self.sorted(FileRules.parseFind(String(decoding: data, as: UTF8.self), in: directory))
        }
        let ls = try await run("cd \(path) && LC_ALL=C ls -lAL")
        return Self.sorted(FileRules.parseLs(String(decoding: ls, as: UTF8.self), in: directory))
    }

    func existingNames(in directory: String, among names: [String]) async throws -> Set<String> {
        guard !names.isEmpty else { return [] }
        let checks = names.map { name in
            let path = FileRules.shellQuote(FileRules.join(directory, name))
            return "[ -e \(path) ] || [ -L \(path) ] && printf '%s\\0' \(FileRules.shellQuote(name))"
        }
        let data = try await run(checks.joined(separator: "; ") + "; true")
        return Set(String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init))
    }

    func makeDirectory(_ path: String) async throws {
        _ = try await run("mkdir \(FileRules.shellQuote(path))")
    }

    func createFile(_ path: String) async throws {
        let quoted = FileRules.shellQuote(path)
        let name = (path as NSString).lastPathComponent
        let exists = String(format: String(localized: "“%@” already exists"), name)
        _ = try await run("if [ -e \(quoted) ]; then echo \(FileRules.shellQuote(exists)) >&2; exit 1; fi; : > \(quoted)")
    }

    func delete(_ paths: [String]) async throws {
        for path in paths {
            if let refusal = FileRules.deleteRefusal(path, remote: true, home: nil) {
                throw FileError.message(refusal)
            }
        }
        let quoted = paths.map(FileRules.shellQuote).joined(separator: " ")
        _ = try await run("rm -rf -- \(quoted)")
    }

    func read(_ path: String, limit: Int) async throws -> Data {
        try await run("head -c \(limit) -- \(FileRules.shellQuote(path))")
    }

    func write(_ data: Data, to path: String) async throws {
        _ = try await run("cat > \(FileRules.shellQuote(path))", input: data)
    }

    func copy(_ path: String, to target: String) async throws {
        _ = try await run("cp -a -- \(FileRules.shellQuote(path)) \(FileRules.shellQuote(target))")
    }

    func resolveFolders(_ paths: [String]) async -> [String] {
        guard !paths.isEmpty else { return [] }
        let script = paths.map { path in
            "(cd \(FileRules.shellQuote(path)) 2>/dev/null && pwd -P || echo); printf '\\0'"
        }.joined(separator: "; ")
        guard let data = try? await run(script) else { return paths }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false)
        return paths.enumerated().map { index, path in
            let resolved = index < lines.count ? lines[index].trimmingCharacters(in: .newlines) : ""
            return resolved.hasPrefix("/") ? resolved : path
        }
    }
}
