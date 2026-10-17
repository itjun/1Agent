import Combine
import Foundation
import Darwin

@MainActor
final class QuickCommandStore: ObservableObject {
    static let shared = QuickCommandStore()
    @Published private(set) var commands: [QuickCommand] = []
    @Published private(set) var loadError: String?
    let url: URL

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.itjun.1agent/quick-commands.json")
        guard FileManager.default.fileExists(atPath: self.url.path) else { return }
        do { commands = try QuickCommandLibrary.decode(Data(contentsOf: self.url)).commands }
        catch { loadError = error.localizedDescription }
    }

    func save(_ item: QuickCommand) throws {
        var item = try item.validated()
        item.updatedAt = Date()
        var next = commands
        if let i = next.firstIndex(where: { $0.id == item.id }) { next[i] = item }
        else { item.order = (next.map(\.order).max() ?? -1) + 1; next.append(item) }
        try replace(next)
    }
    func remove(_ id: UUID) throws { try replace(commands.filter { $0.id != id }) }
    func replace(_ next: [QuickCommand]) throws {
        // Do not overwrite an unreadable/unknown-version library with an empty one.
        if let loadError { throw NSError(domain: "QuickCommands", code: 1, userInfo: [NSLocalizedDescriptionKey: loadError]) }
        let data = try QuickCommandLibrary(commands: next).encoded()
        _ = try QuickCommandLibrary.decode(data)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        // Prepare the complete private file before the commit point. Nothing fallible runs
        // between a successful rename and publishing the new in-memory snapshot.
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".commands-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard rename(temporary.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        commands = next
    }
}
