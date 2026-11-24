import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers

struct PinnedLocation: Codable, Identifiable, Equatable {
    var id = UUID()
    var path: String
    var name: String?
}

/// Explicit favorites, independent of open browser tabs. An empty saved array stays empty.
@MainActor
final class PinnedLocations: ObservableObject {
    static let shared = PinnedLocations()
    static let storageKey = "files.pinnedLocations.v1"
    @Published private(set) var items: [PinnedLocation]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, home: String = NSHomeDirectory()) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey) {
            items = (try? JSONDecoder().decode([PinnedLocation].self, from: data)) ?? []
        } else {
            items = [PinnedLocation(path: home), PinnedLocation(path: home + "/Downloads")]
        }
    }

    /// Only local folders can be pinned. This never copies or modifies the folder itself.
    @discardableResult
    func add(_ urls: [URL], before target: UUID? = nil) -> Int {
        var accepted = 0
        for url in urls where url.isFileURL {
            let normalized = url.standardizedFileURL
            let resolved = normalized.resolvingSymlinksInPath()
            guard (try? resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            accepted += 1
            let key = resolved.path
            guard !items.contains(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == key }) else { continue }
            let index = target.flatMap { id in items.firstIndex { $0.id == id } } ?? items.endIndex
            items.insert(PinnedLocation(path: normalized.path), at: index)
        }
        if accepted > 0 { save() }
        return accepted
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name
        save()
    }

    func move(_ id: UUID, before target: UUID?) {
        guard id != target, let source = items.firstIndex(where: { $0.id == id }),
              target == nil || items.contains(where: { $0.id == target }) else { return }
        let item = items.remove(at: source)
        let destination = target.flatMap { id in items.firstIndex { $0.id == id } } ?? items.endIndex
        items.insert(item, at: destination)
        save()
    }

    func shift(_ id: UUID, by delta: Int) {
        guard let source = items.firstIndex(where: { $0.id == id }), items.indices.contains(source + delta) else { return }
        items.swapAt(source, source + delta)
        save()
    }

    /// Start every payload request synchronously while performDrop still owns access.
    /// Only delivery of the collected results is deferred; callback order must not reorder pins.
    static func requestDroppedURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        let batch = DropURLBatch(count: files.count)
        let group = DispatchGroup()
        for (index, provider) in files.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let value = item as? URL { url = value }
                else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let value = item as? String { url = URL(string: value) }
                else { url = nil }
                batch.set(url, at: index)
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { completion(batch.results()) }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

private final class DropURLBatch: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL?]
    init(count: Int) { urls = Array(repeating: nil, count: count) }
    func set(_ url: URL?, at index: Int) {
        lock.lock(); defer { lock.unlock() }
        urls[index] = url
    }
    func results() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        return urls.compactMap { $0 }
    }
}
