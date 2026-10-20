import Foundation
import AppKit
import UniformTypeIdentifiers

@main
struct PinnedLocationsTests {
    @MainActor static func main() async throws {
        let suite = "1agent.locations.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let a = root.appendingPathComponent("中文 项目")
        let b = root.appendingPathComponent("B")
        let alias = root.appendingPathComponent("Alias")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: a)
        let file = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: file)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let model = PinnedLocations(defaults: defaults, home: root.path)
        precondition(model.items.count == 2)
        for item in model.items { model.remove(item.id) }
        precondition(PinnedLocations(defaults: defaults, home: root.path).items.isEmpty, "Deleted defaults must not reappear on restart")
        precondition(model.add([file, URL(string: "https://example.invalid/folder")!]) == 0)
        precondition(model.add([a, b, alias]) == 3)
        precondition(model.items.count == 2, "Symlink duplicates must not create multiple pins")
        let firstID = model.items[0].id
        let secondID = model.items[1].id
        model.rename(firstID, to: "项目")
        model.move(secondID, before: firstID)
        let restored = PinnedLocations(defaults: defaults, home: root.path)
        precondition(restored.items.map(\.id) == [secondID, firstID])
        precondition(restored.items.last?.name == "项目")
        restored.shift(firstID, by: -1)
        precondition(restored.items.first?.id == firstID)
        restored.move(firstID, before: nil)
        precondition(restored.items.last?.id == firstID)
        restored.remove(firstID)
        precondition(FileManager.default.fileExists(atPath: a.path), "Unpinning must not delete the folder")
        let contents = try String(contentsOf: file, encoding: .utf8)
        precondition(contents == "keep")
        let finderItem = NSItemProvider(item: a as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let dataItem = NSItemProvider(item: b.dataRepresentation as NSData, typeIdentifier: UTType.fileURL.identifier)
        let dropped: [URL] = await withCheckedContinuation { continuation in
            PinnedLocations.requestDroppedURLs([finderItem, dataItem]) { continuation.resume(returning: $0) }
        }
        precondition(dropped.map(\.path) == [a.path, b.path], "Finder URL and data representations must preserve order and Unicode")
        for item in restored.items { restored.remove(item.id) }
        precondition(restored.add(dropped) == 2)
        precondition(restored.items.map(\.path) == [a.path, b.path])
        let tracked = DropLifetimeProvider(item: a as NSURL, typeIdentifier: UTType.fileURL.identifier)
        PinnedLocations.requestDroppedURLs([tracked]) { _ in }
        precondition(tracked.started, "Finder payload reading must start before performDrop returns; deferring it loses access")
        print("ok: presets removable, empty state persists, folder validation, deduplication, order/name persistence, unpin never deletes files")
    }
}

private final class DropLifetimeProvider: NSItemProvider, @unchecked Sendable {
    var started = false
    override func loadItem(forTypeIdentifier typeIdentifier: String, options: [AnyHashable: Any]? = nil,
                           completionHandler: NSItemProvider.CompletionHandler? = nil) {
        started = true
        super.loadItem(forTypeIdentifier: typeIdentifier, options: options, completionHandler: completionHandler)
    }
}
