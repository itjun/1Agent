import Combine
import Foundation

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
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        commands = next
    }
}
