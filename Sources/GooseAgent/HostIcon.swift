import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// macOS system icons for a host row: Finder's icon for a local directory, the network icon for SSH.
@MainActor
enum HostIcon {
    /// NSWorkspace lookups hit the disk, and rows redraw often.
    private static var localCache: [String: NSImage] = [:]

    static func local(path: String?) -> NSImage {
        guard let path, !path.isEmpty else {
            return NSWorkspace.shared.icon(for: .folder)
        }
        if let cached = HostIcon.localCache[path] {
            return cached
        }
        let icon: NSImage
        if FileManager.default.fileExists(atPath: path) {
            icon = NSWorkspace.shared.icon(forFile: path)
        } else {
            icon = NSWorkspace.shared.icon(for: .folder)
        }
        HostIcon.localCache[path] = icon
        return icon
    }

    static func remote() -> NSImage? {
        NSImage(named: NSImage.networkName)
    }
}

struct HostIconView: View {
    var isLocal: Bool
    var directory: String? = nil
    var size: CGFloat

    var body: some View {
        if let image = icon {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "server.rack")
                .font(.system(size: size - 2))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }

    private var icon: NSImage? {
        if isLocal {
            return HostIcon.local(path: directory)
        }
        return HostIcon.remote()
    }
}
